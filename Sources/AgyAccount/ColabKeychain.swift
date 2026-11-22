import Darwin
import Foundation

let colabKeychainService = "google-colab-cli"
let colabKeychainAccount = "oauth_token"

struct ColabKeyringResult {
    var status: Int32
    var output: Data
}

protocol ColabKeyringRunning {
    func run(operation: String, service: String, account: String, value: String?) throws -> ColabKeyringResult
}

struct ColabTokenPayload: Equatable {
    var token: String
    var refreshToken: String
    var clientID: String
    var clientSecret: String
    var expiry: String
    var tokenURI: String
}

protocol ColabEmailResolving {
    func resolveEmail(for token: ColabTokenPayload) throws -> String
}

// 查找本机 colab CLI，顺序与 agyBinary 保持一致，避免受限于菜单栏 LaunchServices 的精简 PATH。
func colabBinary(
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
    recorded: String?,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> String? {
    let usual = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
    let remembered = [recorded].compactMap { $0 }.filter { $0.hasPrefix("/") }
    let candidates = pathCandidates("colab", in: path) + remembered + usual.map { $0 + "/colab" }
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
}

func colabPythonExecutable(
    for colabPath: String,
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: colabPath)),
          let firstLine = String(decoding: data.prefix(512), as: UTF8.self).split(whereSeparator: \.isNewline).first
    else {
        return nil
    }
    let line = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("#!") else {
        return nil
    }
    let command = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    if FileManager.default.isExecutableFile(atPath: command) {
        return command
    }
    let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let executable = parts.first else {
        return nil
    }
    if executable == "/usr/bin/env", parts.count >= 2 {
        let extra = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let candidates = pathCandidates(parts[1], in: path) + extra.map { $0 + "/\(parts[1])" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
    return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
}

private func pathCandidates(_ binary: String, in path: String) -> [String] {
    path.split(separator: ":").filter { !$0.isEmpty }.map { directory in
        URL(fileURLWithPath: String(directory)).appendingPathComponent(binary).path
    }
}

// colab 自身的钥匙串 ACL 与 partition_id 绑定在安装它所用的 Python 解释器上。
// 这里经同一个解释器通过 stdin/stdout 调它的 keyring，避免触发钥匙串授权弹窗并保留分区权限。
struct PythonKeyringRunner: ColabKeyringRunning {
    var cacheURL: URL
    var locateColab: (String?) -> String? = { colabBinary(recorded: $0) }
    var resolvePython: (String) -> String? = { colabPythonExecutable(for: $0) }

    private static let script = """
    import json, sys, keyring, keyring.errors
    req = json.loads(sys.stdin.read())
    op, svc, acc, val = req["op"], req["service"], req["account"], req.get("value")
    try:
        if op == "get":
            secret = keyring.get_password(svc, acc)
            if secret is None:
                sys.exit(44)
            sys.stdout.write(secret)
        elif op == "set":
            keyring.set_password(svc, acc, val)
        elif op == "delete":
            try:
                keyring.delete_password(svc, acc)
            except keyring.errors.PasswordDeleteError:
                if keyring.get_password(svc, acc) is not None:
                    sys.exit(1)
        else:
            sys.exit(2)
    except keyring.errors.KeyringLocked:
        sys.exit(51)
    except Exception:
        sys.exit(1)
    """

    func run(operation: String, service: String, account: String, value: String?) throws -> ColabKeyringResult {
        let python = try pythonExecutable()
        var payload: [String: Any] = ["op": operation, "service": service, "account": account]
        if let value {
            payload["value"] = value
        }
        guard let input = try? JSONSerialization.data(withJSONObject: payload) else {
            throw AccountFailure(.colabLoginFormat)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", Self.script]
        let feed = Pipe()
        let output = Pipe()
        process.standardInput = feed
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AccountFailure(.colabNotFound)
        }
        let writer = feed.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let fed = (try? writer.write(contentsOf: input)) != nil
        try? writer.close()
        let timedOut = SharedFlag(false)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        timer.resume()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard fed, !timedOut.value, process.terminationReason == .exit else {
            throw AccountFailure(.keychainFailed, "colab-keyring")
        }
        return ColabKeyringResult(status: process.terminationStatus, output: data)
    }

    private func pythonExecutable() throws -> String {
        let cached = (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["path"] as? String
        guard let colabPath = locateColab(cached) else {
            throw AccountFailure(.colabNotFound)
        }
        let resolved = (colabPath as NSString).resolvingSymlinksInPath
        if cached != resolved,
           let data = try? JSONSerialization.data(withJSONObject: ["path": resolved], options: [.prettyPrinted, .sortedKeys])
        {
            try? AtomicFile.write(cacheURL, String(decoding: data, as: UTF8.self) + "\n")
        }
        guard let python = resolvePython(colabPath) else {
            throw AccountFailure(.colabNotFound)
        }
        return python
    }
}

private final class SharedFlag: @unchecked Sendable {
    private var state: Bool
    private let lock = NSLock()

    init(_ initial: Bool) {
        state = initial
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func set() {
        lock.lock()
        state = true
        lock.unlock()
    }
}

struct ColabKeychainStore: KeychainStoring {
    var runner: any ColabKeyringRunning
    var service = colabKeychainService
    var account = colabKeychainAccount

    init(cacheURL: URL) {
        runner = PythonKeyringRunner(cacheURL: cacheURL)
    }

    init(runner: any ColabKeyringRunning, service: String = colabKeychainService, account: String = colabKeychainAccount) {
        self.runner = runner
        self.service = service
        self.account = account
    }

    func readBlob() throws -> String {
        let result = try runner.run(operation: "get", service: service, account: account, value: nil)
        guard result.status == 0 else {
            throw securityFailure(exitStatus: result.status)
        }
        guard let text = String(data: result.output, encoding: .utf8) else {
            throw AccountFailure(.colabLoginFormat)
        }
        return stripNewlines(text)
    }

    func writeBlob(_ blob: String) throws {
        try checkWritable(blob)
        let original = try? readBlob()
        try store(blob)
        let written = try readBlob()
        guard written == blob else {
            if let original, original != written {
                try? store(original)
            }
            throw AccountFailure(.writeMismatch)
        }
    }

    func deleteBlob() throws {
        let result = try runner.run(operation: "delete", service: service, account: account, value: nil)
        guard result.status == 0 || result.status == 44 else {
            throw securityFailure(exitStatus: result.status)
        }
    }

    func checkWritable(_ blob: String) throws {
        guard !blob.contains("\n"), !blob.contains("\r"), (try? parseColabToken(blob)) != nil else {
            throw AccountFailure(.colabLoginFormat)
        }
    }

    private func store(_ blob: String) throws {
        let result = try runner.run(operation: "set", service: service, account: account, value: blob)
        guard result.status == 0 else {
            throw securityFailure(exitStatus: result.status)
        }
    }
}

func parseColabToken(_ blob: String) throws -> ColabTokenPayload {
    guard let data = blob.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let object = raw as? [String: Any]
    else {
        throw AccountFailure(.colabLoginFormat)
    }
    guard let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
          let clientID = object["client_id"] as? String, !clientID.isEmpty,
          let clientSecret = object["client_secret"] as? String, !clientSecret.isEmpty
    else {
        throw AccountFailure(.colabLoginFormat)
    }
    return ColabTokenPayload(
        token: object["token"] as? String ?? "",
        refreshToken: refresh,
        clientID: clientID,
        clientSecret: clientSecret,
        expiry: object["expiry"] as? String ?? "",
        tokenURI: object["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
    )
}

func refreshColabAccessToken(
    _ payload: ColabTokenPayload,
    http: any HTTPPosting,
    timeout: TimeInterval = 6
) -> (status: Int?, accessToken: String?, idTokenEmail: String?) {
    let targetURL: URL
    if let candidate = URL(string: payload.tokenURI), candidate.scheme == "https" {
        targetURL = candidate
    } else {
        targetURL = URL(string: "https://oauth2.googleapis.com/token")!
    }
    // 不传 scope，兼容 google-colab-cli #235 的 partial scope 授权。
    let fields = [
        ("client_id", payload.clientID),
        ("client_secret", payload.clientSecret),
        ("refresh_token", payload.refreshToken),
        ("grant_type", "refresh_token"),
    ]
    let body = formURLEncoded(fields)
    let headers = ["Content-Type": "application/x-www-form-urlencoded"]
    guard let response = http.post(HTTPRequest(url: targetURL, headers: headers, body: Data(body.utf8), timeout: timeout)) else {
        return (nil, nil, nil)
    }
    guard response.status == 200,
          let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
          let access = json["access_token"] as? String, !access.isEmpty
    else {
        return (response.status, nil, nil)
    }
    let idEmail = (json["id_token"] as? String).flatMap(jwtEmail)
    return (200, access, idEmail)
}

private func formURLEncoded(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(k)=\(v)"
    }.joined(separator: "&")
}

private func jwtEmail(_ jwt: String) -> String? {
    let segments = jwt.split(separator: ".")
    guard segments.count >= 2 else {
        return nil
    }
    var base64 = String(segments[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: base64),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let email = object["email"] as? String,
          email.contains("@")
    else {
        return nil
    }
    return email
}

struct GoogleColabEmailResolver: ColabEmailResolving {
    var http: any HTTPPosting = URLSessionPoster()
    var now: () -> Date = Date.init

    func resolveEmail(for token: ColabTokenPayload) throws -> String {
        if !token.token.isEmpty,
           let expiry = parseTimestamp(token.expiry),
           expiry > now().addingTimeInterval(30),
           let email = try? fetchTokenInfoEmail(accessToken: token.token)
        {
            return email
        }
        let refreshed = refreshColabAccessToken(token, http: http)
        if let idEmail = refreshed.idTokenEmail {
            return idEmail
        }
        guard let access = refreshed.accessToken else {
            throw AccountFailure(.colabEmailFailed)
        }
        return try fetchTokenInfoEmail(accessToken: access)
    }

    private func fetchTokenInfoEmail(accessToken: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = accessToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard let url = URL(string: "https://oauth2.googleapis.com/tokeninfo?access_token=\(encoded)"),
              let response = http.post(HTTPRequest(url: url, headers: [:], body: Data(), timeout: 6, method: "GET"))
        else {
            throw AccountFailure(.colabEmailFailed)
        }
        guard response.status == 200,
              let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        else {
            throw AccountFailure(.colabEmailFailed)
        }
        guard let email = json["email"] as? String, email.contains("@") else {
            throw AccountFailure(.colabMissingEmail)
        }
        return email
    }
}

struct ColabLoginCodec: LoginDecoding {
    var emailResolver: any ColabEmailResolving = GoogleColabEmailResolver()

    func decodeKeychain(_ blob: String, lookupEmailByBlob: (String) -> String?) throws -> LoginMeta {
        let parsed = try parseColabToken(blob)
        let email: String
        if let known = lookupEmailByBlob(blob), known.contains("@") {
            email = known
        } else {
            email = try emailResolver.resolveEmail(for: parsed)
        }
        return LoginMeta(email: email, authMethod: "oauth2", expiry: parsed.expiry)
    }

    func decodeSaved(_ blob: String, sidecarEmail: String?) throws -> LoginMeta {
        let parsed = try parseColabToken(blob)
        guard let email = sidecarEmail, email.contains("@") else {
            throw AccountFailure(.colabMissingEmail)
        }
        return LoginMeta(email: email, authMethod: "oauth2", expiry: parsed.expiry)
    }

    func refreshToken(in blob: String) -> String? {
        try? parseColabToken(blob).refreshToken
    }

    func canRecover(_ blob: String) -> Bool {
        (try? parseColabToken(blob)) != nil
    }
}

// 按账号隔离 ~/.config/colab-cli/sessions.json 与 sessions.attached.json，
// 并在切换账号时重置 settings.json 里的账号级能力缓存。
struct ColabStateSync: ProviderStateSyncing {
    var locations: AccountLocations
    private let manager = FileManager.default

    func afterSwitch(from previousNames: [String], to targetName: String, sameEmail: Bool) -> [ProviderNotice] {
        guard !sameEmail else {
            return []
        }
        var notices: [ProviderNotice] = []
        if hasActiveSessions() {
            notices.append(ProviderNotice(key: .colabActiveSessions))
        }
        let pairs = sessionPairs(for: previousNames, targetName: targetName)
        for pair in pairs.previous {
            backupFile(from: pair.live, to: pair.backup)
        }
        for pair in pairs.target {
            restoreFile(from: pair.backup, to: pair.live)
        }
        resetCapabilityCache()
        return notices
    }

    func renameAuxiliary(from source: String, to target: String) {
        moveIfPresent(from: locations.sessionsBackupURL(source), to: locations.sessionsBackupURL(target))
        moveIfPresent(from: locations.attachedSessionsBackupURL(source), to: locations.attachedSessionsBackupURL(target))
    }

    func removeAuxiliary(_ name: String) {
        try? manager.removeItem(at: locations.sessionsBackupURL(name))
        try? manager.removeItem(at: locations.attachedSessionsBackupURL(name))
    }

    private func sessionPairs(
        for previousNames: [String],
        targetName: String
    ) -> (previous: [(live: URL, backup: URL)], target: [(live: URL, backup: URL)]) {
        var previous: [(live: URL, backup: URL)] = []
        for name in previousNames {
            if let sessions = locations.colabSessionsFile {
                previous.append((sessions, locations.sessionsBackupURL(name)))
            }
            if let attached = locations.colabAttachedSessionsFile {
                previous.append((attached, locations.attachedSessionsBackupURL(name)))
            }
        }
        var target: [(live: URL, backup: URL)] = []
        if let sessions = locations.colabSessionsFile {
            target.append((sessions, locations.sessionsBackupURL(targetName)))
        }
        if let attached = locations.colabAttachedSessionsFile {
            target.append((attached, locations.attachedSessionsBackupURL(targetName)))
        }
        return (previous, target)
    }

    private func hasActiveSessions() -> Bool {
        for url in [locations.colabSessionsFile, locations.colabAttachedSessionsFile].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !object.isEmpty
            else {
                continue
            }
            return true
        }
        return false
    }

    private func backupFile(from live: URL, to backup: URL) {
        guard manager.fileExists(atPath: live.path),
              let content = try? String(contentsOf: live, encoding: .utf8)
        else {
            try? manager.removeItem(at: backup)
            return
        }
        try? AtomicFile.write(backup, content)
    }

    private func restoreFile(from backup: URL, to live: URL) {
        if manager.fileExists(atPath: backup.path),
           let content = try? String(contentsOf: backup, encoding: .utf8)
        {
            try? AtomicFile.write(live, content)
        } else if manager.fileExists(atPath: live.path) {
            try? AtomicFile.write(live, "{}\n")
        }
    }

    private func moveIfPresent(from source: URL, to target: URL) {
        guard manager.fileExists(atPath: source.path) else {
            return
        }
        try? manager.removeItem(at: target)
        try? manager.moveItem(at: source, to: target)
    }

    private func resetCapabilityCache() {
        guard let settingsURL = locations.colabSettingsFile,
              manager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        var changed = false
        for key in ["public_api_supported", "tunnel_api_supported"] where object[key] != nil && !(object[key] is NSNull) {
            object[key] = NSNull()
            changed = true
        }
        guard changed,
              let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            return
        }
        try? AtomicFile.write(settingsURL, String(decoding: updated, as: UTF8.self) + "\n")
    }
}
