import Foundation
import XCTest
@testable import AgyAccount

final class StaticColabEmailResolver: ColabEmailResolving {
    var byRefresh: [String: String]
    var calls = 0

    init(_ byRefresh: [String: String] = [:]) {
        self.byRefresh = byRefresh
    }

    func resolveEmail(for token: ColabTokenPayload) throws -> String {
        calls += 1
        guard let email = byRefresh[token.refreshToken] else {
            throw AccountFailure(.colabEmailFailed)
        }
        return email
    }
}

func makeColabBlob(
    token: String = "ya29.access",
    refresh: String = "1//colab-refresh",
    clientID: String = "client-id.apps.googleusercontent.com",
    clientSecret: String = "placeholder-secret",
    expiry: String = "2026-12-01T00:00:00Z",
    tokenURI: String = "https://oauth2.googleapis.com/token"
) -> String {
    let payload: [String: Any] = [
        "token": token,
        "refresh_token": refresh,
        "client_id": clientID,
        "client_secret": clientSecret,
        "expiry": expiry,
        "token_uri": tokenURI,
        "account": "",
        "scopes": ["https://www.googleapis.com/auth/colaboratory"],
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private final class StubColabHTTP: HTTPPosting {
    var requests: [HTTPRequest] = []
    var respond: (HTTPRequest) -> HTTPResponse?

    init(_ respond: @escaping (HTTPRequest) -> HTTPResponse?) {
        self.respond = respond
    }

    func warm(_ url: URL) {}

    func post(_ request: HTTPRequest) -> HTTPResponse? {
        requests.append(request)
        return respond(request)
    }
}

private final class RecordingKeyringRunner: ColabKeyringRunning {
    var items: [String: String] = [:]
    var operations: [(op: String, service: String, account: String, value: String?)] = []
    var forcedStatus: Int32?
    var mismatchNextWrite = false

    func run(operation: String, service: String, account: String, value: String?) throws -> ColabKeyringResult {
        operations.append((operation, service, account, value))
        if let forcedStatus {
            return ColabKeyringResult(status: forcedStatus, output: Data())
        }
        let key = "\(service)|\(account)"
        switch operation {
        case "get":
            guard let found = items[key] else {
                return ColabKeyringResult(status: 44, output: Data())
            }
            return ColabKeyringResult(status: 0, output: Data(found.utf8))
        case "set":
            if mismatchNextWrite {
                mismatchNextWrite = false
                items[key] = "{\"tampered\":true}"
            } else if let value {
                items[key] = value
            }
            return ColabKeyringResult(status: 0, output: Data())
        case "delete":
            items.removeValue(forKey: key)
            return ColabKeyringResult(status: 0, output: Data())
        default:
            return ColabKeyringResult(status: 2, output: Data())
        }
    }
}

final class ColabTests: XCTestCase {
    func testColabBinaryAndPythonShebangResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let venvBin = root.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)

        let fakePython = venvBin.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: fakePython, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython.path)

        let directColab = binDir.appendingPathComponent("colab")
        try "#!\(fakePython.path)\nprint('hi')\n".write(to: directColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directColab.path)

        let found = colabBinary(path: binDir.path, recorded: nil, home: root)
        XCTAssertEqual(found, directColab.path)
        XCTAssertEqual(colabPythonExecutable(for: directColab.path, path: binDir.path, home: root), fakePython.path)

        // env shebang resolution
        let envColab = binDir.appendingPathComponent("colab-env")
        try "#!/usr/bin/env python3\n".write(to: envColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: envColab.path)
        XCTAssertEqual(
            colabPythonExecutable(for: envColab.path, path: venvBin.path, home: root),
            fakePython.path
        )
    }

    func testColabTokenParsingAndPartialScopeOAuthAndEmailResolution() throws {
        let blob = makeColabBlob(refresh: "r-new", expiry: "2020-01-01T00:00:00Z")
        let parsed = try parseColabToken(blob)
        XCTAssertEqual(parsed.refreshToken, "r-new")

        XCTAssertThrowsError(try parseColabToken("not-json")) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.colabLoginFormat))
        }
        XCTAssertThrowsError(try parseColabToken("{\"token\":\"only\"}")) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.colabLoginFormat))
        }

        // Token refresh omits scope (compatible with #235) and falls back to tokeninfo when id_token absent.
        let http = StubColabHTTP { request in
            if request.url.path == "/token" {
                let body = String(data: request.body, encoding: .utf8) ?? ""
                XCTAssertFalse(body.contains("scope="))
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                return HTTPResponse(status: 200, body: Data("{\"access_token\":\"fresh-access\"}".utf8))
            }
            if request.url.path == "/tokeninfo" {
                return HTTPResponse(status: 200, body: Data("{\"email\":\"partial@example.com\"}".utf8))
            }
            return nil
        }
        let resolver = GoogleColabEmailResolver(http: http, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let email = try resolver.resolveEmail(for: parsed)
        XCTAssertEqual(email, "partial@example.com")

        // When tokeninfo omits email field, emit .colabMissingEmail cleanly.
        let missingScopeHTTP = StubColabHTTP { request in
            if request.url.path == "/token" {
                return HTTPResponse(status: 200, body: Data("{\"access_token\":\"fresh-access\"}".utf8))
            }
            return HTTPResponse(status: 200, body: Data("{\"azp\":\"client\"}".utf8))
        }
        let missingResolver = GoogleColabEmailResolver(http: missingScopeHTTP, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        XCTAssertThrowsError(try missingResolver.resolveEmail(for: parsed)) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.colabMissingEmail))
        }
    }

    func testColabKeyringStoreProtocolErrorsAndRollback() throws {
        let runner = RecordingKeyringRunner()
        let store = ColabKeychainStore(runner: runner)
        XCTAssertThrowsError(try store.readBlob()) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.keychainMissing))
        }

        runner.forcedStatus = 51
        XCTAssertThrowsError(try store.readBlob()) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.keychainDenied))
        }
        runner.forcedStatus = nil

        let valid1 = makeColabBlob(refresh: "r1")
        let valid2 = makeColabBlob(refresh: "r2")
        try store.writeBlob(valid1)
        XCTAssertEqual(try store.readBlob(), valid1)

        // Write verification mismatch rolls back to original.
        runner.mismatchNextWrite = true
        XCTAssertThrowsError(try store.writeBlob(valid2)) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.writeMismatch))
        }
        XCTAssertEqual(try store.readBlob(), valid1)

        try store.deleteBlob()
        XCTAssertThrowsError(try store.readBlob()) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.keychainMissing))
        }
    }

    func testColabCcuInfoXssiAndUsageFetcher() throws {
        let raw = Data(")]}'\n{\"currentBalance\":87.5,\"consumptionRateHourly\":1.96,\"assignmentsCount\":2}".utf8)
        let parsed = parseColabCcuInfo(raw)
        XCTAssertEqual(parsed, ColabUsageData(balance: 87.5, rateHourly: 1.96, activeAssignments: 2))

        let http = StubColabHTTP { request in
            if request.url.host == "oauth2.googleapis.com" {
                return HTTPResponse(status: 200, body: Data("{\"access_token\":\"tok-1\"}".utf8))
            }
            if request.url == ColabUsageFetcher.ccuInfoURL {
                XCTAssertEqual(request.method, "GET")
                XCTAssertEqual(request.headers["Authorization"], "Bearer tok-1")
                XCTAssertEqual(request.headers["X-Colab-Client-Agent"], "colab-cli")
                return HTTPResponse(status: 200, body: raw)
            }
            return nil
        }
        let fetcher = ColabUsageFetcher(http: http, budget: 5)
        let result = fetcher.fetch([(name: "alice", blob: makeColabBlob(refresh: "r1"), project: "")], within: 5)
        XCTAssertEqual(result["alice"]?.colab, ColabUsageData(balance: 87.5, rateHourly: 1.96, activeAssignments: 2))
    }

    func testColabCLILifecycleIsolationAndStateSync() throws {
        let blob1 = makeColabBlob(refresh: "r-alice")
        let blob2 = makeColabBlob(refresh: "r-bob")
        let blob3 = makeColabBlob(refresh: "r-carol")

        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "r-agy"), markInitialized: true)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "agy"]).code, 0)

        let colabKeychain = MemoryKeychain(blob1)
        let resolver = StaticColabEmailResolver([
            "r-alice": "alice@example.com",
            "r-bob": "bob@example.com",
            "r-carol": "carol@example.com",
        ])
        let colabLauncher = ScriptedLauncher()
        colabLauncher.launchesAfterSwitch = false
        let colabUsage = ScriptedUsage()
        let colabRefresher = ScriptedRefresher()
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: resolver),
            launcher: colabLauncher,
            usage: colabUsage,
            refresher: colabRefresher
        )

        // First run of `colab current` initializes and saves the unseen keychain login, resolving email once.
        let firstCurrent = fixture.run(["colab", "current"])
        XCTAssertEqual(firstCurrent.code, 0)
        XCTAssertEqual(firstCurrent.output, ["已初始化当前登录: alice  alice@example.com", "alice@example.com"])
        XCTAssertEqual(resolver.calls, 1)

        // Subsequent reads match refresh_token offline (zero email resolver calls).
        XCTAssertEqual(fixture.run(["colab", "current"]).output, ["alice@example.com"])
        XCTAssertEqual(fixture.run(["colab", "ls"]).code, 0)
        XCTAssertEqual(resolver.calls, 1)

        // Prepare Colab session/settings/history/log files for alice.
        let colabLocations = AccountLocations(home: fixture.home, provider: .colab)
        let colabRoot = colabLocations.sessionsBackupURL("x").deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: colabRoot.appendingPathComponent("history"), withIntermediateDirectories: true)
        let historyFile = colabRoot.appendingPathComponent("history/keep.txt")
        let logFile = colabRoot.appendingPathComponent("colab.log")
        try Data("hist".utf8).write(to: historyFile)
        try Data("log".utf8).write(to: logFile)
        try Data("{\"t1\":{\"endpoint\":\"gpu\"}}\n".utf8).write(to: colabLocations.colabSessionsFile!)
        try Data("{\"a1\":{\"attached\":true}}\n".utf8).write(to: colabLocations.colabAttachedSessionsFile!)
        try Data("{\"public_api_supported\":true,\"tunnel_api_supported\":true,\"ui_mode\":\"tui\"}\n".utf8)
            .write(to: colabLocations.colabSettingsFile!)

        // Save bob and refresh usage.
        colabKeychain.blob = blob2
        XCTAssertEqual(fixture.run(["colab", "save", "bob"]).code, 0)
        colabUsage.snapshots = [
            "alice": UsageSnapshot(planID: "", planName: "", buckets: [], colab: ColabUsageData(balance: 120.5, rateHourly: 2.0, activeAssignments: 1)),
            "bob": UsageSnapshot(planID: "", planName: "", buckets: [], colab: ColabUsageData(balance: 9.0, rateHourly: 0, activeAssignments: 0)),
        ]
        XCTAssertEqual(fixture.run(["colab", "refresh", "quota"]).code, 0)
        let listed = fixture.run(["colab", "ls"])
        XCTAssertEqual(listed.code, 0)
        XCTAssertTrue(listed.output.contains { $0.contains("120.50 CU") && $0.contains("2.00/hr") && $0.contains("1 active") })

        // Switch back to alice -> backs up bob's (current active at save was bob, whose sessions came from files), restores/resets.
        // Wait: current keychain is bob right now; let's switch to alice!
        let sw = fixture.run(["colab", "switch", "alice"])
        XCTAssertEqual(sw.code, 0)
        XCTAssertEqual(colabLauncher.started, 0)
        XCTAssertTrue(sw.output.contains { $0.contains("云端继续运行") })
        XCTAssertFalse(sw.output.contains { $0.contains("reopen") || $0.contains("agy") })

        // Since bob was active when sessions were non-empty, bob got backed up and alice (no prior backup) cleared live sessions to {}.
        XCTAssertTrue(FileManager.default.fileExists(atPath: colabLocations.sessionsBackupURL("bob").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: colabLocations.attachedSessionsBackupURL("bob").path))
        XCTAssertEqual(try String(contentsOf: colabLocations.colabSessionsFile!, encoding: .utf8), "{}\n")
        XCTAssertEqual(try String(contentsOf: colabLocations.colabAttachedSessionsFile!, encoding: .utf8), "{}\n")

        // settings.json reset capability flags to null while keeping ui_mode.
        let settingsObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: colabLocations.colabSettingsFile!)) as? [String: Any]
        )
        XCTAssertTrue(settingsObj["public_api_supported"] is NSNull)
        XCTAssertTrue(settingsObj["tunnel_api_supported"] is NSNull)
        XCTAssertEqual(settingsObj["ui_mode"] as? String, "tui")

        // history/ and colab.log untouched.
        XCTAssertEqual(try String(contentsOf: historyFile, encoding: .utf8), "hist")
        XCTAssertEqual(try String(contentsOf: logFile, encoding: .utf8), "log")

        // Switch back to bob restores bob's sessions.
        XCTAssertEqual(fixture.run(["colab", "switch", "bob"]).code, 0)
        let restoredSessions = try String(contentsOf: colabLocations.colabSessionsFile!, encoding: .utf8)
        XCTAssertTrue(restoredSessions.contains("endpoint"))

        // Colab `switch add` adds carol and does NOT relaunch after switch.
        fixture.terminal.isInteractive = true
        colabLauncher.supply = {
            colabKeychain.blob = blob3
            colabKeychain.missing = false
        }
        XCTAssertEqual(fixture.run(["colab", "switch", "add"]).code, 0)
        XCTAssertEqual(colabLauncher.started, 0)
        XCTAssertEqual(fixture.run(["colab", "current"]).output, ["carol@example.com"])

        // Antigravity remains isolated and untouched.
        XCTAssertEqual(fixture.run(["current"]).output, ["agy@example.com"])
        XCTAssertEqual(fixture.run(["ls"]).output.count, 1)
    }

    // Opt-in real Python keyring round-trip against a probe item:
    //   AGY_COLAB_PROBE=1 make test FILTER=testColabKeychainRoundTripWhenEnabled
    func testColabKeychainRoundTripWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGY_COLAB_PROBE"] == "1" else {
            return
        }
        guard colabBinary(recorded: nil) != nil else {
            XCTFail("colab binary not found for AGY_COLAB_PROBE")
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runner = PythonKeyringRunner(cacheURL: tmp.appendingPathComponent("colab-client.json"))
        let probeService = "agy-cs-test-probe"
        let store = ColabKeychainStore(runner: runner, service: probeService, account: "oauth_token")
        defer { try? store.deleteBlob() }
        try? store.deleteBlob()

        let sample = makeColabBlob(refresh: "probe-refresh-token")
        try store.writeBlob(sample)
        XCTAssertEqual(try store.readBlob(), sample)
        try store.deleteBlob()
        XCTAssertThrowsError(try store.readBlob()) { error in
            XCTAssertEqual(error as? AccountFailure, AccountFailure(.keychainMissing))
        }
    }

    // Opt-in live Colab usage fetch using saved local Colab login(s) (prints zero secrets):
    //   AGY_COLAB_USAGE_LIVE=1 make test FILTER=testLiveColabUsageFetchWhenEnabled
    func testLiveColabUsageFetchWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGY_COLAB_USAGE_LIVE"] == "1" else {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let store = ColabKeychainStore(cacheURL: ToolLocations(home: home, provider: .colab).clientFile)
        let files = AccountFiles(locations: AccountLocations(home: home, provider: .colab), now: AccountClock.utcTimestamp, codec: ColabLoginCodec())
        let codec = ColabLoginCodec()
        var logins: [(name: String, blob: String, project: String)] = []
        for name in files.savedNames() {
            if let saved = try? files.readSaved(name) {
                logins.append((name, saved.blob, ""))
            }
        }
        if logins.isEmpty, let blob = try? store.readBlob() {
            _ = try codec.decodeKeychain(blob, lookupEmailByBlob: { _ in nil })
            logins.append(("keychain", blob, ""))
        }
        XCTAssertFalse(logins.isEmpty, "No local Colab login found for AGY_COLAB_USAGE_LIVE=1")
        let fetched = ColabUsageFetcher().fetch(logins, within: 10)
        XCTAssertEqual(fetched.count, logins.count)
        for (name, snapshot) in fetched {
            let ccu = try XCTUnwrap(snapshot.colab, "Missing colab data for \(name)")
            print("COLAB_LIVE name=\(name) balance=\(ccu.balance) rate=\(ccu.rateHourly) active=\(ccu.activeAssignments)")
        }
    }
}
