import Darwin
import Dispatch
import Foundation

struct GuardState: Equatable, Codable, Sendable {
    var targetName: String
    var targetEmail: String
    var guardedEmails: [String]
    var processes: [TrackedProcess]
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case targetName = "target_name"
        case targetEmail = "target_email"
        case guardedEmails = "guarded_emails"
        case processes
        case updatedAt = "updated_at"
    }
}

protocol GuardStarting {
    func startDetached()
    func spawnWorker()
    func runWorker()
}

extension GuardStarting {
    func startDetached() {}
    func spawnWorker() {}
    func runWorker() {}
}

struct NoopGuardStarter: GuardStarting {}

enum GuardStepOutcome: Equatable {
    case idle
    case restored(String)
    case retrySoon
    case stopped
}

struct WritebackGuardEngine {
    var files: AccountFiles
    var profile: ToolProfile
    var keychain: any KeychainStoring
    var processes: any ProcessListing
    var clock: () -> Date = Date.init
    var maxRestoresPerMinute: Int = 5

    private var restoreTimes: [Date] = []

    init(
        files: AccountFiles,
        profile: ToolProfile,
        keychain: any KeychainStoring,
        processes: any ProcessListing,
        clock: @escaping () -> Date = Date.init,
        maxRestoresPerMinute: Int = 5
    ) {
        self.files = files
        self.profile = profile
        self.keychain = keychain
        self.processes = processes
        self.clock = clock
        self.maxRestoresPerMinute = maxRestoresPerMinute
    }

    mutating func step() -> GuardStepOutcome {
        guard profile.blockOldWritebackEnabled() else {
            if let lockFD = profile.lockState(wait: 0.2) {
                profile.removeGuardState()
                close(lockFD)
            }
            return .stopped
        }
        guard let lockFD = profile.lockState(wait: 0) else {
            return .retrySoon
        }
        defer { close(lockFD) }

        if files.readRollback() != nil {
            return .retrySoon
        }
        guard profile.blockOldWritebackEnabled(), var state = profile.readGuardState() else {
            if !profile.blockOldWritebackEnabled() {
                profile.removeGuardState()
            }
            return .stopped
        }

        let alive = state.processes.filter { processes.isProcessAlive($0) }
        guard !alive.isEmpty, !state.guardedEmails.isEmpty else {
            profile.removeGuardState()
            return .stopped
        }
        var stateDirty = false
        if alive.count != state.processes.count {
            state.processes = alive
            stateDirty = true
        }

        guard let target = resolveTargetBlob(for: &state, dirty: &stateDirty) else {
            profile.removeGuardState()
            return .stopped
        }
        if stateDirty {
            state.updatedAt = profile.now()
            try? profile.writeGuardState(state)
        }

        let currentBlob: String
        let currentMeta: LoginMeta
        do {
            currentBlob = try keychain.readBlob()
            currentMeta = try decodeLogin(currentBlob, source: .keychain)
        } catch let error as AccountFailure where error.key == .keychainMissing {
            profile.removeGuardState()
            return .stopped
        } catch {
            return .idle
        }

        if currentMeta.email == state.targetEmail {
            return .idle
        }

        guard state.guardedEmails.contains(currentMeta.email) else {
            profile.removeGuardState()
            return .stopped
        }

        let moment = clock()
        restoreTimes.removeAll { moment.timeIntervalSince($0) >= 60 }
        guard restoreTimes.count < maxRestoresPerMinute else {
            profile.removeGuardState()
            return .stopped
        }

        do {
            try keychain.writeBlob(target.blob)
            _ = files.clearQuotaCache()
            restoreTimes.append(moment)
            return .restored(state.targetEmail)
        } catch {
            return .retrySoon
        }
    }

    private func resolveTargetBlob(for state: inout GuardState, dirty: inout Bool) -> (name: String, blob: String)? {
        if let saved = try? files.readSaved(state.targetName), saved.meta.email == state.targetEmail {
            return (state.targetName, saved.blob)
        }
        for candidate in files.slots(forEmail: state.targetEmail) {
            if let saved = try? files.readSaved(candidate), saved.meta.email == state.targetEmail {
                state.targetName = candidate
                dirty = true
                return (candidate, saved.blob)
            }
        }
        return nil
    }
}

struct GuardSpawner: GuardStarting {
    var home: URL
    var keychain: any KeychainStoring
    var processes: any ProcessListing
    var now: () -> String
    var executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]

    func startDetached() {
        guard let pid = spawn(["guard", "--detach"], ownSession: false) else {
            return
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    func spawnWorker() {
        _ = spawn(["guard", "--worker"], ownSession: true)
    }

    func runWorker() {
        let watcher = WritebackGuardWatcher(
            home: home,
            keychain: keychain,
            processes: processes,
            now: now
        )
        watcher.run()
    }

    private func spawn(_ arguments: [String], ownSession: Bool) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
        }
        if ownSession {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        }
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let started = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress, environ)
        }
        return started == 0 ? pid : nil
    }
}

final class WritebackGuardWatcher {
    private let home: URL
    private let profile: ToolProfile
    private let locations: ToolLocations
    private let keychainDirectory: URL
    private let debounceInterval: TimeInterval
    private let fallbackInterval: TimeInterval
    private var engine: WritebackGuardEngine
    private let processes: any ProcessListing

    private let queue = DispatchQueue(label: "agy-cs.guard", qos: .utility)
    private let done = DispatchSemaphore(value: 0)

    private var processSources: [Int32: (process: TrackedProcess, source: DispatchSourceProcess)] = [:]
    private var nodeSources: [String: DispatchSourceFileSystemObject] = [:]
    private var fallbackTimer: DispatchSourceTimer?
    private var pendingEvaluate: DispatchWorkItem?
    private var retryBackoff: TimeInterval = 0.25
    private var finished = false

    init(
        home: URL,
        keychain: any KeychainStoring,
        processes: any ProcessListing,
        now: @escaping () -> String,
        clock: @escaping () -> Date = Date.init,
        keychainDirectory: URL? = nil,
        debounceInterval: TimeInterval = 0.15,
        fallbackInterval: TimeInterval = 15
    ) {
        self.home = home
        self.processes = processes
        self.locations = ToolLocations(home: home, provider: .antigravity)
        self.profile = ToolProfile(home: home, now: now, preferredLanguages: [], provider: .antigravity)
        self.keychainDirectory = keychainDirectory
            ?? home.appendingPathComponent("Library/Keychains", isDirectory: true)
        self.debounceInterval = debounceInterval
        self.fallbackInterval = fallbackInterval
        let files = AccountFiles(
            locations: AccountLocations(home: home, provider: .antigravity),
            now: now,
            codec: AntigravityLoginCodec()
        )
        self.engine = WritebackGuardEngine(
            files: files,
            profile: self.profile,
            keychain: keychain,
            processes: processes,
            clock: clock
        )
    }

    func run() {
        guard let lockFD = profile.lockGuard() else {
            return
        }
        defer { close(lockFD) }

        withExtendedLifetime(self) {
            queue.async { [weak self] in
                self?.start()
            }
            done.wait()
        }
    }

    private func start() {
        syncNodeWatchers()
        startFallbackTimer()
        evaluate()
    }

    private func startFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let nanos = max(100_000_000, UInt64(fallbackInterval * 1_000_000_000))
        timer.schedule(deadline: .now() + .nanoseconds(Int(nanos)), repeating: .nanoseconds(Int(nanos)))
        timer.setEventHandler { [weak self] in
            self?.evaluate()
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func evaluate() {
        guard !finished else {
            return
        }
        syncProcessWatchers()
        syncNodeWatchers()
        switch engine.step() {
        case .idle:
            retryBackoff = 0.25
            syncProcessWatchers()
        case .restored:
            retryBackoff = 0.25
            syncProcessWatchers()
        case .retrySoon:
            let delay = retryBackoff
            retryBackoff = min(1.0, retryBackoff * 2)
            scheduleEvaluate(after: delay)
        case .stopped:
            stop()
        }
    }

    private func scheduleEvaluate(after delay: TimeInterval) {
        guard !finished else {
            return
        }
        pendingEvaluate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingEvaluate = nil
            self?.evaluate()
        }
        pendingEvaluate = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func syncProcessWatchers() {
        let desired = profile.readGuardState()?.processes ?? []
        let desiredByPID = Dictionary(desired.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        for (pid, entry) in processSources where desiredByPID[pid] != entry.process {
            entry.source.cancel()
            processSources.removeValue(forKey: pid)
        }
        for process in desired where process.pid > 0 && processSources[process.pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                self?.processSources.removeValue(forKey: process.pid)?.source.cancel()
                self?.scheduleEvaluate(after: 0.02)
            }
            source.resume()
            processSources[process.pid] = (process, source)
            if !processes.isProcessAlive(process) {
                source.cancel()
                processSources.removeValue(forKey: process.pid)
                scheduleEvaluate(after: 0.02)
            }
        }
    }

    private func syncNodeWatchers() {
        let targets: [(key: String, url: URL, mask: DispatchSource.FileSystemEvent, delay: TimeInterval)] = [
            ("keychainDir", keychainDirectory, [.write, .delete, .rename, .attrib], debounceInterval),
            ("keychainDB", keychainDirectory.appendingPathComponent("login.keychain-db"), [.write, .extend, .attrib, .delete, .rename], debounceInterval),
            ("keychainWAL", keychainDirectory.appendingPathComponent("login.keychain-db-wal"), [.write, .extend, .attrib, .delete, .rename], debounceInterval),
            ("configDir", locations.globalRoot, [.write, .delete, .rename, .attrib], 0.05),
            ("guardFile", locations.guardStateFile, [.write, .delete, .rename, .attrib], 0.05),
            ("toggleFile", locations.blockWritebackFile, [.write, .delete, .rename, .attrib], 0.05),
        ]
        for target in targets {
            let exists = FileManager.default.fileExists(atPath: target.url.path)
            if !exists {
                if let old = nodeSources.removeValue(forKey: target.key) {
                    old.cancel()
                }
                continue
            }
            guard nodeSources[target.key] == nil else {
                continue
            }
            let fd = open(target.url.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else {
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: target.mask, queue: queue)
            source.setCancelHandler {
                close(fd)
            }
            source.setEventHandler { [weak self, key = target.key, delay = target.delay] in
                guard let self, !self.finished else {
                    return
                }
                let events = source.data
                if events.contains(.delete) || events.contains(.rename) {
                    if let removed = self.nodeSources.removeValue(forKey: key) {
                        removed.cancel()
                    }
                    self.syncNodeWatchers()
                } else if key == "keychainDir" || key == "configDir" {
                    self.syncNodeWatchers()
                }
                self.scheduleEvaluate(after: delay)
            }
            source.resume()
            nodeSources[target.key] = source
        }
    }

    private func stop() {
        guard !finished else {
            return
        }
        finished = true
        pendingEvaluate?.cancel()
        pendingEvaluate = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        for (_, entry) in processSources {
            entry.source.cancel()
        }
        processSources.removeAll()
        for (_, source) in nodeSources {
            source.cancel()
        }
        nodeSources.removeAll()
        done.signal()
    }
}
