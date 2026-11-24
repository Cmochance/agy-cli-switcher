import Darwin
import Foundation
import XCTest
@testable import AgyAccount
@testable import AgyMenuBar

final class GuardTests: XCTestCase {
    func testGuardCLICommandsAndColabRejection() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)

        let offStatus = fixture.run(["guard"])
        XCTAssertEqual(offStatus.code, 0)
        XCTAssertTrue(offStatus.output.contains("禁止旧会话回写登录: 已关闭"))

        let badUsage = fixture.run(["guard", "bogus"])
        XCTAssertEqual(badUsage.code, 2)

        let onResult = fixture.run(["guard", "on"])
        XCTAssertEqual(onResult.code, 0)
        XCTAssertEqual(onResult.output, ["已开启禁止旧会话回写登录。"])
        XCTAssertTrue(ToolProfile(home: fixture.home, now: { "" }, preferredLanguages: []).blockOldWritebackEnabled())

        let onStatus = fixture.run(["guard"])
        XCTAssertEqual(onStatus.code, 0)
        XCTAssertTrue(onStatus.output.contains("禁止旧会话回写登录: 已开启"))

        let offResult = fixture.run(["guard", "off"])
        XCTAssertEqual(offResult.code, 0)
        XCTAssertEqual(offResult.output, ["已关闭禁止旧会话回写登录。"])
        XCTAssertFalse(ToolProfile(home: fixture.home, now: { "" }, preferredLanguages: []).blockOldWritebackEnabled())

        fixture.colab = ProviderServices(
            keychain: MemoryKeychain(makeColabBlob(refresh: "colab-1")),
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["colab-1": "researcher@example.com"])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        let colabGuard = fixture.run(["colab", "guard"])
        XCTAssertEqual(colabGuard.code, 2)
    }

    @MainActor
    func testPanelBoardReflectsAndTogglesBlockOldWriteback() async throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)

        let model = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        XCTAssertFalse(model.state.blockOldWriteback)

        model.toggleBlockOldWriteback()
        for _ in 0 ..< 200 where model.busy != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.state.blockOldWriteback)
        XCTAssertEqual(model.messages, ["已开启禁止旧会话回写登录。"])

        model.toggleBlockOldWriteback()
        for _ in 0 ..< 200 where model.busy != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.state.blockOldWriteback)
        XCTAssertEqual(model.messages, ["已关闭禁止旧会话回写登录。"])
    }

    func testSwitchArmsGuardOnlyWhenEnabledAndAgyRunning() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)

        // 默认关闭：不写 guard.json，不拉起 worker。
        fixture.processes.pids = [42]
        XCTAssertEqual(fixture.run(["switch", "alice"]).code, 0)
        XCTAssertEqual(fixture.guarder.started, 0)
        XCTAssertNil(profile(for: fixture).readGuardState())

        // 开启但没有运行中的 agy：不写 guard.json，不拉起 worker。
        fixture.processes.pids = []
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)
        XCTAssertEqual(fixture.guarder.started, 0)
        XCTAssertNil(profile(for: fixture).readGuardState())
    }

    func testGuardRestoresTargetWithoutOverwritingSavedOldBackup() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a-clean")
        let bob = makeBlob(email: "bob@example.com", refresh: "b-clean")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)

        fixture.processes.pids = [101]
        let switched = fixture.run(["switch", "bob"])
        XCTAssertEqual(switched.code, 0)
        XCTAssertEqual(fixture.guarder.started, 1)
        XCTAssertTrue(switched.output.contains("正在运行的 agy 仍使用旧登录: 101（已监控，回写时会自动恢复为当前账号）。"))

        let state = try XCTUnwrap(profile(for: fixture).readGuardState())
        XCTAssertEqual(state.targetName, "bob")
        XCTAssertEqual(state.targetEmail, "bob@example.com")
        XCTAssertEqual(state.guardedEmails, ["alice@example.com"])
        XCTAssertEqual(state.processes, [TrackedProcess(pid: 101, startSec: 1, startUsec: 0)])

        // 模拟旧会话读取钥匙串做 Read-Modify-Write，混入新账号的 project_id 后写回。
        let pollutedWriteback = makeMixedBlob(email: "alice@example.com", refresh: "a-clean", access: "short-lived-access", projectID: "bob-project")
        fixture.keychain.blob = pollutedWriteback

        var now = Date(timeIntervalSince1970: 1_000)
        var engine = makeEngine(fixture: fixture, clock: { now })
        XCTAssertEqual(engine.step(), .restored("bob@example.com"))
        XCTAssertEqual(fixture.keychain.blob, bob)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quota.path))

        // 严禁把旧会话回写的混合 blob 覆盖回 alice 的干净副本。
        let aliceBackup = stripNewlines(try String(contentsOf: fixture.locations.tokenURL("alice"), encoding: .utf8))
        XCTAssertEqual(aliceBackup, alice)
        XCTAssertNotEqual(aliceBackup, pollutedWriteback)

        // 钥匙串已经等于 bob 时再次检查，保持 idle。
        now.addTimeInterval(1)
        XCTAssertEqual(engine.step(), .idle)
    }

    func testMultiHopAndSwitchBackToOldAccount() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let carol = makeBlob(email: "carol@example.com", refresh: "c")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = carol
        XCTAssertEqual(fixture.run(["save", "carol"]).code, 0)
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)

        fixture.processes.pids = [101]
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)
        fixture.processes.pids = [101, 202]
        XCTAssertEqual(fixture.run(["switch", "carol"]).code, 0)

        let stateC = try XCTUnwrap(profile(for: fixture).readGuardState())
        XCTAssertEqual(stateC.targetEmail, "carol@example.com")
        XCTAssertEqual(Set(stateC.guardedEmails), Set(["alice@example.com", "bob@example.com"]))

        var engine = makeEngine(fixture: fixture)
        fixture.keychain.blob = alice
        XCTAssertEqual(engine.step(), .restored("carol@example.com"))
        XCTAssertEqual(fixture.keychain.blob, carol)

        fixture.keychain.blob = bob
        XCTAssertEqual(engine.step(), .restored("carol@example.com"))
        XCTAssertEqual(fixture.keychain.blob, carol)

        // 切回旧号 alice 后，alice 不再在 guardedEmails 中，回写 alice 不再被改走。
        XCTAssertEqual(fixture.run(["switch", "alice"]).code, 0)
        let stateA = try XCTUnwrap(profile(for: fixture).readGuardState())
        XCTAssertEqual(stateA.targetEmail, "alice@example.com")
        XCTAssertFalse(stateA.guardedEmails.contains("alice@example.com"))
        XCTAssertTrue(stateA.guardedEmails.contains("bob@example.com"))
        XCTAssertTrue(stateA.guardedEmails.contains("carol@example.com"))

        fixture.keychain.blob = makeBlob(email: "alice@example.com", refresh: "a-refreshed")
        XCTAssertEqual(engine.step(), .idle)
        XCTAssertEqual(fixture.keychain.blob, makeBlob(email: "alice@example.com", refresh: "a-refreshed"))
    }

    func testGuardOnAfterSwitchingArmsProtectionImmediately() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)

        fixture.processes.pids = [303]
        let on = fixture.run(["guard", "on"])
        XCTAssertEqual(on.code, 0)
        XCTAssertEqual(fixture.guarder.started, 1)
        XCTAssertTrue(on.output.contains("正在监控以下旧 agy 进程的回写: 303"))

        fixture.keychain.blob = alice
        var engine = makeEngine(fixture: fixture)
        XCTAssertEqual(engine.step(), .restored("bob@example.com"))
        XCTAssertEqual(fixture.keychain.blob, bob)
    }

    func testPIDReuseStopsGuardWhenStartTimeDiffers() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)

        let timed = TimedProcesses()
        timed.list = [TrackedProcess(pid: 555, startSec: 100, startUsec: 20)]
        let services = CommandServices(
            home: fixture.home,
            keychain: fixture.keychain,
            processes: timed,
            now: { "2026-01-01T00:00:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: fixture.terminal,
            launcher: fixture.launcher,
            usage: fixture.usage,
            refresher: fixture.refresher,
            guarder: fixture.guarder
        )
        var out: [String] = []
        var err: [String] = []
        XCTAssertEqual(AgyAccountCLI.execute(["switch", "bob"], services: services, stdout: { out.append($0) }, stderr: { err.append($0) }).code, 0)
        XCTAssertNotNil(profile(for: fixture).readGuardState())

        // 同一 PID 被新启动的进程复用（startSec 变化）：应判定旧进程已退场，停止监控。
        timed.list = [TrackedProcess(pid: 555, startSec: 200, startUsec: 99)]
        fixture.keychain.blob = alice
        var engine = WritebackGuardEngine(
            files: AccountFiles(locations: fixture.locations, now: { "2026-01-01T00:00:00Z" }),
            profile: profile(for: fixture),
            keychain: fixture.keychain,
            processes: timed
        )
        XCTAssertEqual(engine.step(), .stopped)
        XCTAssertEqual(fixture.keychain.blob, alice)
        XCTAssertNil(profile(for: fixture).readGuardState())
    }

    func testLogoutOrUnknownNewEmailStopsGuardWithoutOverwriting() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let dave = makeBlob(email: "dave@example.com", refresh: "d")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)
        fixture.processes.pids = [404]

        // 1. /logout 使钥匙串变空：停止监控且不写回。
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)
        fixture.keychain.missing = true
        var engine = makeEngine(fixture: fixture)
        XCTAssertEqual(engine.step(), .stopped)
        XCTAssertTrue(fixture.keychain.missing)
        XCTAssertNil(profile(for: fixture).readGuardState())

        // 2. 外部登录未知新账号 dave：停止监控且不覆盖 dave。
        fixture.keychain.missing = false
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)
        XCTAssertNotNil(profile(for: fixture).readGuardState())
        fixture.keychain.blob = dave
        XCTAssertEqual(engine.step(), .stopped)
        XCTAssertEqual(fixture.keychain.blob, dave)
        XCTAssertNil(profile(for: fixture).readGuardState())
    }

    func testYieldsOnStateLockAndRollbackAndStopsAfterRenameOrRemove() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)
        fixture.processes.pids = [505]
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)

        var engine = makeEngine(fixture: fixture)
        fixture.keychain.blob = alice

        // state.lock 被占用时避让。
        let lockFD = try XCTUnwrap(profile(for: fixture).lockState(wait: 1))
        XCTAssertEqual(engine.step(), .retrySoon)
        XCTAssertEqual(fixture.keychain.blob, alice)
        close(lockFD)

        // 存在 .add-rollback 时避让。
        let files = AccountFiles(locations: fixture.locations, now: { "2026-01-01T00:00:00Z" })
        try files.writeRollback(alice)
        XCTAssertEqual(engine.step(), .retrySoon)
        XCTAssertEqual(fixture.keychain.blob, alice)
        files.removeRollback()

        // 恢复后，rename 目标账号仍能正常工作；rm --force 删除唯一副本后停止。
        XCTAssertEqual(fixture.run(["rename", "bob", "work"]).code, 0)
        XCTAssertEqual(try XCTUnwrap(profile(for: fixture).readGuardState()).targetName, "work")
        fixture.keychain.blob = alice
        XCTAssertEqual(engine.step(), .restored("bob@example.com"))
        XCTAssertEqual(fixture.keychain.blob, bob)

        XCTAssertEqual(fixture.run(["rm", "work", "--force"]).code, 0)
        XCTAssertNil(profile(for: fixture).readGuardState())
        XCTAssertEqual(engine.step(), .stopped)
    }

    func testCircuitBreakerStopsAfterFiveRestoresWithinOneMinute() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = alice
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)
        fixture.processes.pids = [606]
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)

        var now = Date(timeIntervalSince1970: 5_000)
        var engine = makeEngine(fixture: fixture, clock: { now })
        for stepIndex in 0 ..< 5 {
            now = Date(timeIntervalSince1970: 5_000 + Double(stepIndex))
            fixture.keychain.blob = alice
            XCTAssertEqual(engine.step(), .restored("bob@example.com"))
        }
        now = Date(timeIntervalSince1970: 5_010)
        fixture.keychain.blob = alice
        XCTAssertEqual(engine.step(), .stopped)
        XCTAssertEqual(fixture.keychain.blob, alice)
        XCTAssertNil(profile(for: fixture).readGuardState())
    }

    func testWatcherRestoresOnKeychainFileChangeAndExitsWhenProcessEnds() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        XCTAssertEqual(fixture.run(["guard", "on"]).code, 0)

        let keychainDir = fixture.home.appendingPathComponent("FakeKeychains", isDirectory: true)
        try FileManager.default.createDirectory(at: keychainDir, withIntermediateDirectories: true)
        let dbFile = keychainDir.appendingPathComponent("login.keychain-db")
        try Data("v1".utf8).write(to: dbFile)

        // 启动一个真实短命子进程，通过 SystemProcessList 解析其真实启动时间。
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        var info = proc_bsdinfo()
        let got = proc_pidinfo(child.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        XCTAssertEqual(got, Int32(MemoryLayout<proc_bsdinfo>.stride))
        let tracked = TrackedProcess(
            pid: child.processIdentifier,
            startSec: UInt64(info.pbi_start_tvsec),
            startUsec: UInt64(info.pbi_start_tvusec)
        )
        let systemProcesses = SystemProcessList()
        XCTAssertTrue(systemProcesses.isProcessAlive(tracked))

        let state = GuardState(
            targetName: "bob",
            targetEmail: "bob@example.com",
            guardedEmails: ["alice@example.com"],
            processes: [tracked],
            updatedAt: "2026-01-01T00:00:00Z"
        )
        try profile(for: fixture).writeGuardState(state)

        let watcher = WritebackGuardWatcher(
            home: fixture.home,
            keychain: fixture.keychain,
            processes: systemProcesses,
            now: { "2026-01-01T00:00:00Z" },
            keychainDirectory: keychainDir,
            debounceInterval: 0.05,
            fallbackInterval: 30
        )

        let finished = XCTestExpectation(description: "watcher exits after watched process terminates")
        DispatchQueue.global(qos: .userInitiated).async {
            watcher.run()
            finished.fulfill()
        }

        // 等 watcher 挂好监听后，模拟旧进程写回钥匙串并触发文件变化。
        Thread.sleep(forTimeInterval: 0.2)
        fixture.keychain.blob = alice
        try Data("v2".utf8).write(to: dbFile)

        var restored = false
        for _ in 0 ..< 40 {
            if fixture.keychain.blob == bob {
                restored = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(restored)

        // 结束被标记的进程：EVFILT_PROC NOTE_EXIT 应立刻唤醒并退出。
        child.terminate()
        child.waitUntilExit()
        wait(for: [finished], timeout: 3.0)
        XCTAssertNil(profile(for: fixture).readGuardState())
    }

    private func profile(for fixture: Fixture) -> ToolProfile {
        ToolProfile(home: fixture.home, now: { "2026-01-01T00:00:00Z" }, preferredLanguages: ["zh-Hans"])
    }

    private func makeEngine(fixture: Fixture, clock: @escaping () -> Date = Date.init) -> WritebackGuardEngine {
        WritebackGuardEngine(
            files: AccountFiles(locations: fixture.locations, now: { "2026-01-01T00:00:00Z" }),
            profile: profile(for: fixture),
            keychain: fixture.keychain,
            processes: fixture.processes,
            clock: clock
        )
    }

    private func makeMixedBlob(email: String, refresh: String, access: String, projectID: String) -> String {
        let object: [String: Any] = [
            "id_token_email": email,
            "auth_method": "consumer",
            "project_id": projectID,
            "token": [
                "refresh_token": refresh,
                "access_token": access,
                "expiry": "2026-01-01T01:00:00Z",
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "go-keyring-base64:" + data.base64EncodedString()
    }
}

private final class TimedProcesses: ProcessListing {
    var list: [TrackedProcess] = []

    func runningAgyPIDs() -> [Int] {
        list.map { Int($0.pid) }
    }

    func runningAgyProcesses() -> [TrackedProcess] {
        list
    }

    func isProcessAlive(_ process: TrackedProcess) -> Bool {
        list.contains(process)
    }
}
