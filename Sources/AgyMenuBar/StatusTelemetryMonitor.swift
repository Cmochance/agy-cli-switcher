import AgyAccount
import Darwin
import Foundation

// 仅在启用“菜单栏显示上下文与速度”时，用 EVFILT_VNODE 防抖监听 Antigravity 会话目录与设置变更。
final class StatusTelemetryMonitor: @unchecked Sendable {
    private let board: AccountBoard
    private let queue = DispatchQueue(label: "agy-cs.status-telemetry", qos: .utility)
    private let onUpdate: @MainActor (String?) -> Void

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private var resyncTimer: DispatchSourceTimer?
    private var lastStamp: String?
    private var stopped = false

    init(board: AccountBoard, onUpdate: @escaping @MainActor (String?) -> Void) {
        self.board = board
        self.onUpdate = onUpdate
    }

    deinit {
        debounceWork?.cancel()
        resyncTimer?.cancel()
        for source in sources.values {
            source.cancel()
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.stopped = false
            self?.syncWatchersAndEvaluate(resetStamp: true)
            self?.startResyncTimer()
        }
    }

    func refreshNow() {
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                return
            }
            self.debounceWork?.cancel()
            self.debounceWork = nil
            self.syncWatchersAndEvaluate(resetStamp: true)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.stopped = true
            self.debounceWork?.cancel()
            self.debounceWork = nil
            self.resyncTimer?.cancel()
            self.resyncTimer = nil
            for source in self.sources.values {
                source.cancel()
            }
            self.sources.removeAll()
        }
    }

    private func startResyncTimer() {
        resyncTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else {
                return
            }
            self.syncDirectoryWatchers()
            if !self.sources.isEmpty {
                self.evaluate(resetStamp: false)
            }
        }
        timer.resume()
        resyncTimer = timer
    }

    private func syncWatchersAndEvaluate(resetStamp: Bool) {
        syncDirectoryWatchers()
        evaluate(resetStamp: resetStamp)
    }

    private func syncDirectoryWatchers() {
        let shouldWatch = board.isStatusTelemetryActive()
        let desiredPaths: Set<String> = shouldWatch
            ? Set(board.watchedTelemetryDirectories().map(\.path))
            : []

        for path in Array(sources.keys) where !desiredPaths.contains(path) || !FileManager.default.fileExists(atPath: path) {
            sources.removeValue(forKey: path)?.cancel()
        }

        for path in desiredPaths where sources[path] == nil {
            guard FileManager.default.fileExists(atPath: path) else {
                continue
            }
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else {
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebouncedEvaluate()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources[path] = source
        }
    }

    private func scheduleDebouncedEvaluate() {
        guard !stopped else {
            return
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.syncWatchersAndEvaluate(resetStamp: false)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func evaluate(resetStamp: Bool) {
        let result = board.loadStatusBarSummary(knownStamp: resetStamp ? nil : lastStamp)
        lastStamp = result.stamp
        guard result.changed else {
            return
        }
        let badge = result.badge
        let callback = onUpdate
        DispatchQueue.main.async {
            callback(badge)
        }
    }
}
