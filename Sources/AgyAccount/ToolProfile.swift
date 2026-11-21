import Foundation

struct ToolLocations {
    var root: URL
    var accountsDirectory: URL
    var languageFile: URL
    var activeFile: URL
    var initializedFile: URL
    var usageDirectory: URL
    var clientFile: URL
    var usageStatusFile: URL
    var usageLockFile: URL
    var addCommandFile: URL

    init(home: URL) {
        root = home.appendingPathComponent(".agy-cs", isDirectory: true)
        addCommandFile = root.appendingPathComponent("add-account.command")
        accountsDirectory = root.appendingPathComponent("accounts", isDirectory: true)
        usageDirectory = root.appendingPathComponent("usage", isDirectory: true)
        clientFile = root.appendingPathComponent("agy-client.json")
        usageStatusFile = root.appendingPathComponent("usage-status.json")
        usageLockFile = root.appendingPathComponent("usage.lock")
        languageFile = root.appendingPathComponent("language")
        activeFile = root.appendingPathComponent("active")
        initializedFile = root.appendingPathComponent("initialized")
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
    private let manager = FileManager.default
    private var locations: ToolLocations { ToolLocations(home: home) }

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
        return found.sorted()
    }

    func read(_ name: String) throws -> LoginMeta {
        let url = locations.profileURL(name)
        guard manager.fileExists(atPath: url.path) else {
            throw missing(name)
        }
        let record = try readRecord(url)
        return LoginMeta(email: record.email, authMethod: record.authMethod, expiry: record.expiry)
    }

    func write(name: String, meta: LoginMeta, savedAt: String? = nil) throws {
        let sidecar = encodeSidecar(
            name: name,
            email: meta.email,
            authMethod: meta.authMethod,
            expiry: meta.expiry,
            savedAt: savedAt ?? now()
        )
        try AtomicFile.write(locations.profileURL(name), sidecar)
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
        let descriptor = open(locations.usageLockFile.path, O_CREAT | O_RDWR, 0o600)
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

    private func ensureRoot() throws {
        try manager.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try setMode(locations.root, 0o700)
    }

    private func importPublicRecords() throws -> Set<String> {
        let source = AccountLocations(home: home).accountsDirectory
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
        let url = AccountLocations(home: home).activeURL
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
        try manager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }
}

private struct PublicRecord {
    var email: String
    var authMethod: String
    var expiry: String
    var savedAt: String
}
