import Darwin
import Foundation
import XCTest
@testable import AgyAccount

final class ColabLoginTests: XCTestCase {
    func testPKCES256MatchesTheRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(pkceS256Challenge(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLOmitsTokenUsageUntilTheRemotePage() {
        let client = sampleClient()
        let loopback = colabAuthorizeURL(
            client: client,
            redirect: "http://127.0.0.1:9/",
            challenge: "challenge",
            state: "state",
            remote: false
        )
        let remote = colabAuthorizeURL(
            client: client,
            redirect: colabRemoteRedirectURI,
            challenge: "challenge",
            state: "state",
            remote: true
        )
        let loopItems = URLComponents(url: loopback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let remoteItems = URLComponents(url: remote, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(loopItems.first { $0.name == "token_usage" })
        XCTAssertEqual(loopItems.first { $0.name == "redirect_uri" }?.value, "http://127.0.0.1:9/")
        XCTAssertEqual(loopItems.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(remoteItems.first { $0.name == "token_usage" }?.value, "remote")
        XCTAssertEqual(remoteItems.first { $0.name == "redirect_uri" }?.value, colabRemoteRedirectURI)
        XCTAssertEqual(loopItems.first { $0.name == "access_type" }?.value, "offline")
    }

    func testCodePatternsAndLoginLines() {
        let clipboard = "4/" + String(repeating: "A", count: 20)
        XCTAssertTrue(isColabClipboardCode(clipboard))
        XCTAssertTrue(isColabManualCode(clipboard))
        XCTAssertFalse(isColabClipboardCode("copied " + clipboard))
        XCTAssertTrue(isColabManualCode(String(repeating: "a", count: 20) + "/~"))
        XCTAssertFalse(isColabManualCode("short"))
        XCTAssertEqual(parseColabLoginLine("AGY_CS_LOGIN opened"), .opened)
        XCTAssertEqual(parseColabLoginLine("AGY_CS_LOGIN need-code"), .needCode)
        XCTAssertEqual(parseColabLoginLine("AGY_CS_LOGIN retry colabLoginCodeRejected"), .retry(.colabLoginCodeRejected))
        XCTAssertEqual(parseColabLoginLine("AGY_CS_LOGIN saved ada ada@example.com"), .saved(name: "ada", email: "ada@example.com"))
        XCTAssertEqual(parseColabLoginLine("AGY_CS_LOGIN error colabLoginCancelled"), .error(.colabLoginCancelled))
        XCTAssertEqual(parseColabLoginLine("AGY_CS_LOGIN saved only-three"), .ignored)
        XCTAssertEqual(parseColabLoginLine("hello"), .ignored)
    }

    func testCredentialsJSONHasOnlyTheColabKeys() throws {
        let client = sampleClient()
        let blob = try colabCredentialsJSON(
            accessToken: "access",
            refreshToken: "refresh",
            client: client,
            scopes: colabPublicScopes,
            expiry: colabExpiryString(now: Date(timeIntervalSince1970: 1_700_000_000), expiresIn: 60)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["account", "client_id", "client_secret", "expiry", "refresh_token", "scopes", "token", "token_uri", "universe_domain"]
        )
        XCTAssertEqual(object["account"] as? String, "")
        XCTAssertEqual(object["universe_domain"] as? String, "googleapis.com")
        XCTAssertEqual(object["expiry"] as? String, "2023-11-14T22:14:20Z")
        XCTAssertFalse(blob.contains("\n"))
        XCTAssertEqual(object["scopes"] as? [String], colabPublicScopes)
    }

    func testOAuthConfigIsReadFromTheVenvNextToPython() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = root.appendingPathComponent("lib/python3.13/site-packages/colab_cli", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let python = root.appendingPathComponent("bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8))
        let config = site.appendingPathComponent("oauth_config.json")
        try Data(
            #"{"installed":{"client_id":"id.apps.googleusercontent.com","client_secret":"test-secret","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#
                .utf8
        ).write(to: config)
        let found = try XCTUnwrap(colabOAuthConfigFile(pythonPath: python.path))
        XCTAssertEqual((found as NSString).resolvingSymlinksInPath, (config.path as NSString).resolvingSymlinksInPath)
        let loaded = try loadColabOAuthClient(at: found)
        XCTAssertEqual(loaded.clientID, "id.apps.googleusercontent.com")
        XCTAssertEqual(loaded.clientSecret, "test-secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: found)
        XCTAssertThrowsError(try loadColabOAuthClient(at: found)) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.colabOAuthConfigMissing))
        }
    }

    func testLoopbackCallbackRejectsABadStateThenAcceptsOneCode() throws {
        let code = "4/" + String(repeating: "b", count: 24)
        let pipes = try openPipe()
        defer {
            close(pipes.read)
            close(pipes.write)
        }
        var lines: [String] = []
        let http = LoginHTTP { request in
            let body = String(decoding: request.body, as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=authorization_code"))
            XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1"))
            XCTAssertFalse(body.contains("token_usage"))
            return tokenResponse(refresh: "refresh-loop")
        }
        let signer = makeSigner(http: http, lines: { lines.append($0) }, stdin: pipes.read) { url in
            DispatchQueue.global().async {
                guard let redirect = query(url, "redirect_uri"), let state = query(url, "state"), let port = URL(string: redirect)?.port else {
                    return
                }
                let bad = rawGET(port: UInt16(port), path: "/?code=\(code)&state=wrong")
                XCTAssertTrue(bad.contains("400"))
                let icon = rawGET(port: UInt16(port), path: "/favicon.ico")
                XCTAssertTrue(icon.contains("404"))
                let good = rawGET(port: UInt16(port), path: "/?code=\(code)&state=\(state)")
                XCTAssertTrue(good.contains("登录完成"))
            }
        }
        let blob = try signer.signIn(handoff: true)
        XCTAssertTrue(lines.contains("\(colabLoginLinePrefix) opened"))
        XCTAssertFalse(lines.joined(separator: "\n").contains(code))
        XCTAssertFalse(blob.contains(code))
        XCTAssertTrue(blob.contains("refresh-loop"))
    }

    func testCancelWritesNothingAndFallbackThenRetryKeepsTheVerifier() throws {
        let pipes = try openPipe()
        defer {
            close(pipes.read)
            close(pipes.write)
        }
        var lines: [String] = []
        let http = LoginHTTP { _ in nil }
        let signer = makeSigner(http: http, lines: { lines.append($0) }, stdin: pipes.read, timeout: 3) { _ in
            writeLine("cancel", pipes.write)
        }
        XCTAssertThrowsError(try signer.signIn(handoff: true)) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.colabLoginCancelled))
        }
        XCTAssertEqual(http.requests.count, 0)
        XCTAssertFalse(lines.joined(separator: "\n").contains("AGY_CS_LOGIN error"))

        let again = try openPipe()
        defer {
            close(again.read)
            close(again.write)
        }
        var verifiers: [String] = []
        var posts = 0
        let remoteCode = "4/" + String(repeating: "c", count: 24)
        let retryCode = "4/" + String(repeating: "d", count: 24)
        let http2 = LoginHTTP { request in
            let body = String(decoding: request.body, as: UTF8.self)
            if let verifier = formValue(body, "code_verifier") {
                verifiers.append(verifier)
            }
            posts += 1
            if posts == 1 {
                writeLine(retryCode, again.write)
                return HTTPResponse(status: 400, body: Data("{}".utf8))
            }
            XCTAssertTrue(body.contains("redirect_uri=https%3A%2F%2Fsdk.cloud.google.com"))
            return tokenResponse(refresh: "refresh-remote")
        }
        var opens: [URL] = []
        let signer2 = makeSigner(http: http2, lines: { lines.append($0) }, stdin: again.read) { url in
            opens.append(url)
            if opens.count == 1 {
                XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token_usage" })
                writeLine("fallback", again.write)
            } else {
                XCTAssertEqual(query(url, "token_usage"), "remote")
                XCTAssertEqual(query(url, "redirect_uri"), colabRemoteRedirectURI)
                writeLine(remoteCode, again.write)
            }
        }
        let blob = try signer2.signIn(handoff: true)
        XCTAssertEqual(verifiers.count, 2)
        XCTAssertEqual(verifiers[0], verifiers[1])
        XCTAssertTrue(lines.contains("\(colabLoginLinePrefix) need-code"))
        XCTAssertTrue(lines.contains("\(colabLoginLinePrefix) retry colabLoginCodeRejected"))
        XCTAssertFalse(lines.joined(separator: "\n").contains(remoteCode))
        XCTAssertFalse(lines.joined(separator: "\n").contains(retryCode))
        XCTAssertTrue(blob.contains("refresh-remote"))
    }

    func testCommandHandoffSaveAndUntouchedCancel() throws {
        let blob = makeColabBlob(refresh: "r-new")
        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com"))
        defer { fixture.cleanup() }
        let keychain = MemoryKeychain(makeColabBlob(refresh: "r-old"))
        let signer = ScriptedColabSigner()
        signer.failure = AccountFailure(.colabLoginCancelled)
        let refresher = ScriptedRefresher()
        fixture.colab = ProviderServices(
            keychain: keychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["r-old": "old@example.com", "r-new": "new@example.com"])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: refresher,
            signer: signer
        )
        let missing = fixture.run(["colab", "switch", "add"])
        XCTAssertEqual(missing.code, 2)
        XCTAssertEqual(keychain.blob, makeColabBlob(refresh: "r-old"))
        XCTAssertTrue(missing.errors.joined(separator: "\n").contains("终端"))

        let cancelled = fixture.run(["colab", "switch", "add", "--handoff"])
        XCTAssertEqual(cancelled.code, 1)
        XCTAssertEqual(cancelled.output.filter { $0.hasPrefix(colabLoginLinePrefix) }, ["AGY_CS_LOGIN error colabLoginCancelled"])
        XCTAssertEqual(keychain.writes.count, 0)
        XCTAssertFalse(cancelled.errors.joined(separator: "\n").contains("已恢复"))
        XCTAssertEqual(refresher.started, 0)

        signer.failure = nil
        signer.blob = blob
        fixture.terminal.isInteractive = true
        let saved = fixture.run(["colab", "switch", "add"])
        XCTAssertEqual(saved.code, 0)
        XCTAssertTrue(saved.output.contains { $0.contains("已保存") && $0.contains("new@example.com") })
        XCTAssertFalse(saved.output.joined(separator: "\n").contains("AGY_CS_LOGIN"))
        XCTAssertFalse(saved.output.joined(separator: "\n").contains("r-new"))
        XCTAssertEqual(refresher.started, 1)

        let handoff = fixture.run(["colab", "switch", "add", "--handoff"])
        XCTAssertEqual(handoff.code, 0)
        XCTAssertTrue(handoff.output.contains("AGY_CS_LOGIN saved new new@example.com"))
        XCTAssertFalse(handoff.output.joined(separator: "\n").contains("已保存"))
        XCTAssertFalse(handoff.output.joined(separator: "\n").contains("r-new"))
    }
}

private func sampleClient() -> ColabOAuthClient {
    ColabOAuthClient(
        clientID: "client.apps.googleusercontent.com",
        clientSecret: "test-secret",
        authURI: "https://accounts.google.com/o/oauth2/auth",
        tokenURI: "https://oauth2.googleapis.com/token"
    )
}

private func makeSigner(
    http: LoginHTTP,
    lines: @escaping (String) -> Void,
    stdin: Int32,
    timeout: TimeInterval = 5,
    openURL: @escaping (URL) throws -> Void
) -> ColabBrowserSigner {
    ColabBrowserSigner(
        http: http,
        openURL: openURL,
        stdout: lines,
        speak: { Localizer(language: .simplifiedChinese).line($0) },
        stdin: stdin,
        timeout: timeout,
        loadClient: sampleClient,
        slice: 0.05
    )
}

private func tokenResponse(refresh: String) -> HTTPResponse {
    let json = #"{"access_token":"ya29.access","refresh_token":"\#(refresh)","expires_in":3600,"scope":"openid"}"#
    return HTTPResponse(status: 200, body: Data(json.utf8))
}

private func query(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private func formValue(_ body: String, _ name: String) -> String? {
    for field in body.split(separator: "&") {
        let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.first == name {
            return pair.count == 2 ? pair[1].removingPercentEncoding : ""
        }
    }
    return nil
}

private func openPipe() throws -> (read: Int32, write: Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    guard pipe(&fds) == 0 else {
        throw POSIXError(.EPIPE)
    }
    return (fds[0], fds[1])
}

private func writeLine(_ line: String, _ fd: Int32) {
    var text = line + "\n"
    text.withUTF8 { bytes in
        _ = Darwin.write(fd, bytes.baseAddress, bytes.count)
    }
}

private func rawGET(port: UInt16, path: String) -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return ""
    }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        return ""
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        return ""
    }
    var request = "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    request.withUTF8 { bytes in
        _ = Darwin.write(fd, bytes.baseAddress, bytes.count)
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private final class LoginHTTP: HTTPPosting {
    var requests: [HTTPRequest] = []
    var respond: (HTTPRequest) -> HTTPResponse?

    init(_ respond: @escaping (HTTPRequest) -> HTTPResponse?) {
        self.respond = respond
    }

    func post(_ request: HTTPRequest) -> HTTPResponse? {
        requests.append(request)
        return respond(request)
    }
}


