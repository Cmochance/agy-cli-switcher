import Darwin
import XCTest
@testable import AgyAccount

final class AgyAccountTests: XCTestCase {
    func testDecodeAndNameRules() throws {
        let blob = makeBlob(email: "a@b.c", refresh: "r1", expiry: "2026-01-01T00:00:00Z")
        let meta = try decodeLogin(blob, source: .keychain)
        XCTAssertEqual(meta.email, "a@b.c")
        XCTAssertEqual(meta.authMethod, "consumer")
        XCTAssertEqual(meta.expiry, "2026-01-01T00:00:00Z")

        XCTAssertThrowsError(try decodeLogin("plain", source: .keychain))
        XCTAssertThrowsError(try decodeLogin("go-keyring-base64:!!!!", source: .saved))
        XCTAssertThrowsError(try decodeLogin(makeBlob(email: "no-at"), source: .saved))
        XCTAssertThrowsError(try checkName(""))
        XCTAssertThrowsError(try checkName("-ab"))
        XCTAssertNoThrow(try checkName(String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try checkName(String(repeating: "a", count: 65)))
    }

    func testHelpListsEveryCommandWithoutReadingKeychain() {
        let keychain = ExplodingKeychain()
        let result = runCommand(args: ["help"], keychain: keychain)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(keychain.reads, 0)
        for word in ["current", "list", "save", "switch", "next", "rename", "rm", "help", "language", "邮箱", "切换", "删除", "新增"] {
            XCTAssertTrue(result.output.joined(separator: "\n").contains(word), word)
        }
        XCTAssertEqual(runCommand(args: ["-h"], keychain: keychain).code, 0)
        XCTAssertEqual(runCommand(args: ["--help"], keychain: keychain).code, 0)
        XCTAssertEqual(runCommand(args: ["nope"], keychain: keychain).code, 2)
    }

    func testSaveListCurrentAndSameEmailRefresh() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "old"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        XCTAssertEqual(fixture.keychain.reads, 1)
        XCTAssertEqual(fixture.run(["current"]).output, ["alice@example.com"])
        XCTAssertEqual(fixture.run([]).output, ["* alice  alice@example.com"])
        XCTAssertEqual(fixture.keychain.reads, 3)
        XCTAssertEqual(try mode(fixture.locations.accountsDirectory), 0o700)
        XCTAssertEqual(try mode(fixture.locations.tokenURL("alice")), 0o600)
        let saved = try String(contentsOf: fixture.locations.metaURL("alice"), encoding: .utf8)
        XCTAssertEqual(
            saved,
            "{\n  \"name\": \"alice\",\n  \"email\": \"alice@example.com\",\n  \"auth_method\": \"consumer\",\n  \"expiry\": \"2026-01-01T00:00:00Z\",\n  \"saved_at\": \"2026-01-01T00:00:00Z\"\n}\n"
        )

        let profile = try String(contentsOf: fixture.tool.profileURL("alice"), encoding: .utf8)
        XCTAssertFalse(profile.contains("refresh"))
        XCTAssertFalse(profile.contains("go-keyring"))
        XCTAssertEqual(try mode(fixture.tool.root), 0o700)
        XCTAssertEqual(try mode(fixture.tool.profileURL("alice")), 0o600)

        fixture.keychain.blob = makeBlob(email: "alice@example.com", refresh: "new")
        let refreshed = fixture.run(["switch", "alice"])
        XCTAssertEqual(refreshed.code, 0)
        XCTAssertEqual(fixture.keychain.writes, [])
        XCTAssertEqual(refreshed.output, [
            "已经是 alice  alice@example.com",
            "已把钥匙串里较新的 token 写回: alice",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quota.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.conversation.path))
        let stored = stripNewlines(try String(contentsOf: fixture.locations.tokenURL("alice"), encoding: .utf8))
        XCTAssertEqual(stored, fixture.keychain.blob)
    }

    func testSwitchClearsQuotaAndKeepsConversations() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.processes.pids = [42, 43]
        let switched = fixture.run(["switch", "alice"])
        XCTAssertEqual(switched.code, 0)
        XCTAssertEqual(fixture.keychain.writes, [alice])
        XCTAssertEqual(switched.output, [
            "已切换到 alice  alice@example.com",
            "正在运行的 agy 仍使用旧登录: 42, 43",
            "退出已打开的 agy，再开一个新会话才会用这个账号。",
        ])
        XCTAssertEqual(fixture.launcher.started, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quota.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.conversation.path))
    }

    // 当前登录还没保存过时，切走之前先把它存下来；名字起不出来才拒绝。
    func testSwitchSavesAnUnsavedCurrentLoginFirst() throws {
        let alice = makeBlob(email: "alice@example.com")
        let carol = makeBlob(email: "carol@example.com")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = carol
        let switched = fixture.run(["switch", "alice"])
        XCTAssertEqual(switched.code, 0)
        XCTAssertEqual(fixture.keychain.writes, [alice])
        XCTAssertEqual(stripNewlines(try String(contentsOf: fixture.locations.tokenURL("carol"), encoding: .utf8)), carol)
        XCTAssertEqual(fixture.run(["list"]).output, ["* alice  alice@example.com", "  carol  carol@example.com"])

        fixture.keychain.blob = makeBlob(email: "a+b@example.com")
        let refused = fixture.run(["switch", "carol"])
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue(refused.errors.joined(separator: "\n").contains("还没保存"))
        XCTAssertEqual(fixture.keychain.writes, [alice])
    }

    func testNextSkipsSameEmailAndStopsWhenOnlyOneMailbox() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a1")
        let aliceAgain = makeBlob(email: "alice@example.com", refresh: "a2")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice-1"]).code, 0)
        fixture.keychain.blob = aliceAgain
        XCTAssertEqual(fixture.run(["save", "alice-2"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.keychain.blob = alice
        let rotated = fixture.run(["next"])
        XCTAssertEqual(rotated.code, 0)
        XCTAssertEqual(rotated.output.first, "已切换到 bob  bob@example.com")
        XCTAssertEqual(fixture.keychain.blob, bob)

        let onlyAlice = try Fixture(blob: alice)
        defer { onlyAlice.cleanup() }
        XCTAssertEqual(onlyAlice.run(["save", "one"]).code, 0)
        onlyAlice.keychain.blob = aliceAgain
        XCTAssertEqual(onlyAlice.run(["save", "two"]).code, 0)
        onlyAlice.keychain.blob = alice
        XCTAssertEqual(onlyAlice.run(["next"]).code, 1)
        XCTAssertEqual(onlyAlice.run(["next"]).errors.first?.contains("同一个邮箱"), true)
    }

    func testRemoveRequiresForceForOnlyCurrentCopy() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "alice@example.com", refresh: "a2")
        XCTAssertEqual(fixture.run(["save", "alice-copy"]).code, 0)
        XCTAssertEqual(fixture.keychain.reads, 2)
        fixture.keychain.blob = makeBlob(email: "alice@example.com", refresh: "a")
        XCTAssertEqual(fixture.run(["rm", "alice"]).code, 0)
        XCTAssertEqual(fixture.keychain.reads, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("alice").path))
        XCTAssertEqual(fixture.keychain.blob, makeBlob(email: "alice@example.com", refresh: "a"))

        let alone = try Fixture(blob: makeBlob(email: "alice@example.com"))
        defer { alone.cleanup() }
        XCTAssertEqual(alone.run(["save", "alice"]).code, 0)
        let blocked = alone.run(["rm", "alice"])
        XCTAssertEqual(blocked.code, 1)
        XCTAssertTrue(blocked.errors.joined(separator: "\n").contains("--force"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alone.locations.tokenURL("alice").path))
        XCTAssertEqual(alone.run(["rm", "--force", "alice"]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alone.locations.tokenURL("alice").path))
        XCTAssertEqual(alone.keychain.writes, [])
    }

    func testCatalogImportSkipsSecretsAndKeychain() throws {
        let fixture = try Fixture(blob: makeBlob(email: "bob@example.com", refresh: "secret-value"))
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.locations.accountsDirectory, withIntermediateDirectories: true)
        let sidecar = encodeSidecar(
            name: "alice",
            email: "alice@example.com",
            authMethod: "consumer",
            expiry: "2026-01-01T00:00:00Z",
            savedAt: "2026-01-01T00:00:00Z"
        )
        try sidecar.write(to: fixture.locations.metaURL("alice"), atomically: true, encoding: .utf8)
        try Data("alice\n".utf8).write(to: fixture.locations.activeURL)
        try Data(makeBlob(email: "bob@example.com").utf8).write(to: fixture.locations.tokenURL("alice"))
        XCTAssertEqual(fixture.run(["list"]).output, ["  alice  alice@example.com", "* bob  bob@example.com"])
        XCTAssertEqual(fixture.run(["current"]).output, ["bob@example.com"])
        XCTAssertEqual(fixture.keychain.reads, 2)
        let profile = try String(contentsOf: fixture.tool.profileURL("alice"), encoding: .utf8)
        XCTAssertFalse(profile.contains("go-keyring"))
        XCTAssertFalse(profile.contains("bob@example.com"))
        XCTAssertFalse(profile.contains("secret-value"))
    }

    func testLanguagesAndRenamedSwitchDoNotReadKeychain() throws {
        XCTAssertEqual(AppLanguage.resolve(preferred: ["zh-Hans-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferred: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(preferred: ["zh-HK", "en"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(preferred: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.resolve(preferred: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferred: ["fr-FR"]), .english)

        let keychain = ExplodingKeychain()
        let followed = runCommand(args: ["lg"], keychain: keychain, preferred: ["ja-JP"])
        XCTAssertEqual(followed.code, 0)
        XCTAssertEqual(keychain.reads, 0)
        XCTAssertTrue(followed.output.joined(separator: "\n").contains("システムに従う"))

        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com"))
        defer { fixture.cleanup() }
        let english = fixture.run(["language", "en"])
        XCTAssertEqual(english.code, 0)
        XCTAssertTrue(english.output.joined(separator: "\n").contains("Language set to en English"))
        XCTAssertTrue(fixture.run(["help"]).output.joined(separator: "\n").contains("Switch to a saved account"))
        XCTAssertTrue(fixture.run(["language", "zh-Hant"]).output.joined(separator: "\n").contains("已切換語言: zh-Hant 繁體中文"))
        XCTAssertTrue(fixture.run(["lg", "ja"]).output.joined(separator: "\n").contains("言語を切り替えました: ja 日本語"))
        let renamed = fixture.run(["use", "alice"])
        XCTAssertEqual(renamed.code, 2)
        XCTAssertTrue(renamed.errors.joined(separator: "\n").contains("switch"))
        XCTAssertEqual(fixture.keychain.reads, 0)
    }

    func testLiveKeychainRoundTripWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGY_ACCOUNT_LIVE"] == "1" else {
            return
        }
        let store = LoginKeychainStore()
        XCTAssertEqual(try store.matchingItemCount(dataProtection: false), 1)
        XCTAssertEqual(try store.matchingItemCount(dataProtection: true), 0)
        let blob = try store.readBlob()
        let email = try decodeLogin(blob, source: .keychain).email
        try store.writeBlob(blob)
        let written = try store.readBlob()
        XCTAssertEqual(written, blob)
        XCTAssertEqual(try decodeLogin(written, source: .keychain).email, email)
        XCTAssertEqual(try store.matchingItemCount(dataProtection: false), 1)
        XCTAssertEqual(try store.matchingItemCount(dataProtection: true), 0)
        XCTAssertFalse(email.isEmpty)
    }

    func testSwitchMenuSelectsSavedAccountAndLaunchesAgy() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        fixture.processes.pids = [7]
        fixture.terminal.isInteractive = true
        fixture.terminal.lines = ["1", "9", "3"]
        let readsBefore = fixture.keychain.reads
        let chosen = fixture.run(["switch"])
        XCTAssertEqual(chosen.code, 0)
        XCTAssertEqual(fixture.keychain.writes, [alice])
        XCTAssertEqual(fixture.launcher.started, 1)
        XCTAssertGreaterThan(fixture.keychain.reads, readsBefore)
        XCTAssertTrue(chosen.errors.contains { $0.contains("不能选") })
        XCTAssertTrue(chosen.errors.contains { $0.contains("没有这个序号") })
        XCTAssertEqual(chosen.output.last, "正在当前终端启动 agy。")
        XCTAssertTrue(chosen.output.contains("已切换到 alice  alice@example.com"))
        XCTAssertTrue(chosen.output.contains("正在运行的 agy 仍使用旧登录: 7"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quota.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.conversation.path))

        let again = try Fixture(blob: alice)
        defer { again.cleanup() }
        XCTAssertEqual(again.run(["save", "alice"]).code, 0)
        let reads = again.keychain.reads
        again.terminal.isInteractive = true
        again.terminal.lines = ["1", "q"]
        XCTAssertEqual(again.run(["switch"]).code, 0)
        XCTAssertEqual(again.keychain.reads, reads + 2)
        XCTAssertEqual(again.launcher.started, 0)
        XCTAssertEqual(again.run(["switch", "alice", "extra"]).code, 2)
        XCTAssertEqual(again.run(["switch", "add", "extra"]).code, 2)
        again.terminal.isInteractive = false
        XCTAssertEqual(again.run(["switch"]).code, 2)
        XCTAssertEqual(again.launcher.started, 0)
    }

    func testSwitchAddSkipsTheMenuAndKeepsTheSavedNameAdd() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let carol = makeBlob(email: "carol@example.com", refresh: "c")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        try fixture.writeLegacyRecord(name: "add", blob: alice)
        fixture.terminal.isInteractive = true
        fixture.launcher.supply = {
            fixture.keychain.blob = carol
            fixture.keychain.missing = false
        }
        let added = fixture.run(["switch", "add"])
        XCTAssertEqual(added.code, 0)
        XCTAssertEqual(fixture.launcher.started, 1)
        XCTAssertFalse(added.output.contains("选择序号"))
        XCTAssertFalse(added.output.contains("已切换到 add"))
        XCTAssertTrue(added.output.contains("已保存 carol  carol@example.com"))
        XCTAssertEqual(fixture.refresher.started, 1)
        XCTAssertTrue(fixture.usage.calls.isEmpty)
        XCTAssertEqual(fixture.run(["current"]).output, ["carol@example.com"])
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: fixture.locations.tokenURL("add"), encoding: .utf8)),
            alice
        )

        fixture.terminal.isInteractive = false
        XCTAssertEqual(fixture.run(["switch", "add"]).code, 2)
        XCTAssertEqual(fixture.launcher.started, 1)
    }

    func testAddIsRefusedAsANewNameButOldRecordsStayUsable() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        let saved = fixture.run(["save", "add"])
        XCTAssertEqual(saved.code, 1)
        XCTAssertTrue(saved.errors.joined(separator: "\n").contains("agy-cs switch add"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("add").path))
        let renamed = fixture.run(["rename", "alice", "add"])
        XCTAssertEqual(renamed.code, 1)
        XCTAssertTrue(renamed.errors.joined(separator: "\n").contains("agy-cs switch add"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("alice").path))

        try fixture.writeLegacyRecord(name: "add", blob: alice)
        XCTAssertTrue(fixture.run(["list"]).output.contains("* add  alice@example.com"))
        XCTAssertEqual(fixture.run(["rename", "add", "older"]).code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("older").path))
        try fixture.writeLegacyRecord(name: "add", blob: alice)
        XCTAssertEqual(fixture.run(["rm", "add"]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("add").path))

        let mailbox = makeBlob(email: "add@example.com", refresh: "d")
        fixture.terminal.isInteractive = true
        fixture.launcher.supply = {
            fixture.keychain.blob = mailbox
            fixture.keychain.missing = false
        }
        let added = fixture.run(["switch", "add"])
        XCTAssertEqual(added.code, 1)
        XCTAssertTrue(added.errors.joined(separator: "\n").contains("agy-cs save"))
        XCTAssertTrue(added.errors.joined(separator: "\n").contains("已恢复原来的钥匙串登录"))
        XCTAssertEqual(fixture.keychain.blob, alice)
        XCTAssertEqual(fixture.launcher.started, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("add").path))

        let first = try Fixture(blob: mailbox, markInitialized: false)
        defer { first.cleanup() }
        let listed = first.run(["list"])
        XCTAssertTrue(listed.errors.joined(separator: "\n").contains("save"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.tool.profileURL("add").path))
    }

    func testAddAccountSavesLocalPartAndRestoresWhenLoginStops() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let carol = makeBlob(email: "carol@example.com", refresh: "c")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.terminal.isInteractive = true
        fixture.terminal.lines = ["2"]
        fixture.launcher.supply = {
            fixture.keychain.blob = carol
            fixture.keychain.missing = false
        }
        let added = fixture.run(["switch"])
        XCTAssertEqual(added.code, 0)
        XCTAssertEqual(fixture.launcher.started, 1)
        XCTAssertTrue(added.output.contains("已保存 carol  carol@example.com"))
        XCTAssertEqual(fixture.run(["current"]).output, ["carol@example.com"])
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: fixture.locations.tokenURL("alice"), encoding: .utf8)),
            alice
        )
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: fixture.locations.tokenURL("carol"), encoding: .utf8)),
            carol
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.quota.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.conversation.path))

        let cancelled = try Fixture(blob: alice)
        defer { cancelled.cleanup() }
        XCTAssertEqual(cancelled.run(["save", "alice"]).code, 0)
        cancelled.terminal.isInteractive = true
        cancelled.terminal.lines = ["2"]
        let stopped = cancelled.run(["switch"])
        XCTAssertEqual(stopped.code, 1)
        XCTAssertTrue(stopped.errors.joined(separator: "\n").contains("已恢复"))
        XCTAssertEqual(cancelled.launcher.started, 0)
        XCTAssertEqual(cancelled.keychain.blob, alice)
        XCTAssertFalse(cancelled.keychain.missing)
        XCTAssertEqual(cancelled.keychain.writes, [alice])
        XCTAssertEqual(cancelled.refresher.started, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cancelled.quota.path))

        let failed = try Fixture(blob: alice)
        defer { failed.cleanup() }
        XCTAssertEqual(failed.run(["save", "alice"]).code, 0)
        failed.terminal.isInteractive = true
        failed.terminal.lines = ["2"]
        failed.launcher.failure = AccountFailure(.agyLaunchFailed, "agy")
        let broken = failed.run(["switch"])
        XCTAssertEqual(broken.code, 1)
        XCTAssertTrue(broken.errors.joined(separator: "\n").contains("agy"))
        XCTAssertEqual(failed.keychain.blob, alice)
        XCTAssertFalse(failed.keychain.missing)
        XCTAssertEqual(failed.keychain.writes, [alice])
    }

    func testAddAccountRestoresOriginalLoginWhenPollingFails() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let carol = makeBlob(email: "carol@example.com", refresh: "c")

        let denied = try Fixture(blob: alice)
        defer { denied.cleanup() }
        XCTAssertEqual(denied.run(["save", "alice"]).code, 0)
        try FileManager.default.removeItem(at: denied.locations.tokenURL("alice"))
        denied.terminal.isInteractive = true
        denied.terminal.lines = ["2"]
        denied.launcher.supply = {
            denied.keychain.blob = carol
            denied.keychain.missing = false
            denied.keychain.denied = true
        }
        let refused = denied.run(["switch"])
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue(refused.errors.joined(separator: "\n").contains("钥匙串没有允许读取"))
        XCTAssertTrue(refused.errors.joined(separator: "\n").contains("已恢复原来的钥匙串登录"))
        XCTAssertEqual(denied.launcher.started, 0)
        XCTAssertEqual(denied.keychain.blob, alice)
        XCTAssertFalse(denied.keychain.missing)
        XCTAssertEqual(denied.keychain.writes, [alice])
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: denied.locations.tokenURL("alice"), encoding: .utf8)),
            alice
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: denied.locations.tokenURL("carol").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: denied.quota.path))

        let unfinished = try Fixture(blob: alice)
        defer { unfinished.cleanup() }
        XCTAssertEqual(unfinished.run(["save", "alice"]).code, 0)
        unfinished.terminal.isInteractive = true
        unfinished.terminal.lines = ["2"]
        unfinished.launcher.supply = {
            unfinished.keychain.blob = "go-keyring-base64:" + Data("{}".utf8).base64EncodedString()
            unfinished.keychain.missing = false
        }
        let partial = unfinished.run(["switch"])
        XCTAssertEqual(partial.code, 1)
        XCTAssertTrue(partial.errors.joined(separator: "\n").contains("已恢复"))
        XCTAssertEqual(unfinished.keychain.blob, alice)
        XCTAssertEqual(unfinished.keychain.writes, [alice])

        let carolElsewhere = makeBlob(email: "carol@elsewhere.com", refresh: "e")
        let taken = try Fixture(blob: carolElsewhere)
        defer { taken.cleanup() }
        XCTAssertEqual(taken.run(["save", "carol"]).code, 0)
        taken.keychain.blob = alice
        XCTAssertEqual(taken.run(["save", "alice"]).code, 0)
        taken.terminal.isInteractive = true
        taken.terminal.lines = ["2"]
        taken.launcher.supply = {
            taken.keychain.blob = carol
            taken.keychain.missing = false
        }
        let clashed = taken.run(["switch"])
        XCTAssertEqual(clashed.code, 1)
        XCTAssertTrue(clashed.errors.joined(separator: "\n").contains("名字 carol 已经被 carol@elsewhere.com 使用"))
        XCTAssertTrue(clashed.errors.joined(separator: "\n").contains("已恢复原来的钥匙串登录"))
        XCTAssertEqual(taken.launcher.started, 0)
        XCTAssertEqual(taken.keychain.blob, alice)
        XCTAssertFalse(taken.keychain.missing)
        XCTAssertEqual(taken.keychain.writes, [alice])
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: taken.locations.tokenURL("carol"), encoding: .utf8)),
            carolElsewhere
        )
        XCTAssertEqual(taken.run(["current"]).output, ["alice@example.com"])
    }

    func testAddAccountLeavesALoginAloneWhenItCouldNotBeWrittenBack() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.writeLimit = alice.count - 1
        fixture.terminal.isInteractive = true
        fixture.launcher.supply = { XCTFail("agy must not open") }
        let refused = fixture.run(["switch", "add"])
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue(refused.errors.joined(separator: "\n").contains("没有改动钥匙串"))
        XCTAssertFalse(fixture.keychain.missing)
        XCTAssertEqual(fixture.keychain.blob, alice)
        XCTAssertTrue(fixture.keychain.writes.isEmpty)
        XCTAssertEqual(fixture.launcher.started, 0)
    }

    func testSwitchRecordsUsageAndListOnlyReadsTheRecords() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        XCTAssertTrue(fixture.usage.calls.isEmpty)
        XCTAssertEqual(fixture.run(["list"]).output, ["  alice  alice@example.com", "* bob  bob@example.com"])

        let pro = UsageSnapshot(planID: "g1-pro-tier", planName: "Google AI Pro", buckets: [
            UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-01-01T03:00:00Z"),
            UsageBucket(id: "gemini-weekly", remaining: 0.4, resetTime: "2025-12-31T23:00:00Z"),
            UsageBucket(id: "3p-5h", remaining: 0.1, resetTime: "2026-01-01T03:00:00Z"),
            UsageBucket(id: "gemini-argon-wtu-weekly", remaining: 1, resetTime: "2026-01-08T00:00:00Z"),
        ])
        let free = UsageSnapshot(planID: "free-tier", planName: "Antigravity Starter Quota", buckets: [
            UsageBucket(id: "gemini-weekly", remaining: 0.9962848, resetTime: "2026-01-07T10:23:00Z"),
        ])
        fixture.usage.snapshots = ["alice": pro, "bob": free]
        let switched = fixture.run(["switch", "alice"])
        XCTAssertEqual(switched.code, 0)
        XCTAssertEqual(switched.errors, [])
        XCTAssertEqual(fixture.refresher.started, 1)
        XCTAssertTrue(fixture.usage.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tool.usageURL("alice").path))
        XCTAssertEqual(fixture.run(["refresh", "quota", "--detach"]).code, 0)
        XCTAssertEqual(fixture.refresher.workers, 1)
        XCTAssertTrue(fixture.usage.calls.isEmpty)
        for wrong in [["refresh"], ["refresh", "nope"], ["refresh", "quota", "now"]] {
            XCTAssertEqual(fixture.run(wrong).code, 2)
        }

        let reads = fixture.keychain.reads
        let expected = [
            ["* alice", "alice@example.com", "Pro", "5h 62% \(localTime("2026-01-01T03:00:00Z"))", "7d 100%", "Argon 100%"],
            ["bob", "bob@example.com", "Free", "7d 99% \(localTime("2026-01-07T10:23:00Z"))"],
        ]
        let refreshed = fixture.run(["refresh", "quota"])
        XCTAssertEqual(refreshed.code, 0)
        XCTAssertEqual(refreshed.errors, [])
        XCTAssertEqual(refreshed.output.map(cells), expected)
        XCTAssertEqual(fixture.usage.calls, [["alice", "bob"]])
        XCTAssertEqual(fixture.keychain.reads, reads + 2)
        XCTAssertEqual(fixture.keychain.writes, [alice])
        XCTAssertEqual(try mode(fixture.tool.usageDirectory), 0o700)
        XCTAssertEqual(try mode(fixture.tool.usageURL("alice")), 0o600)
        let record = try String(contentsOf: fixture.tool.usageURL("alice"), encoding: .utf8)
        XCTAssertFalse(record.contains("go-keyring"))
        XCTAssertFalse(record.contains("refresh"))

        let listed = fixture.run(["list"])
        XCTAssertEqual(listed.output, refreshed.output)
        XCTAssertEqual(listed.errors, [])
        XCTAssertEqual(fixture.usage.calls.count, 1)
        XCTAssertEqual(fixture.keychain.reads, reads + 3)

        fixture.usage.snapshots = ["alice": pro]
        let partial = fixture.run(["refresh", "quota"])
        XCTAssertEqual(partial.code, 1)
        XCTAssertEqual(partial.errors.count, 1)
        XCTAssertTrue(partial.errors[0].contains("bob") && partial.errors[0].contains("refresh quota"))
        XCTAssertFalse(partial.errors[0].contains("alice"))
        XCTAssertEqual(partial.output.map(cells), expected)
        XCTAssertEqual(fixture.run(["list"]).errors, partial.errors)

        let back = fixture.run(["switch", "bob"])
        XCTAssertEqual(back.code, 0)
        XCTAssertEqual(back.errors, [])
        XCTAssertEqual(fixture.refresher.started, 2)
        XCTAssertEqual(fixture.run(["switch", "bob"]).code, 0)
        XCTAssertEqual(fixture.refresher.started, 2)
        XCTAssertEqual(fixture.usage.calls.count, 2)

        XCTAssertEqual(fixture.run(["rename", "alice", "anna"]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tool.usageURL("alice").path))
        XCTAssertEqual(cells(fixture.run(["list"]).output[0]), ["anna"] + expected[0].dropFirst())
        XCTAssertEqual(fixture.run(["rm", "anna"]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tool.usageURL("anna").path))

        let bobLine = ["* bob"] + expected[1].dropFirst()
        XCTAssertEqual(cells(fixture.run(["list"]).output[0]), bobLine)
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        XCTAssertEqual(cells(fixture.run(["list"]).output[0]), bobLine)
        fixture.keychain.blob = makeBlob(email: "carol@example.com", refresh: "c")
        let kept = fixture.run(["save", "bob"])
        XCTAssertEqual(kept.code, 1)
        XCTAssertEqual(kept.errors, ["名字 bob 下面已经存着 bob@example.com，所以没有保存。确认用当前登录替换它，再用 agy-cs save bob --force。"])
        XCTAssertEqual(cells(fixture.run(["list"]).output[0]), expected[1])
        XCTAssertEqual(fixture.run(["save", "bob", "--force"]).code, 0)
        XCTAssertEqual(fixture.run(["list"]).output, ["* bob  carol@example.com", "* carol  carol@example.com"])
        fixture.usage.snapshots = nil
        let healed = fixture.run(["refresh", "quota"])
        XCTAssertEqual(healed.code, 0)
        XCTAssertEqual(fixture.run(["list"]).errors, [])
    }

    func testListMarksAPlanWhosePaidModelsAreLocked() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        func plan(_ id: String, _ locked: Bool?) throws -> String {
            fixture.usage.snapshots = ["alice": UsageSnapshot(planID: id, planName: "", buckets: [], argonLocked: locked, project: "p-\(id)")]
            let shown = fixture.run(["refresh", "quota"])
            XCTAssertEqual(shown.code, 0)
            return try XCTUnwrap(shown.output.first.map(cells))[2]
        }
        XCTAssertEqual(try plan("g1-pro-tier", true), "Pro（非付费）")
        XCTAssertEqual(fixture.usage.hints.last, [""])
        XCTAssertEqual(try plan("g1-pro-tier", nil), "Pro（非付费）")
        XCTAssertEqual(fixture.usage.hints.last, ["p-g1-pro-tier"])
        XCTAssertEqual(try plan("g1-pro-tier", false), "Pro")
        XCTAssertEqual(try plan("g1-pro-tier", nil), "Pro")
        XCTAssertEqual(try plan("free-tier", true), "Free")
        XCTAssertEqual(fixture.run(["language", "en"]).code, 0)
        XCTAssertEqual(try plan("g1-pro-tier", true), "Pro (non-paid)")
    }

    func testRefreshQuotaReportsUnreadableCopiesAndWaitsForARunningLookup() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        try FileManager.default.removeItem(at: fixture.locations.tokenURL("alice"))
        let lopsided = fixture.run(["refresh", "quota"])
        XCTAssertEqual(lopsided.code, 1)
        XCTAssertEqual(fixture.usage.calls, [["bob"]])
        XCTAssertTrue(lopsided.errors.contains { $0.contains("alice") && !$0.contains("bob") })
        XCTAssertTrue(fixture.run(["list"]).errors.contains { $0.contains("alice") })

        let held = open(fixture.tool.usageLockFile.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        fixture.usage.budget = 0.3
        let status = try String(contentsOf: fixture.tool.usageStatusFile, encoding: .utf8)
        let busy = fixture.run(["refresh", "quota"])
        XCTAssertEqual(busy.code, 1)
        XCTAssertTrue(busy.errors.contains { $0.contains("还没结束") })
        XCTAssertTrue(busy.output.isEmpty)
        XCTAssertEqual(fixture.usage.calls.count, 1)
        XCTAssertEqual(try String(contentsOf: fixture.tool.usageStatusFile, encoding: .utf8), status)

        // 另一个进程查完了 bob。它开始之后才存进来的 alice 要补查，bob 不再查一遍。
        fixture.usage.budget = 5
        let profile = ToolProfile(home: fixture.home, now: { "2026-01-01T00:00:00Z" }, preferredLanguages: [])
        try profile.writeUsageStatus(failed: [])
        try fixture.writeLegacyRecord(name: "alice", blob: alice)
        func releaseSoon(_ descriptor: Int32) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        releaseSoon(held)
        let started = Date()
        let waited = fixture.run(["refresh", "quota"])
        XCTAssertEqual(waited.code, 0)
        XCTAssertEqual(waited.errors, [])
        XCTAssertEqual(waited.output.map { cells($0).count }, [3, 3])
        XCTAssertFalse(waited.output.contains { $0.contains("5h") || $0.contains("7d") || $0.contains("Argon") })
        XCTAssertEqual(fixture.usage.calls.last, ["alice"])
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertLessThan(try XCTUnwrap(fixture.usage.allowed.last), 4.9)

        let again = open(fixture.tool.usageLockFile.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(again, LOCK_EX), 0)
        releaseSoon(again)
        XCTAssertEqual(fixture.run(["refresh", "quota"]).code, 0)
        XCTAssertEqual(fixture.usage.calls.count, 2)

        // 结果写不下来时不能报成功，也不能拿上一次的结果顶替。
        try FileManager.default.removeItem(at: fixture.tool.usageStatusFile)
        try FileManager.default.createDirectory(
            at: fixture.tool.usageStatusFile.appendingPathComponent("blocked"),
            withIntermediateDirectories: true
        )
        let unwritable = fixture.run(["refresh", "quota"])
        XCTAssertEqual(unwritable.code, 1)
        XCTAssertEqual(fixture.usage.calls.last, ["alice", "bob"])
        XCTAssertTrue(unwritable.errors.contains { $0.contains("usage-status.json") })
    }

    func testKeepSnapshotDoesNotOverwriteMismatchedOrUnreadableToken() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")

        let skipped = try Fixture(blob: alice)
        defer { skipped.cleanup() }
        XCTAssertEqual(skipped.run(["save", "work"]).code, 0)
        try Data((bob + "\n").utf8).write(to: skipped.locations.tokenURL("work"))
        skipped.terminal.isInteractive = true
        skipped.terminal.lines = ["2"]
        let cancelled = skipped.run(["switch"])
        XCTAssertEqual(cancelled.code, 1)
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: skipped.locations.tokenURL("work"), encoding: .utf8)),
            bob
        )
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: skipped.locations.tokenURL("alice"), encoding: .utf8)),
            alice
        )
        XCTAssertEqual(skipped.keychain.blob, alice)

        let unreadable = try Fixture(blob: alice)
        defer { unreadable.cleanup() }
        XCTAssertEqual(unreadable.run(["save", "work"]).code, 0)
        try Data("not-a-valid-token\n".utf8).write(to: unreadable.locations.tokenURL("work"))
        unreadable.terminal.isInteractive = true
        unreadable.terminal.lines = ["2"]
        XCTAssertEqual(unreadable.run(["switch"]).code, 1)
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: unreadable.locations.tokenURL("work"), encoding: .utf8)),
            "not-a-valid-token"
        )
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: unreadable.locations.tokenURL("alice"), encoding: .utf8)),
            alice
        )

        let blocked = try Fixture(blob: alice)
        defer { blocked.cleanup() }
        XCTAssertEqual(blocked.run(["save", "alice"]).code, 0)
        try Data((bob + "\n").utf8).write(to: blocked.locations.tokenURL("alice"))
        blocked.terminal.isInteractive = true
        blocked.terminal.lines = ["2"]
        let refused = blocked.run(["switch"])
        XCTAssertEqual(refused.code, 1)
        // 名字 alice 下面的副本是别人的：不动它，当前登录另存成 alice-2，新增账号照常进行；没登录成就把原来的登录写回去。
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: blocked.locations.tokenURL("alice"), encoding: .utf8)),
            bob
        )
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: blocked.locations.tokenURL("alice-2"), encoding: .utf8)),
            alice
        )
        XCTAssertEqual(blocked.keychain.blob, alice)
        XCTAssertFalse(blocked.keychain.missing)
        XCTAssertEqual(blocked.keychain.writes, [alice])
    }

    func testRenameMovesCatalogWithoutReadingKeychain() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        let reads = fixture.keychain.reads
        let renamed = fixture.run(["rename", "alice", "carol"])
        XCTAssertEqual(renamed.code, 0)
        XCTAssertEqual(renamed.output, ["已把 alice 改名为 carol  alice@example.com"])
        XCTAssertEqual(fixture.keychain.reads, reads)
        XCTAssertEqual(fixture.keychain.writes, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("alice").path))
        XCTAssertEqual(
            stripNewlines(try String(contentsOf: fixture.locations.tokenURL("carol"), encoding: .utf8)),
            alice
        )
        let profile = try String(contentsOf: fixture.tool.profileURL("carol"), encoding: .utf8)
        XCTAssertTrue(profile.contains("\"name\": \"carol\""))
        XCTAssertFalse(profile.contains("go-keyring"))
        XCTAssertEqual(fixture.run(["current"]).output, ["bob@example.com"])
        XCTAssertEqual(fixture.run(["rename", "dave"]).output, ["已把 bob 改名为 dave  bob@example.com"])
        XCTAssertEqual(try String(contentsOf: fixture.tool.activeFile, encoding: .utf8), "dave\n")
        XCTAssertEqual(try String(contentsOf: fixture.locations.activeURL, encoding: .utf8), "dave\n")
        XCTAssertEqual(fixture.run(["rename", "dave"]).output, ["dave 已经是这个名字  bob@example.com"])
        let blocked = fixture.run(["rename", "carol", "dave"])
        XCTAssertEqual(blocked.code, 1)
        XCTAssertTrue(blocked.errors.joined(separator: "\n").contains("dave"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("carol").path))
        XCTAssertEqual(fixture.run(["rename"]).code, 2)
        XCTAssertEqual(fixture.run(["rename", "a", "b", "c"]).code, 2)
        XCTAssertEqual(fixture.keychain.reads, reads + 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.quota.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.conversation.path))
    }

    func testFirstRunInitializesCurrentLoginOnce() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com"), markInitialized: false)
        defer { fixture.cleanup() }
        let listed = fixture.run(["list"])
        XCTAssertEqual(listed.code, 0)
        XCTAssertEqual(listed.output, [
            "已初始化当前登录: alice  alice@example.com",
            "* alice  alice@example.com",
        ])
        XCTAssertEqual(fixture.keychain.reads, 2)
        XCTAssertEqual(fixture.run(["current"]).output, ["alice@example.com"])
        XCTAssertEqual(fixture.keychain.reads, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.tool.initializedFile.path))
        let profile = try String(contentsOf: fixture.tool.profileURL("alice"), encoding: .utf8)
        XCTAssertFalse(profile.contains("refresh"))
        XCTAssertFalse(profile.contains("go-keyring"))

        let rejected = try Fixture(blob: makeBlob(email: "a+b@example.com"), markInitialized: false)
        defer { rejected.cleanup() }
        let rejectedRun = rejected.run(["current"])
        XCTAssertEqual(rejectedRun.code, 0)
        XCTAssertTrue(rejectedRun.errors.joined(separator: "\n").contains("save"))
        XCTAssertEqual(rejected.keychain.reads, 2)
        XCTAssertEqual(rejected.run(["list"]).code, 0)
        XCTAssertEqual(rejected.keychain.reads, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.tool.profileURL("a+b").path))

        let missing = try Fixture(blob: makeBlob(email: "alice@example.com"), markInitialized: false)
        defer { missing.cleanup() }
        missing.keychain.missing = true
        let empty = missing.run(["list"])
        XCTAssertEqual(empty.code, 0)
        XCTAssertTrue(empty.errors.joined(separator: "\n").contains("没有自动保存"))
        XCTAssertEqual(empty.output, ["还没有保存的账号。先在 agy 里登录，再执行 agy-cs save <名字>。"])
        XCTAssertEqual(missing.keychain.reads, 2)
        XCTAssertEqual(missing.run(["help"]).code, 0)
        XCTAssertEqual(missing.keychain.reads, 2)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let denied = ExplodingKeychain()
        let first = runCommand(args: ["help"], keychain: denied, home: home, markInitialized: false)
        XCTAssertEqual(first.code, 1)
        XCTAssertEqual(denied.reads, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agy-cs/initialized").path))
        let second = runCommand(args: ["help"], keychain: denied, home: home, markInitialized: false)
        XCTAssertEqual(second.code, 1)
        XCTAssertEqual(denied.reads, 4)
    }

    func testChildWaitDistinguishesStopFromExit() {
        XCTAssertEqual(classifyWait(waited: 0, pid: 10, status: 0, callErrno: 0), .running)
        XCTAssertEqual(classifyWait(waited: -1, pid: 10, status: 0, callErrno: EINTR), .running)
        XCTAssertEqual(classifyWait(waited: -1, pid: 10, status: 0, callErrno: ECHILD), .finished)
        let stopped = (SIGTSTP << 8) | 0x7f
        XCTAssertEqual(classifyWait(waited: 10, pid: 10, status: stopped, callErrno: 0), .stopped(SIGTSTP))
        let continued = (SIGCONT << 8) | 0x7f
        XCTAssertEqual(classifyWait(waited: 10, pid: 10, status: continued, callErrno: 0), .running)
        XCTAssertEqual(classifyWait(waited: 10, pid: 10, status: 0, callErrno: 0), .finished)
        XCTAssertEqual(classifyWait(waited: 10, pid: 10, status: SIGTERM, callErrno: 0), .finished)
    }

    func testStoppedChildIsCancelledOnlyForTerminalStop() {
        XCTAssertEqual(nextStep(after: .running), .keepWaiting)
        XCTAssertEqual(nextStep(after: .stopped(SIGTSTP)), .cancel)
        XCTAssertEqual(nextStep(after: .stopped(SIGTTIN)), .resume)
        XCTAssertEqual(nextStep(after: .stopped(SIGTTOU)), .resume)
        XCTAssertEqual(nextStep(after: .stopped(SIGSTOP)), .resume)
        XCTAssertEqual(nextStep(after: .finished), .finished)
    }

    func testTerminalIsOnlyUsedFromTheForeground() {
        XCTAssertTrue(ownsForeground(foreground: 10, own: 10))
        XCTAssertFalse(ownsForeground(foreground: 11, own: 10))
        XCTAssertFalse(ownsForeground(foreground: -1, own: 10))
        XCTAssertFalse(ownsForeground(foreground: -1, own: -1))
    }

    func testKeychainStoreTalksToSecurityAndKeepsTheLoginOutOfArguments() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let tool = ScriptedSecurityTool()
        let store = LoginKeychainStore(tool: tool)
        XCTAssertThrowsError(try store.readBlob()) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.keychainMissing))
        }
        tool.stored = alice
        XCTAssertEqual(try store.readBlob(), alice)
        XCTAssertEqual(tool.calls.last?.arguments, ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"])
        XCTAssertNil(tool.calls.last?.input)

        try store.writeBlob(bob)
        XCTAssertEqual(tool.stored, bob)
        XCTAssertEqual(tool.calls.compactMap(\.input), ["add-generic-password -U -s gemini -a antigravity -w \(bob)\n"])
        XCTAssertEqual(tool.calls.first { $0.input != nil }?.arguments, ["-i"])
        XCTAssertFalse(tool.calls.contains { $0.arguments.contains { $0.contains("go-keyring") } })

        try store.deleteBlob()
        XCTAssertNil(tool.stored)
        XCTAssertEqual(tool.calls.last?.arguments, ["delete-generic-password", "-s", "gemini", "-a", "antigravity"])
        XCTAssertNoThrow(try store.deleteBlob())
    }

    func testKeychainStoreRefusesLoginsThatCouldCarryASecondCommand() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let tool = ScriptedSecurityTool()
        tool.stored = alice
        let store = LoginKeychainStore(tool: tool)
        let unsafe = [
            alice + "\ndelete-keychain",
            alice + " -T /bin/sh",
            alice + "\"",
            "plain",
            keychainPrefix,
            keychainPrefix + String(repeating: "A", count: securityLineLimit),
        ]
        for blob in unsafe {
            XCTAssertThrowsError(try store.writeBlob(blob), String(blob.suffix(20)))
        }
        XCTAssertTrue(tool.calls.allSatisfy { $0.input == nil })
        XCTAssertEqual(tool.stored, alice)

        let fixed = "add-generic-password -U -s gemini -a antigravity -w \(keychainPrefix)\n".utf8.count
        let longest = keychainPrefix + String(repeating: "A", count: securityLineLimit - fixed)
        XCTAssertEqual(
            securityAddLine(service: "gemini", account: "antigravity", blob: longest)?.utf8.count,
            securityLineLimit
        )
        XCTAssertNil(securityAddLine(service: "gemini", account: "antigravity", blob: longest + "A"))
        XCTAssertNil(securityAddLine(service: "gemini -a other", account: "antigravity", blob: alice))
    }

    func testKeychainStoreRestoresTheOriginalAndMapsExitCodes() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let tool = ScriptedSecurityTool()
        tool.stored = alice
        tool.garbleNextWrite = true
        let store = LoginKeychainStore(tool: tool)
        XCTAssertThrowsError(try store.writeBlob(bob)) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.writeMismatch))
        }
        XCTAssertEqual(tool.stored, alice)

        XCTAssertEqual(securityFailure(exitStatus: 44), AccountFailure(.keychainMissing))
        for status: Int32 in [128, 51, 36] {
            XCTAssertEqual(securityFailure(exitStatus: status), AccountFailure(.keychainDenied))
        }
        XCTAssertEqual(securityFailure(exitStatus: 1), AccountFailure(.keychainFailed, "1"))
        tool.failStatus = 51
        XCTAssertThrowsError(try store.readBlob()) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.keychainDenied))
        }
        XCTAssertThrowsError(try store.deleteBlob()) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.keychainDenied))
        }
        XCTAssertThrowsError(try store.writeBlob(bob)) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.keychainDenied))
        }
    }

    func testSecurityToolRoundTripOnAProbeItemWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGY_ACCOUNT_PROBE"] == "1" else {
            return
        }
        let store = LoginKeychainStore(service: "agy-cs-test-probe", account: "probe")
        defer { try? store.deleteBlob() }
        try store.deleteBlob()
        XCTAssertThrowsError(try store.readBlob()) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.keychainMissing))
        }
        let first = makeBlob(email: "alice@example.com", refresh: String(repeating: "r", count: 900))
        try store.writeBlob(first)
        XCTAssertEqual(try store.readBlob(), first)
        let fixed = "add-generic-password -U -s agy-cs-test-probe -a probe -w \(keychainPrefix)\n".utf8.count
        let room = securityLineLimit - fixed
        let longest = keychainPrefix + String(repeating: "A+/=", count: room / 4) + String(repeating: "A", count: room % 4)
        XCTAssertEqual(securityAddLine(service: store.service, account: store.account, blob: longest)?.utf8.count, securityLineLimit)
        XCTAssertThrowsError(try store.checkWritable(longest + "A"))
        try store.writeBlob(longest)
        XCTAssertEqual(try store.readBlob(), longest)
        XCTAssertEqual(try store.matchingItemCount(dataProtection: false), 1)
        try store.deleteBlob()
        XCTAssertThrowsError(try store.readBlob()) {
            XCTAssertEqual($0 as? AccountFailure, AccountFailure(.keychainMissing))
        }
        XCTAssertNoThrow(try store.deleteBlob())
    }
}

private final class ScriptedSecurityTool: SecurityToolRunning {
    var stored: String?
    var calls: [(arguments: [String], input: String?)] = []
    var failStatus: Int32?
    var garbleNextWrite = false

    func run(_ arguments: [String], input: Data?) throws -> SecurityToolResult {
        let text = input.map { String(decoding: $0, as: UTF8.self) }
        calls.append((arguments, text))
        if let failStatus {
            return SecurityToolResult(status: failStatus, output: Data())
        }
        switch arguments.first {
        case "find-generic-password":
            guard let stored else {
                return SecurityToolResult(status: 44, output: Data())
            }
            return SecurityToolResult(status: 0, output: Data((stored + "\n").utf8))
        case "delete-generic-password":
            guard stored != nil else {
                return SecurityToolResult(status: 44, output: Data())
            }
            stored = nil
            return SecurityToolResult(status: 0, output: Data("keychain: \"login.keychain-db\"\n".utf8))
        case "-i":
            let value = text?.components(separatedBy: " -w ").last?.trimmingCharacters(in: .newlines)
            stored = garbleNextWrite ? keychainPrefix + "AAAA" : value
            garbleNextWrite = false
            return SecurityToolResult(status: 0, output: Data())
        default:
            return SecurityToolResult(status: 1, output: Data())
        }
    }
}

final class MemoryKeychain: KeychainStoring {
    var blob: String
    var writes: [String] = []
    var reads = 0

    init(_ blob: String) {
        self.blob = blob
    }

    var missing = false
    var denied = false
    var writeLimit: Int?
    var onWrite: ((String) -> Void)?
    var onBeforeRestore: (() -> Void)?
    var writeAttempts = 0
    var failOnAttempt: Int?

    func checkWritable(_ blob: String) throws {
        if let writeLimit, blob.count > writeLimit {
            throw AccountFailure(.loginNotWritable)
        }
    }

    func readBlob() throws -> String {
        reads += 1
        if denied {
            throw AccountFailure(.keychainDenied)
        }
        if missing {
            throw AccountFailure(.keychainMissing)
        }
        return blob
    }

    func writeBlob(_ blob: String) throws {
        try checkWritable(blob)
        writeAttempts += 1
        if failOnAttempt == writeAttempts {
            throw AccountFailure(.writeMismatch)
        }
        writes.append(blob)
        self.blob = blob
        missing = false
        denied = false
        onWrite?(blob)
    }

    func restoreBlob(_ blob: String, ifCurrentEquals expected: String) throws -> Bool {
        onBeforeRestore?()
        try checkWritable(blob)
        let current: String
        do {
            current = try readBlob()
        } catch let error as AccountFailure where error.key == .keychainMissing {
            return false
        }
        guard current == expected else {
            return false
        }
        try writeBlob(blob)
        return true
    }

    func deleteBlob() throws {
        missing = true
    }
}

private final class ExplodingKeychain: KeychainStoring {
    var reads = 0

    func readBlob() throws -> String {
        reads += 1
        reads += 1
        throw AccountFailure(.keychainDenied)
    }

    func writeBlob(_ blob: String) throws {
        throw AccountFailure(.writeMismatch)
    }

    func deleteBlob() throws {
        throw AccountFailure(.keychainDenied)
    }

    func checkWritable(_ blob: String) throws {}
}

final class FixedProcesses: ProcessListing {
    var pids: [Int] = []

    func runningAgyPIDs() -> [Int] {
        pids
    }
}

struct CommandResult {
    var code: Int32
    var output: [String]
    var errors: [String]
}

final class ScriptedTerminal: LineReading {
    var isInteractive: Bool
    var lines: [String]

    init(isInteractive: Bool = false, lines: [String] = []) {
        self.isInteractive = isInteractive
        self.lines = lines
    }

    func readLine() -> String? {
        guard !lines.isEmpty else {
            return nil
        }
        return lines.removeFirst()
    }
}

final class ScriptedLauncher: AgyLaunching {
    var started = 0
    var launchesAfterSwitch = true
    var supply: (() -> Void)?
    var failure: AccountFailure?

    func runUntilLoggedIn(_ poll: () throws -> ObservedLogin?) throws -> LoginWatchResult {
        if let failure {
            throw failure
        }
        supply?()
        if let observed = try poll() {
            return .loggedIn(observed)
        }
        return .exited
    }

    func startInCurrentTerminal() throws {
        started += 1
    }
}

final class ScriptedUsage: UsageFetching {
    var budget: TimeInterval = 1
    var snapshots: [String: UsageSnapshot]?
    var calls: [[String]] = []

    var allowed: [TimeInterval] = []

    var hints: [[String]] = []

    func fetch(
        _ logins: [(name: String, blob: String, project: String)],
        within seconds: TimeInterval
    ) -> [String: UsageSnapshot] {
        calls.append(logins.map(\.name))
        hints.append(logins.map(\.project))
        allowed.append(seconds)
        var answer: [String: UsageSnapshot] = [:]
        for login in logins {
            answer[login.name] = snapshots.map { $0[login.name] } ?? UsageSnapshot(planID: "", planName: "", buckets: [])
        }
        return answer
    }
}

final class ScriptedRefresher: QuotaRefreshStarting {
    var started = 0
    var workers = 0

    func startDetached() {
        started += 1
    }

    func spawnWorker() {
        workers += 1
    }
}

final class ScriptedGuardStarter: GuardStarting {
    var started = 0
    var workers = 0
    var runs = 0

    func startDetached() {
        started += 1
    }

    func spawnWorker() {
        workers += 1
    }

    func runWorker() {
        runs += 1
    }
}

func cells(_ line: String) -> [String] {
    line.components(separatedBy: "  ")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

func localTime(_ timestamp: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: ISO8601DateFormatter().date(from: timestamp)!)
}

final class Fixture {
    let home: URL
    let keychain: MemoryKeychain
    let processes = FixedProcesses()
    let terminal = ScriptedTerminal()
    let launcher = ScriptedLauncher()
    let usage = ScriptedUsage()
    let refresher = ScriptedRefresher()
    let guarder = ScriptedGuardStarter()
    var stateWait: TimeInterval = 5
    var colab: ProviderServices?
    let locations: AccountLocations
    let tool: ToolLocations
    let quota: URL
    let conversation: URL

    init(blob: String, markInitialized: Bool = true) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        keychain = MemoryKeychain(blob)
        locations = AccountLocations(home: home)
        tool = ToolLocations(home: home)
        try FileManager.default.createDirectory(at: tool.root, withIntermediateDirectories: true)
        try Data("zh-Hans\n".utf8).write(to: tool.languageFile)
        if markInitialized {
            try Data("1\n".utf8).write(to: tool.initializedFile)
        }
        quota = locations.quotaCache
        conversation = home
            .appendingPathComponent(".gemini/antigravity-cli/conversations/keep.txt")
        try FileManager.default.createDirectory(
            at: quota.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: quota)
        try FileManager.default.createDirectory(
            at: conversation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: conversation)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }

    func writeLegacyRecord(name: String, blob: String) throws {
        let now = { "2026-01-01T00:00:00Z" }
        let meta = try decodeLogin(blob, source: .saved)
        try AccountFiles(locations: locations, now: now).writeSaved(name: name, blob: blob, meta: meta)
        try ToolProfile(home: home, now: now, preferredLanguages: ["zh-Hans"]).write(name: name, meta: meta)
    }

    // 菜单栏面板用的入口，和 run 用同一套假的钥匙串和查询。面板没有终端。
    var board: AccountBoard {
        AccountBoard(services: CommandServices(
            home: home,
            keychain: keychain,
            processes: processes,
            now: { "2026-01-01T00:00:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: NoTerminal(),
            launcher: launcher,
            usage: usage,
            refresher: refresher,
            guarder: guarder,
            stateWait: stateWait,
            colab: colab
        ))
    }

    func run(_ args: [String]) -> CommandResult {
        let capture = Capture()
        let code = AgyAccountCLI.run(
            args,
            home: home,
            keychain: keychain,
            processes: processes,
            now: { "2026-01-01T00:00:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: terminal,
            launcher: launcher,
            usage: usage,
            refresher: refresher,
            guarder: guarder,
            colab: colab,
            stdout: { capture.output.append($0) },
            stderr: { capture.errors.append($0) }
        )
        return CommandResult(code: code, output: capture.output, errors: capture.errors)
    }
}

final class Capture {
    var output: [String] = []
    var errors: [String] = []
}

func makeBlob(email: String, refresh: String = "refresh-token", expiry: String = "2026-01-01T00:00:00Z") -> String {
    let object: [String: Any] = [
        "id_token_email": email,
        "auth_method": "consumer",
        "token": [
            "refresh_token": refresh,
            "access_token": "access-token",
            "expiry": expiry,
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return "go-keyring-base64:" + data.base64EncodedString()
}

private func runCommand(
    args: [String],
    keychain: any KeychainStoring,
    preferred: [String] = ["zh-Hans"],
    home: URL? = nil,
    markInitialized: Bool = true
) -> CommandResult {
    let root = home ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(".agy-cs", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if markInitialized {
        try? Data("1\n".utf8).write(to: directory.appendingPathComponent("initialized"))
    }
    let capture = Capture()
    let code = AgyAccountCLI.run(
        args,
        home: root,
        keychain: keychain,
        processes: FixedProcesses(),
        now: { "2026-01-01T00:00:00Z" },
        preferredLanguages: preferred,
        terminal: ScriptedTerminal(),
        launcher: ScriptedLauncher(),
        usage: ScriptedUsage(),
        refresher: ScriptedRefresher(),
        stdout: { capture.output.append($0) },
        stderr: { capture.errors.append($0) }
    )
    return CommandResult(code: code, output: capture.output, errors: capture.errors)
}

func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let value = attributes[.posixPermissions] as? NSNumber
    return (value?.intValue ?? -1) & 0o777
}
