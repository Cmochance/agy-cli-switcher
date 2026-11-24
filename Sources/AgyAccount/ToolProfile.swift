import Foundation

struct ToolLocations {
    var provider: AccountProvider
    var globalRoot: URL
    var root: URL
    var providerFile: URL
    var accountsDirectory: URL
    var languageFile: URL
    var activeFile: URL
    var initializedFile: URL
    var usageDirectory: URL
    var clientFile: URL
    var usageStatusFile: URL
    var usageLockFile: URL
    var addCommandFile: URL
    var orderFile: URL
    var appLockFile: URL
    var stateLockFile: URL
    var dismissedFile: URL
    var blockWritebackFile: URL
    var guardStateFile: URL
    var guardLockFile: URL

    init(home: URL, provider: AccountProvider = .antigravity) {
        self.provider = provider
        let global = home.appendingPathComponent(".agy-cs", isDirectory: true)
        globalRoot = global
        providerFile = global.appendingPathComponent("provider")
        languageFile = global.appendingPathComponent("language")
        addCommandFile = global.appendingPathComponent("add-account.command")
        appLockFile = global.appendingPathComponent("app.lock")
        blockWritebackFile = global.appendingPathComponent("block-writeback")
        guardStateFile = global.appendingPathComponent("guard.json")
        guardLockFile = global.appendingPathComponent("guard.lock")

        let scoped = provider == .antigravity
            ? global
            : global.appendingPathComponent(provider.rawValue, isDirectory: true)
        root = scoped
        orderFile = scoped.appendingPathComponent("order")
        stateLockFile = scoped.appendingPathComponent("state.lock")
        dismissedFile = scoped.appendingPathComponent("not-saved")
        accountsDirectory = scoped.appendingPathComponent("accounts", isDirectory: true)
        usageDirectory = scoped.appendingPathComponent("usage", isDirectory: true)
        clientFile = global.appendingPathComponent(
            provider == .antigravity ? "agy-client.json" : "colab-client.json"
        )
        usageStatusFile = scoped.appendingPathComponent("usage-status.json")
        usageLockFile = scoped.appendingPathComponent("usage.lock")
        activeFile = scoped.appendingPathComponent("active")
        initializedFile = scoped.appendingPathComponent("initialized")
    }

    func profileURL(_ name: String) -> URL {
        accountsDirectory.appendingPathComponent("\(name).json")
    }

    func usageURL(_ name: String) -> URL {
        usageDirectory.appendingPathComponent("\(name).json")
    }
}

struct ToolProfile {
    var home: URL
    var now: () -> String
    var preferredLanguages: [String]
    var provider: AccountProvider = .antigravity
    private let manager = FileManager.default
    private var locations: ToolLocations { ToolLocations(home: home, provider: provider) }

    func selectedProvider() -> AccountProvider {
        guard let text = try? readText(locations.providerFile) else {
            return .antigravity
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountProvider(rawValue: trimmed) ?? .antigravity
    }

    func setSelectedProvider(_ selected: AccountProvider) throws {
        try ensureGlobalRoot()
        try AtomicFile.write(locations.providerFile, selected.rawValue + "\n")
    }

    func prepare() throws {
        try ensureRoot()
        if manager.fileExists(atPath: locations.accountsDirectory.path) {
            try setMode(locations.accountsDirectory, 0o700)
            return
        }
        try manager.createDirectory(at: locations.accountsDirectory, withIntermediateDirectories: true)
        try setMode(locations.accountsDirectory, 0o700)
        let imported = try importPublicRecords()
        let active = geminiActiveName()
        if imported.contains(active) {
            try setActive(active)
        }
    }

    func names() -> [String] {
        guard let urls = try? manager.contentsOfDirectory(
            at: locations.accountsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var found: [String] = []
        for url in urls where url.lastPathComponent.hasSuffix(".json") {
            let name = url.deletingPathExtension().lastPathComponent
            guard (try? checkName(name)) != nil else {
                continue
            }
            found.append(name)
        }
        // 记过顺序的名字按记下的顺序在前，没记过的按字母顺序接在后面。
        let placed = order().filter(found.contains)
        return placed + found.sorted().filter { !placed.contains($0) }
    }

    func setOrder(_ names: [String]) throws {
        try AtomicFile.write(locations.orderFile, names.map { $0 + "\n" }.joined())
    }

    private func order() -> [String] {
        guard let text = try? readText(locations.orderFile) else {
            return []
        }
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { seen.insert($0).inserted }
    }

    func read(_ name: String) throws -> LoginMeta {
        let url = locations.profileURL(name)
        guard manager.fileExists(atPath: url.path) else {
            throw missing(name)
        }
        let record = try readRecord(url)
        return LoginMeta(email: record.email, authMethod: record.authMethod, expiry: record.expiry)
    }

    // 已经记过顺序时，新名字接在最后，先存的在前。还没记过顺序时不记，照旧按字母顺序。
    // 改名自己安排位置，不走这一步（placing 为 false）。
    func write(name: String, meta: LoginMeta, savedAt: String? = nil, placing: Bool = true) throws {
        let isNew = !manager.fileExists(atPath: locations.profileURL(name).path)
        let earlier = placing && isNew && manager.fileExists(atPath: locations.orderFile.path) ? names() : nil
        let sidecar = encodeSidecar(
            name: name,
            email: meta.email,
            authMethod: meta.authMethod,
            expiry: meta.expiry,
            savedAt: savedAt ?? now()
        )
        try AtomicFile.write(locations.profileURL(name), sidecar)
        if let earlier {
            try? setOrder(earlier + [name])
        }
    }

    func setActive(_ name: String) throws {
        try AtomicFile.write(locations.activeFile, name + "\n")
    }

    func activeName() -> String {
        guard let text = try? readText(locations.activeFile) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func slots(forEmail email: String) -> [String] {
        names().filter { name in
            (try? read(name).email) == email
        }
    }

    func savedAt(_ name: String) -> String {
        guard let record = try? readRecord(locations.profileURL(name)), !record.savedAt.isEmpty else {
            return now()
        }
        return record.savedAt
    }

    func deleteRecord(_ name: String) throws {
        let url = locations.profileURL(name)
        guard manager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try manager.removeItem(at: url)
        } catch {
            throw AccountFailure(.deleteFailed, name)
        }
    }

    func readUsage(_ name: String, email: String) -> UsageSnapshot? {
        (try? Data(contentsOf: locations.usageURL(name))).flatMap { decodeUsage($0, email: email) }
    }

    func writeUsage(_ name: String, _ snapshot: UsageSnapshot, email: String) throws {
        try AtomicFile.write(locations.usageURL(name), encodeUsage(snapshot, email: email, fetchedAt: now()))
    }

    // 同一时间只让一个进程查询并写额度记录。进程结束时锁自动释放。
    // 锁被占着时最多等 wait 秒，等不到返回 nil。waited 表示等过别的进程。
    func lockUsage(wait: TimeInterval) -> (descriptor: Int32, waited: Bool)? {
        try? ensureRoot()
        let descriptor = open(locations.usageLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        let deadline = DispatchTime.now() + wait
        var waited = false
        while descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK || errno == EINTR {
            guard DispatchTime.now() < deadline else {
                close(descriptor)
                return nil
            }
            waited = true
            usleep(100_000)
        }
        return (descriptor, waited)
    }

    // 同一时间只让一个进程改账号（保存、切换、删除、改名、排序、新增）。进程结束时锁自动放开。
    // 带 O_CLOEXEC，不传给之后启动的 agy 和查额度的进程。锁被占着时最多等 wait 秒，等不到返回 nil。
    func lockState(wait: TimeInterval) -> Int32? {
        try? ensureRoot()
        let descriptor = open(locations.stateLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return nil
        }
        let deadline = DispatchTime.now() + wait
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, DispatchTime.now() < deadline else {
                close(descriptor)
                return nil
            }
            usleep(50_000)
        }
        return descriptor
    }

    // 用户带着 --force 删掉了当前登录唯一的一份副本时，把这个邮箱记在这里，之后不再自动保存它。
    // 这个邮箱重新保存，或者当前登录换成了别的，这条记录就没用了。
    func dismissedEmail() -> String {
        ((try? readText(locations.dismissedFile)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setDismissed(_ email: String) {
        try? AtomicFile.write(locations.dismissedFile, email + "\n")
    }

    func clearDismissed() {
        try? manager.removeItem(at: locations.dismissedFile)
    }

    func blockOldWritebackEnabled() -> Bool {
        guard let text = try? readText(locations.blockWritebackFile) else {
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func setBlockOldWriteback(_ enabled: Bool) throws {
        try ensureGlobalRoot()
        if enabled {
            try AtomicFile.write(locations.blockWritebackFile, "1\n")
            return
        }
        if manager.fileExists(atPath: locations.blockWritebackFile.path) {
            do {
                try manager.removeItem(at: locations.blockWritebackFile)
            } catch {
                throw AccountFailure(.writeFailed, locations.blockWritebackFile.path)
            }
        }
    }

    func readGuardState() -> GuardState? {
        guard let data = try? Data(contentsOf: locations.guardStateFile) else {
            return nil
        }
        return try? JSONDecoder().decode(GuardState.self, from: data)
    }

    func writeGuardState(_ state: GuardState) throws {
        try ensureGlobalRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try AtomicFile.write(locations.guardStateFile, String(decoding: data, as: UTF8.self) + "\n")
    }

    func removeGuardState() {
        try? manager.removeItem(at: locations.guardStateFile)
    }

    func lockGuard(wait: TimeInterval = 0.3) -> Int32? {
        try? ensureGlobalRoot()
        let descriptor = open(locations.guardLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return nil
        }
        let deadline = DispatchTime.now() + wait
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, DispatchTime.now() < deadline else {
                close(descriptor)
                return nil
            }
            usleep(20_000)
        }
        return descriptor
    }

    func writeUsageStatus(failed: [String]) throws {
        let object: [String: Any] = ["finished_at": now(), "failed": failed]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try AtomicFile.write(locations.usageStatusFile, String(decoding: data, as: UTF8.self) + "\n")
    }

    func failedUsage() -> [String] {
        let object = (try? Data(contentsOf: locations.usageStatusFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return object?["failed"] as? [String] ?? []
    }

    func moveUsage(from source: String, to target: String) {
        try? manager.removeItem(at: locations.usageURL(target))
        try? manager.moveItem(at: locations.usageURL(source), to: locations.usageURL(target))
    }

    func isInitialized() -> Bool {
        manager.fileExists(atPath: locations.initializedFile.path)
    }

    func markInitialized() throws {
        try AtomicFile.write(locations.initializedFile, "1\n")
    }

    func remove(_ name: String) throws {
        let url = locations.profileURL(name)
        if manager.fileExists(atPath: url.path) {
            do {
                try manager.removeItem(at: url)
            } catch {
                throw AccountFailure(.deleteFailed, name)
            }
        }
        try? manager.removeItem(at: locations.usageURL(name))
        // 删掉的名字不留在顺序里：以后再存一个同名的账号，不该占着原来的位置。
        let listed = order()
        if listed.contains(name) {
            try? setOrder(listed.filter { $0 != name })
        }
        if activeName() == name, manager.fileExists(atPath: locations.activeFile.path) {
            do {
                try manager.removeItem(at: locations.activeFile)
            } catch {
                throw AccountFailure(.deleteFailed, name)
            }
        }
    }

    func resolvedLanguage() -> AppLanguage {
        if let stored = storedLanguage() {
            return stored
        }
        return AppLanguage.resolve(preferred: preferredLanguages)
    }

    func languageIsExplicit() -> Bool {
        storedLanguage() != nil
    }

    func setLanguage(_ language: AppLanguage) throws {
        try AtomicFile.write(locations.languageFile, language.rawValue + "\n")
    }

    private func storedLanguage() -> AppLanguage? {
        guard let text = try? readText(locations.languageFile) else {
            return nil
        }
        return AppLanguage.parse(text)
    }

    private func ensureGlobalRoot() throws {
        try manager.createDirectory(at: locations.globalRoot, withIntermediateDirectories: true)
        try setMode(locations.globalRoot, 0o700)
    }

    private func ensureRoot() throws {
        try ensureGlobalRoot()
        try manager.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try setMode(locations.root, 0o700)
    }

    private func importPublicRecords() throws -> Set<String> {
        let source = AccountLocations(home: home, provider: provider).accountsDirectory
        guard let urls = try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return []
        }
        var imported = Set<String>()
        for url in urls where url.lastPathComponent.hasSuffix(".meta.json") {
            let filename = url.lastPathComponent
            let name = String(filename.dropLast(".meta.json".count))
            guard (try? checkName(name)) != nil, let record = try? readRecord(url) else {
                continue
            }
            try write(
                name: name,
                meta: LoginMeta(email: record.email, authMethod: record.authMethod, expiry: record.expiry),
                savedAt: record.savedAt
            )
            imported.insert(name)
        }
        return imported
    }

    private func geminiActiveName() -> String {
        let url = AccountLocations(home: home, provider: provider).activeURL
        guard let text = try? readText(url) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readRecord(_ url: URL) throws -> PublicRecord {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AccountFailure(.readFailed, url.path)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = object["email"] as? String,
              email.contains("@")
        else {
            throw AccountFailure(.loginUnreadable)
        }
        return PublicRecord(
            email: email,
            authMethod: object["auth_method"] as? String ?? "",
            expiry: object["expiry"] as? String ?? "",
            savedAt: object["saved_at"] as? String ?? ""
        )
    }

    private func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AccountFailure(.loginUnreadable)
        }
        return text
    }

    private func missing(_ name: String) -> AccountFailure {
        let existing = names()
        if existing.isEmpty {
            return AccountFailure(.accountMissingNone, name)
        }
        return AccountFailure(.accountMissing, name, existing.joined(separator: ", "))
    }

    private func setMode(_ url: URL, _ mode: Int) throws {
        if let existing = (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue,
           (existing & 0o777) == mode
        {
            return
        }
        try manager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }
}

private struct PublicRecord {
    var email: String
    var authMethod: String
    var expiry: String
    var savedAt: String
}
