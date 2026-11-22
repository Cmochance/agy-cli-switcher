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
        let localBin = root.appendingPathComponent(".local/bin", isDirectory: true)
        let unsafeBin = root.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unsafeBin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafeBin.path)

        let fakePython = venvBin.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: fakePython, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython.path)

        let directColab = binDir.appendingPathComponent("colab")
        try "#!\(fakePython.path)\nfrom colab_cli.cli import main\n".write(to: directColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directColab.path)

        let found = colabBinary(path: binDir.path, recorded: nil, home: root)
        XCTAssertEqual(found, directColab.path)
        XCTAssertEqual(colabPythonExecutable(for: directColab.path, path: binDir.path, home: root), fakePython.path)

        // env shebang resolution (via PATH and via trusted ~/.local/bin before system python3)
        let venvPythonCustom = venvBin.appendingPathComponent("python-venv-test")
        try "#!/bin/sh\nexit 0\n".write(to: venvPythonCustom, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: venvPythonCustom.path)

        let envColab = binDir.appendingPathComponent("colab-env")
        try "#!/usr/bin/env python-venv-test\nfrom colab_cli.cli import main\n".write(to: envColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: envColab.path)
        XCTAssertEqual(
            colabPythonExecutable(for: envColab.path, path: venvBin.path, home: root),
            venvPythonCustom.path
        )

        let localPython = localBin.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: localPython, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localPython.path)
        let envColabStd = binDir.appendingPathComponent("colab-env-std")
        try "#!/usr/bin/env python3\nfrom colab_cli.cli import main\n".write(to: envColabStd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: envColabStd.path)
        // `#!/usr/bin/env python3` honors trusted virtualenv PATH ahead of ~/.local/bin / system python3, while skipping world-writable PATH dirs.
        XCTAssertEqual(
            colabPythonExecutable(for: envColabStd.path, path: "\(unsafeBin.path):\(venvBin.path)", home: root),
            fakePython.path
        )
        XCTAssertEqual(
            colabPythonExecutable(for: envColabStd.path, path: "/usr/bin:/bin", home: root),
            localPython.path
        )

        // World-writable directory and safe child under a world-writable ancestor are both rejected.
        let worldColab = unsafeBin.appendingPathComponent("colab")
        try "#!\(fakePython.path)\nfrom colab_cli.cli import main\n".write(to: worldColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worldColab.path)
        XCTAssertNil(colabBinary(path: unsafeBin.path, recorded: nil, home: root))

        let nestedUnderWorld = unsafeBin.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedUnderWorld, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nestedUnderWorld.path)
        let nestedColab = nestedUnderWorld.appendingPathComponent("colab")
        try "#!\(fakePython.path)\nfrom colab_cli.cli import main\n".write(to: nestedColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nestedColab.path)
        XCTAssertFalse(isTrustedExecutablePath(nestedColab.path))
        XCTAssertNil(colabBinary(path: nestedUnderWorld.path, recorded: nil, home: root))

        // Direct python+script command construction bypasses /usr/bin/env re-lookup on launch.
        let whoamiSpec = InteractiveColab.whoamiCommand(for: ColabInstallation(colabPath: directColab.path, pythonPath: fakePython.path))
        XCTAssertEqual(whoamiSpec.executable, fakePython.path)
        XCTAssertEqual(whoamiSpec.arguments, [fakePython.path, directColab.path, "whoami"])

        // Launcher without colab_cli import or pointing to non-python interpreter is rejected (Fix #7).
        let decoyDir = root.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        let notColab = decoyDir.appendingPathComponent("colab")
        try "#!\(fakePython.path)\nprint('decoy')\n".write(to: notColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notColab.path)
        XCTAssertNil(colabBinary(path: decoyDir.path, recorded: nil, home: root))

        let badInterp = decoyDir.appendingPathComponent("sh")
        try "#!/bin/sh\nexit 0\n".write(to: badInterp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badInterp.path)
        let badShebangColab = decoyDir.appendingPathComponent("colab-bad")
        try "#!\(badInterp.path)\nfrom colab_cli.cli import main\n".write(to: badShebangColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badShebangColab.path)
        XCTAssertNil(colabPythonExecutable(for: badShebangColab.path, path: decoyDir.path, home: root))

        // Recorded virtualenv path works even with empty PATH (Fix #6).
        let cacheURL = root.appendingPathComponent("colab-client.json")
        let installed = resolveColabInstallation(cacheURL: cacheURL, path: binDir.path, home: root)
        XCTAssertEqual(installed, ColabInstallation(colabPath: directColab.path, pythonPath: fakePython.path))
        let fromCacheOnly = resolveColabInstallation(cacheURL: cacheURL, path: "", home: root)
        XCTAssertEqual(fromCacheOnly, ColabInstallation(colabPath: directColab.path, pythonPath: fakePython.path))

        // Standard ~/.local/bin takes precedence over unrecorded PATH entries (Fix #7).
        let trustedLocalColab = localBin.appendingPathComponent("colab")
        try "#!\(fakePython.path)\nfrom colab_cli.cli import main\n".write(to: trustedLocalColab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trustedLocalColab.path)
        XCTAssertEqual(colabBinary(path: binDir.path, recorded: nil, home: root), trustedLocalColab.path)
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

    func testFirstSwitchFromUnsavedColabBacksUpNewlyAutoSavedSessions() throws {
        let bob = makeColabBlob(refresh: "r-bob")
        let unsaved = makeColabBlob(refresh: "r-unsaved")

        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "r-agy"))
        defer { fixture.cleanup() }
        let colabKeychain = MemoryKeychain(bob)
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver([
                "r-bob": "bob@example.com",
                "r-unsaved": "unsaved@example.com",
            ])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )

        XCTAssertEqual(fixture.run(["colab", "save", "bob"]).code, 0)

        // User signs into a brand new account externally with active Colab sessions.
        colabKeychain.blob = unsaved
        let locations = AccountLocations(home: fixture.home, provider: .colab)
        try FileManager.default.createDirectory(at: locations.colabSessionsFile!.deletingLastPathComponent(), withIntermediateDirectories: true)
        let liveSessions = "{\"s1\":{\"endpoint\":\"gpu-unsaved\"}}\n"
        try Data(liveSessions.utf8).write(to: locations.colabSessionsFile!)

        // Switching away auto-saves `unsaved` AND backs up its live sessions under `unsaved`.
        XCTAssertEqual(fixture.run(["colab", "switch", "bob"]).code, 0)
        XCTAssertEqual(
            try String(contentsOf: locations.sessionsBackupURL("unsaved"), encoding: .utf8),
            liveSessions
        )
        XCTAssertEqual(try String(contentsOf: locations.colabSessionsFile!, encoding: .utf8), "{}\n")

        // Switching back to `unsaved` restores its sessions.
        XCTAssertEqual(fixture.run(["colab", "switch", "unsaved"]).code, 0)
        XCTAssertEqual(try String(contentsOf: locations.colabSessionsFile!, encoding: .utf8), liveSessions)
    }

    func testColabSwitchAbortsBeforeMutatingKeychainOrSessionsWhenBackupFails() throws {
        let alice = makeColabBlob(refresh: "r-alice")
        let bob = makeColabBlob(refresh: "r-bob")

        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "r-agy"))
        defer { fixture.cleanup() }
        let colabKeychain = MemoryKeychain(alice)
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver([
                "r-alice": "alice@example.com",
                "r-bob": "bob@example.com",
            ])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "alice"]).code, 0)
        colabKeychain.blob = bob
        XCTAssertEqual(fixture.run(["colab", "save", "bob"]).code, 0)
        XCTAssertEqual(fixture.run(["colab", "switch", "alice"]).code, 0)

        let locations = AccountLocations(home: fixture.home, provider: .colab)
        let priorBackup = "{\"old\":\"keep\"}\n"
        let liveSessions = "{\"new\":\"do-not-lose\"}\n"
        let liveAttached = "{\"att\":\"do-not-lose\"}\n"
        try Data(priorBackup.utf8).write(to: locations.sessionsBackupURL("alice"))
        try Data(liveSessions.utf8).write(to: locations.colabSessionsFile!)
        try Data(liveAttached.utf8).write(to: locations.colabAttachedSessionsFile!)

        // Unreadable live session file preserves prior backup, live files, and keychain.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locations.colabSessionsFile!.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locations.colabSessionsFile!.path)
            try? FileManager.default.removeItem(at: locations.attachedSessionsBackupURL("alice"))
        }
        let failedRead = fixture.run(["colab", "switch", "bob"])
        XCTAssertNotEqual(failedRead.code, 0)
        XCTAssertEqual(colabKeychain.blob, alice)
        XCTAssertEqual(try String(contentsOf: locations.sessionsBackupURL("alice"), encoding: .utf8), priorBackup)
        XCTAssertEqual(try String(contentsOf: locations.colabAttachedSessionsFile!, encoding: .utf8), liveAttached)

        // Restore readable live file, then make attached backup destination a non-empty directory so AtomicFile rename fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locations.colabSessionsFile!.path)
        let blockingDir = locations.attachedSessionsBackupURL("alice")
        try FileManager.default.createDirectory(at: blockingDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blockingDir.appendingPathComponent("inside"))

        let failedWrite = fixture.run(["colab", "switch", "bob"])
        XCTAssertNotEqual(failedWrite.code, 0)
        XCTAssertEqual(colabKeychain.blob, alice)
        XCTAssertEqual(try String(contentsOf: locations.colabSessionsFile!, encoding: .utf8), liveSessions)
        XCTAssertEqual(try String(contentsOf: locations.colabAttachedSessionsFile!, encoding: .utf8), liveAttached)
    }

    func testColabSaveForceChangingEmailClearsOldSessionsAndSameEmailKeepsThem() throws {
        let alice = makeColabBlob(refresh: "r-alice")
        let bob = makeColabBlob(refresh: "r-bob")
        let aliceRefreshed = makeColabBlob(token: "ya29.new", refresh: "r-alice")

        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "r-agy"))
        defer { fixture.cleanup() }
        let colabKeychain = MemoryKeychain(alice)
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver([
                "r-alice": "alice@example.com",
                "r-bob": "bob@example.com",
            ])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "work"]).code, 0)

        let locations = AccountLocations(home: fixture.home, provider: .colab)
        try Data("{\"alice\":true}\n".utf8).write(to: locations.sessionsBackupURL("work"))
        try Data("{\"aliceAtt\":true}\n".utf8).write(to: locations.attachedSessionsBackupURL("work"))

        // Re-saving same email keeps auxiliary session backups.
        colabKeychain.blob = aliceRefreshed
        XCTAssertEqual(fixture.run(["colab", "save", "work", "--force"]).code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.sessionsBackupURL("work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.attachedSessionsBackupURL("work").path))

        // Replacing with different email clears previous email's session backups.
        colabKeychain.blob = bob
        XCTAssertEqual(fixture.run(["colab", "save", "work", "--force"]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.sessionsBackupURL("work").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.attachedSessionsBackupURL("work").path))
    }

    func testColabAddMissingEmailRestoresPreviousLoginAndSurfacesError() throws {
        let alice = makeColabBlob(refresh: "r-alice")
        let noEmail = makeColabBlob(refresh: "r-noemail", expiry: "2020-01-01T00:00:00Z")

        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "r-agy"))
        defer { fixture.cleanup() }
        fixture.terminal.isInteractive = true
        let colabKeychain = MemoryKeychain(alice)
        let colabLauncher = ScriptedLauncher()
        colabLauncher.launchesAfterSwitch = false
        let missingEmailHTTP = StubColabHTTP { request in
            if request.url.path == "/token" {
                return HTTPResponse(status: 200, body: Data("{\"access_token\":\"tok\"}".utf8))
            }
            if request.url.path == "/tokeninfo" {
                return HTTPResponse(status: 200, body: Data("{\"azp\":\"client\"}".utf8))
            }
            return nil
        }
        let resolver = GoogleColabEmailResolver(http: missingEmailHTTP, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        // First initialize alice via save using static resolver, then replace with missing-email resolver for add.
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["r-alice": "alice@example.com"])),
            launcher: colabLauncher,
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "alice"]).code, 0)

        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: resolver),
            launcher: colabLauncher,
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        colabLauncher.supply = {
            colabKeychain.blob = noEmail
            colabKeychain.missing = false
        }
        let result = fixture.run(["colab", "switch", "add"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(colabKeychain.blob, alice)
        XCTAssertTrue(result.errors.joined(separator: "\n").contains("未包含邮箱"))
    }

    func testColabAddCompletesSessionSwapInsideStateLock() throws {
        let alice = makeColabBlob(refresh: "r-alice")
        let bob = makeColabBlob(refresh: "r-bob")

        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "r-agy"))
        defer { fixture.cleanup() }
        fixture.terminal.isInteractive = true
        let colabKeychain = MemoryKeychain(alice)
        let colabLauncher = ScriptedLauncher()
        colabLauncher.launchesAfterSwitch = false
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver([
                "r-alice": "alice@example.com",
                "r-bob": "bob@example.com",
            ])),
            launcher: colabLauncher,
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "alice"]).code, 0)

        let locations = AccountLocations(home: fixture.home, provider: .colab)
        try FileManager.default.createDirectory(at: locations.colabSessionsFile!.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aliceSessions = "{\"alice\":1}\n"
        try Data(aliceSessions.utf8).write(to: locations.colabSessionsFile!)

        let observedSwapBeforeUnlock = XCTestExpectation(description: "contending state lock sees completed session swap")
        var sessionsAtLockAcquisition = ""
        let colabProfile = ToolProfile(home: fixture.home, now: { "2026-01-01T00:00:00Z" }, preferredLanguages: ["zh-Hans"], provider: .colab)

        colabLauncher.supply = {
            DispatchQueue.global().async {
                guard let fd = colabProfile.lockState(wait: 5) else {
                    XCTFail("Failed to acquire state.lock")
                    return
                }
                defer { close(fd) }
                sessionsAtLockAcquisition = (try? String(contentsOf: locations.colabSessionsFile!, encoding: .utf8)) ?? ""
                observedSwapBeforeUnlock.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.08)
            colabKeychain.blob = bob
            colabKeychain.missing = false
        }

        XCTAssertEqual(fixture.run(["colab", "switch", "add"]).code, 0)
        wait(for: [observedSwapBeforeUnlock], timeout: 5)
        XCTAssertEqual(sessionsAtLockAcquisition, "{}\n")
        XCTAssertEqual(try String(contentsOf: locations.sessionsBackupURL("alice"), encoding: .utf8), aliceSessions)
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
