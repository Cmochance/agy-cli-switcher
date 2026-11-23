import CryptoKit
import Darwin
import Foundation
import Security

// colab 0.8.0 PUBLIC_SCOPES。登录自己做 PKCE，不跑 `colab whoami`。
let colabPublicScopes = [
    "openid",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/colaboratory",
    "https://www.googleapis.com/auth/drive.file",
]

let colabRemoteRedirectURI = "https://sdk.cloud.google.com/applicationdefaultauthcode.html"

public let colabLoginLinePrefix = "AGY_CS_LOGIN"

public enum ColabLoginEvent: Equatable {
    case opened
    case needCode
    case retry(TextKey)
    case saved(name: String, email: String)
    case error(TextKey)
    case ignored
}

// 面板和子进程之间的几行。授权码不走这几行，只走子进程的标准输入。
public func parseColabLoginLine(_ line: String) -> ColabLoginEvent {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.first == colabLoginLinePrefix, parts.count >= 2 else {
        return .ignored
    }
    switch parts[1] {
    case "opened" where parts.count == 2:
        return .opened
    case "need-code" where parts.count == 2:
        return .needCode
    case "retry" where parts.count == 3:
        guard let key = TextKey(rawValue: parts[2]) else {
            return .ignored
        }
        return .retry(key)
    case "saved" where parts.count == 4:
        return .saved(name: parts[2], email: parts[3])
    case "error" where parts.count == 3:
        guard let key = TextKey(rawValue: parts[2]) else {
            return .ignored
        }
        return .error(key)
    default:
        return .ignored
    }
}

// 浏览器 Copy 出来的那一种。只在面板等授权码时自动提交。
public func isColabClipboardCode(_ text: String) -> Bool {
    text.range(of: #"^4/[A-Za-z0-9_-]{20,200}$"#, options: .regularExpression) != nil
}

// 手贴的可以更宽。回环和远程两处收到的码都先过这一关。
public func isColabManualCode(_ text: String) -> Bool {
    text.range(of: #"^[A-Za-z0-9_./~-]{20,512}$"#, options: .regularExpression) != nil
}

struct ColabOAuthClient: Equatable {
    var clientID: String
    var clientSecret: String
    var authURI: String
    var tokenURI: String
}

protocol ColabSigning {
    func signIn(handoff: Bool) throws -> String
}

struct UnavailableColabSigner: ColabSigning {
    func signIn(handoff: Bool) throws -> String {
        throw AccountFailure(.colabNotFound)
    }
}

func pkceS256Challenge(_ verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return base64URL(Data(digest))
}

func colabAuthorizeURL(
    client: ColabOAuthClient,
    redirect: String,
    challenge: String,
    state: String,
    remote: Bool
) -> URL {
    var components = URLComponents(string: client.authURI) ?? URLComponents()
    var items = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: client.clientID),
        URLQueryItem(name: "redirect_uri", value: redirect),
        URLQueryItem(name: "scope", value: colabPublicScopes.joined(separator: " ")),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "access_type", value: "offline"),
        URLQueryItem(name: "prompt", value: "consent"),
    ]
    if remote {
        items.append(URLQueryItem(name: "token_usage", value: "remote"))
    }
    components.queryItems = items
    return components.url ?? URL(string: client.authURI)!
}

func colabCredentialsJSON(
    accessToken: String,
    refreshToken: String,
    client: ColabOAuthClient,
    scopes: [String],
    expiry: String
) throws -> String {
    let object: [String: Any] = [
        "account": "",
        "client_id": client.clientID,
        "client_secret": client.clientSecret,
        "expiry": expiry,
        "refresh_token": refreshToken,
        "scopes": scopes,
        "token": accessToken,
        "token_uri": client.tokenURI,
        "universe_domain": "googleapis.com",
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let text = String(decoding: data, as: UTF8.self)
    guard !text.contains("\n"), !text.contains("\r") else {
        throw AccountFailure(.colabLoginFormat)
    }
    return text
}

func colabExpiryString(now: Date, expiresIn: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: now.addingTimeInterval(TimeInterval(expiresIn)))
}

// 解释器在 `<venv>/bin/python`，配置在旁边的 `lib/python*/site-packages/colab_cli/oauth_config.json`。
func colabOAuthConfigFile(pythonPath: String) -> String? {
    let python = URL(fileURLWithPath: pythonPath).resolvingSymlinksInPath()
    let binDirectory = python.deletingLastPathComponent()
    guard binDirectory.lastPathComponent == "bin" else {
        return nil
    }
    let lib = binDirectory.deletingLastPathComponent().appendingPathComponent("lib")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: lib,
        includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
        return nil
    }
    let matches = entries
        .filter { $0.lastPathComponent.hasPrefix("python") }
        .map { $0.appendingPathComponent("site-packages/colab_cli/oauth_config.json").path }
        .filter { FileManager.default.fileExists(atPath: $0) }
        .sorted()
    return matches.last
}

func loadColabOAuthClient(at path: String) throws -> ColabOAuthClient {
    guard isTrustedConfigFile(path) else {
        throw AccountFailure(.colabOAuthConfigMissing)
    }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw AccountFailure(.colabOAuthConfigMissing)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let installed = object["installed"] as? [String: Any],
          let clientID = installed["client_id"] as? String, !clientID.isEmpty,
          let clientSecret = installed["client_secret"] as? String, !clientSecret.isEmpty
    else {
        throw AccountFailure(.colabOAuthConfigMissing)
    }
    let authURI = httpsString(installed["auth_uri"]) ?? "https://accounts.google.com/o/oauth2/auth"
    let tokenURI = httpsString(installed["token_uri"]) ?? "https://oauth2.googleapis.com/token"
    return ColabOAuthClient(clientID: clientID, clientSecret: clientSecret, authURI: authURI, tokenURI: tokenURI)
}

func loadTrustedColabOAuthClient() throws -> ColabOAuthClient {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let cache = ToolLocations(home: home, provider: .colab).clientFile
    guard let installation = resolveColabInstallation(cacheURL: cache),
          let path = colabOAuthConfigFile(pythonPath: installation.pythonPath)
    else {
        throw AccountFailure(.colabOAuthConfigMissing)
    }
    return try loadColabOAuthClient(at: path)
}

func openSystemBrowser(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw AccountFailure(.colabBrowserFailed)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AccountFailure(.colabBrowserFailed)
    }
}

struct ColabBrowserSigner: ColabSigning {
    var http: any HTTPPosting = URLSessionPoster()
    var openURL: (URL) throws -> Void = openSystemBrowser
    var stdout: (String) -> Void
    var speak: (TextKey) -> String
    var stdin: Int32 = STDIN_FILENO
    var timeout: TimeInterval = 600
    var now: () -> Date = Date.init
    var loadClient: () throws -> ColabOAuthClient = loadTrustedColabOAuthClient
    var slice: TimeInterval = 0.2

    func signIn(handoff: Bool) throws -> String {
        let client = try loadClient()
        let deadline = now().addingTimeInterval(timeout)
        var failures = 0
        let loop = PKCEMaterial()
        let listener = try LoopbackListener()
        defer { listener.close() }
        let redirect = "http://127.0.0.1:\(listener.port)/"
        let url = colabAuthorizeURL(
            client: client,
            redirect: redirect,
            challenge: loop.challenge,
            state: loop.state,
            remote: false
        )
        if handoff {
            stdout("\(colabLoginLinePrefix) opened")
        } else {
            stdout(speak(.colabLoginOpening))
            stdout(speak(.colabLoginPressC))
        }
        try openURL(url)
        var stdinBuffer = StdinBuffer()
        let page = speak(.colabLoginPageDone)
        while now() < deadline {
            let event = try listener.poll(
                stdin: stdin,
                buffer: &stdinBuffer,
                slice: slice,
                state: loop.state,
                page: page
            )
            switch event {
            case .callback(let code):
                do {
                    return try exchange(code, verifier: loop.verifier, redirect: redirect, client: client)
                } catch is ExchangeRejected {
                    listener.allowAnother()
                    failures += 1
                    guard failures < 3 else {
                        throw AccountFailure(.colabLoginCancelled)
                    }
                    tellRetry(handoff)
                    try openURL(url)
                }
            case .line(let line):
                if handoff, line == "cancel" {
                    throw AccountFailure(.colabLoginCancelled)
                }
                let wantsCode = handoff ? line == "fallback" : (line == "c" || line == "C")
                if wantsCode {
                    return try remoteSignIn(
                        client: client,
                        handoff: handoff,
                        deadline: deadline,
                        failures: &failures,
                        buffer: &stdinBuffer
                    )
                }
            case .eof:
                throw AccountFailure(.colabLoginCancelled)
            case .slice:
                break
            }
        }
        throw AccountFailure(.colabLoginCancelled)
    }

    private func remoteSignIn(
        client: ColabOAuthClient,
        handoff: Bool,
        deadline: Date,
        failures: inout Int,
        buffer: inout StdinBuffer
    ) throws -> String {
        let remote = PKCEMaterial()
        let url = colabAuthorizeURL(
            client: client,
            redirect: colabRemoteRedirectURI,
            challenge: remote.challenge,
            state: remote.state,
            remote: true
        )
        if handoff {
            stdout("\(colabLoginLinePrefix) need-code")
        } else {
            stdout(speak(.colabLoginCodePrompt))
        }
        try openURL(url)
        while now() < deadline {
            let event = try waitStdin(buffer: &buffer, slice: slice)
            switch event {
            case .eof:
                throw AccountFailure(.colabLoginCancelled)
            case .slice:
                break
            case .line(let line):
                if handoff, line == "cancel" {
                    throw AccountFailure(.colabLoginCancelled)
                }
                if line.isEmpty || (handoff && line == "fallback") {
                    continue
                }
                guard isColabManualCode(line) else {
                    try noteRejection(handoff: handoff, failures: &failures)
                    continue
                }
                do {
                    return try exchange(line, verifier: remote.verifier, redirect: colabRemoteRedirectURI, client: client)
                } catch is ExchangeRejected {
                    try noteRejection(handoff: handoff, failures: &failures)
                }
            case .callback:
                break
            }
        }
        throw AccountFailure(.colabLoginCancelled)
    }

    private func noteRejection(handoff: Bool, failures: inout Int) throws {
        failures += 1
        if failures >= 3 {
            throw AccountFailure(.colabLoginCancelled)
        }
        tellRetry(handoff)
    }

    private func tellRetry(_ handoff: Bool) {
        if handoff {
            stdout("\(colabLoginLinePrefix) retry \(TextKey.colabLoginCodeRejected.rawValue)")
        } else {
            stdout(speak(.colabLoginCodeRejected))
        }
    }

    private func waitStdin(buffer: inout StdinBuffer, slice: TimeInterval) throws -> LoopbackEvent {
        if let line = buffer.popLine() {
            return .line(line)
        }
        var set = fd_set()
        var limit = Int32(0)
        fdInsert(stdin, into: &set, limit: &limit)
        var wait = timeval(tv_sec: 0, tv_usec: Int32(slice * 1_000_000))
        let ready = select(limit, &set, nil, nil, &wait)
        if ready < 0 {
            if errno == EINTR {
                return .slice
            }
            throw AccountFailure(.colabBrowserFailed)
        }
        if ready == 0 || !fdContains(stdin, set) {
            return .slice
        }
        return readStdin(buffer: &buffer)
    }

    private func readStdin(buffer: inout StdinBuffer) -> LoopbackEvent {
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(stdin, &bytes, bytes.count)
        if count == 0 {
            return .eof
        }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN {
                return .slice
            }
            return .eof
        }
        buffer.append(Data(bytes.prefix(count)))
        if let line = buffer.popLine() {
            return .line(line)
        }
        return .slice
    }

    private func exchange(
        _ code: String,
        verifier: String,
        redirect: String,
        client: ColabOAuthClient
    ) throws -> String {
        guard let tokenURL = URL(string: client.tokenURI), tokenURL.scheme == "https" else {
            throw ExchangeRejected()
        }
        let body = oauthFormEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
            ("redirect_uri", redirect),
            ("code_verifier", verifier),
        ])
        guard let response = http.post(HTTPRequest(
            url: tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 10
        )), response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty
        else {
            throw ExchangeRejected()
        }
        let scopes = scopeList(json["scope"]) ?? colabPublicScopes
        let expires = numberValue(json["expires_in"]) ?? 3600
        return try colabCredentialsJSON(
            accessToken: access,
            refreshToken: refresh,
            client: client,
            scopes: scopes,
            expiry: colabExpiryString(now: now(), expiresIn: expires)
        )
    }
}

private struct ExchangeRejected: Error {}

private struct PKCEMaterial {
    var verifier: String
    var challenge: String
    var state: String

    init() {
        verifier = base64URL(randomBytes(32))
        challenge = pkceS256Challenge(verifier)
        state = base64URL(randomBytes(16))
    }
}

private enum LoopbackEvent {
    case slice
    case eof
    case line(String)
    case callback(String)
}

struct StdinBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) {
        pending.append(data)
        if pending.count > 4096 {
            pending.removeFirst(pending.count - 4096)
        }
    }

    mutating func popLine() -> String? {
        guard let index = pending.firstIndex(of: 10) else {
            return nil
        }
        var chunk = Data(pending.prefix(upTo: index))
        pending.removeSubrange(..<pending.index(after: index))
        if chunk.last == 13 {
            chunk.removeLast()
        }
        return String(data: chunk, encoding: .utf8) ?? ""
    }
}

// 只绑 127.0.0.1 上系统分配的端口。Darwin 的 FD_SET 宏进不了 Swift，位运算要和 select 一起测。
final class LoopbackListener {
    private var descriptor: Int32 = -1
    private(set) var port: UInt16 = 0
    private var accepted = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AccountFailure(.colabBrowserFailed)
        }
        descriptor = fd
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close()
            throw AccountFailure(.colabBrowserFailed)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close()
            throw AccountFailure(.colabBrowserFailed)
        }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let namedOK = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard namedOK == 0 else {
            close()
            throw AccountFailure(.colabBrowserFailed)
        }
        port = UInt16(bigEndian: named.sin_port)
    }

    func allowAnother() {
        accepted = false
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        close()
    }

    fileprivate func poll(
        stdin: Int32,
        buffer: inout StdinBuffer,
        slice: TimeInterval,
        state: String,
        page: String
    ) throws -> LoopbackEvent {
        guard descriptor >= 0 else {
            throw AccountFailure(.colabBrowserFailed)
        }
        if let line = buffer.popLine() {
            return .line(line)
        }
        var set = fd_set()
        var limit = Int32(0)
        fdInsert(descriptor, into: &set, limit: &limit)
        if stdin >= 0 {
            fdInsert(stdin, into: &set, limit: &limit)
        }
        var wait = timeval(tv_sec: 0, tv_usec: Int32(max(slice, 0) * 1_000_000))
        let ready = select(limit, &set, nil, nil, &wait)
        if ready < 0 {
            if errno == EINTR {
                return .slice
            }
            throw AccountFailure(.colabBrowserFailed)
        }
        if ready == 0 {
            return .slice
        }
        if stdin >= 0, fdContains(stdin, set) {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = read(stdin, &bytes, bytes.count)
            if count == 0 {
                return .eof
            }
            if count > 0 {
                buffer.append(Data(bytes.prefix(count)))
                if let line = buffer.popLine() {
                    return .line(line)
                }
            }
        }
        if fdContains(descriptor, set), let code = acceptOne(state: state, page: page) {
            return .callback(code)
        }
        return .slice
    }

    // 对上 state 的那一次才收。别的请求回完就继续等，不把等待时间耗在一个不说话的连接上。
    private func acceptOne(state: String, page: String) -> String? {
        var clientAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &clientAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(descriptor, $0, &length)
            }
        }
        guard client >= 0 else {
            return nil
        }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = readHTTPRequest(client) else {
            writeHTTP(client, status: 404, body: "")
            return nil
        }
        guard !accepted else {
            writeHTTP(client, status: 404, body: "")
            return nil
        }
        guard request.path == "/" else {
            writeHTTP(client, status: 404, body: "")
            return nil
        }
        guard request.state == state, let code = request.code, isColabManualCode(code) else {
            writeHTTP(client, status: 400, body: "")
            return nil
        }
        accepted = true
        writeHTTP(client, status: 200, body: colabLoginPage(page))
        return code
    }
}

private struct HTTPRequestLine {
    var path: String
    var code: String?
    var state: String?
}

private func readHTTPRequest(_ fd: Int32) -> HTTPRequestLine? {
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while received.count < 8192 {
        let count = read(fd, &buffer, buffer.count)
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            break
        }
        received.append(buffer, count: count)
        if received.range(of: Data("\r\n\r\n".utf8)) != nil {
            break
        }
    }
    guard let text = String(data: received, encoding: .utf8) else {
        return nil
    }
    let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else {
        return nil
    }
    guard let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
        return nil
    }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] {
        query[item.name] = item.value ?? ""
    }
    return HTTPRequestLine(path: components.path, code: query["code"], state: query["state"])
}

private func writeHTTP(_ fd: Int32, status: Int, body: String) {
    let reason = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Not Found")
    let payload = Data(body.utf8)
    let head = "HTTP/1.0 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    var data = Data(head.utf8)
    data.append(payload)
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            return
        }
        var sent = 0
        while sent < raw.count {
            let count = Darwin.write(fd, base + sent, raw.count - sent)
            if count <= 0 {
                break
            }
            sent += count
        }
    }
}

private func colabLoginPage(_ message: String) -> String {
    let safe = htmlEscaped(message)
    return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(safe)</title></head><body><p>\(safe)</p></body></html>"
}

private func htmlEscaped(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func fdInsert(_ fd: Int32, into set: inout fd_set, limit: inout Int32) {
    guard fd >= 0 else {
        return
    }
    let index = Int(fd) / 32
    let mask = Int32(1) << Int32(Int(fd) % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) { tuple in
        tuple.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[index] |= mask
        }
    }
    if fd >= limit {
        limit = fd + 1
    }
}

private func fdContains(_ fd: Int32, _ set: fd_set) -> Bool {
    guard fd >= 0 else {
        return false
    }
    var copy = set
    let index = Int(fd) / 32
    let mask = Int32(1) << Int32(Int(fd) % 32)
    return withUnsafePointer(to: &copy.fds_bits) { tuple in
        tuple.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            (bits[index] & mask) != 0
        }
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255)
        }
    }
    return Data(bytes)
}

private func httpsString(_ value: Any?) -> String? {
    guard let text = value as? String, let url = URL(string: text), url.scheme == "https" else {
        return nil
    }
    return text
}

private func numberValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let text = value as? String {
        return Int(text)
    }
    return nil
}

private func scopeList(_ value: Any?) -> [String]? {
    guard let text = value as? String else {
        return nil
    }
    let scopes = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    return scopes.isEmpty ? nil : scopes
}

private func oauthFormEncoded(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
}
