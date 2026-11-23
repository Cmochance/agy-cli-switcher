import AppKit
import SwiftUI
import XCTest
@testable import AgyAccount
@testable import AgyMenuBar

final class BoardTests: XCTestCase {
    func testMenuBarOnlyStartsWhenTheSystemOpenedTheApp() {
        let marked = [menuBarMarker: "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        XCTAssertEqual(launchMode(arguments: [], environment: marked, parent: 1), .menuBar)
        XCTAssertEqual(launchMode(arguments: ["ls"], environment: marked, parent: 1), .commandLine)
        XCTAssertEqual(launchMode(arguments: ["refresh", "quota", "--detach"], environment: marked, parent: 1), .commandLine)
        XCTAssertEqual(launchMode(arguments: [], environment: marked, parent: 4242), .commandLine)
        XCTAssertEqual(launchMode(arguments: [], environment: ["PATH": "/usr/bin"], parent: 1), .commandLine)
        XCTAssertEqual(launchMode(arguments: [], environment: [menuBarMarker: "0"], parent: 1), .commandLine)
    }

    func testBoardShowsWhatListShowsAndRunsTheSameCommands() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        let board = fixture.board
        XCTAssertEqual(board.perform(["save", "alice"]).output, ["已保存 alice  alice@example.com"])
        fixture.keychain.blob = bob
        XCTAssertTrue(board.perform(["save", "bob"]).succeeded)
        let reads = fixture.keychain.reads

        var state = board.load()
        XCTAssertFalse(state.failed)
        XCTAssertEqual(state.notices, [])
        XCTAssertEqual(state.language, "zh-Hans")
        XCTAssertEqual(state.rows, [
            AccountRow(name: "alice", email: "alice@example.com", isCurrent: false, usage: nil),
            AccountRow(name: "bob", email: "bob@example.com", isCurrent: true, usage: nil),
        ])
        XCTAssertEqual(fixture.keychain.reads, reads + 1)
        XCTAssertTrue(fixture.usage.calls.isEmpty)

        let switched = board.perform(["switch", "alice"])
        XCTAssertTrue(switched.succeeded)
        XCTAssertNil(switched.failure)
        XCTAssertEqual(switched.output.first, "已切换到 alice  alice@example.com")
        XCTAssertEqual(switched.errors, [])
        XCTAssertEqual(fixture.keychain.writes, [alice])
        XCTAssertEqual(fixture.refresher.started, 1)
        XCTAssertEqual(fixture.launcher.started, 0)

        fixture.usage.snapshots = ["alice": UsageSnapshot(planID: "g1-pro-tier", planName: "", buckets: [
            UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-01-01T03:00:00Z"),
        ], argonLocked: true)]
        let partial = board.perform(["refresh", "quota"])
        XCTAssertEqual(partial.code, 1)
        XCTAssertEqual(partial.failure, .usageFailed)
        state = board.load()
        XCTAssertEqual(state.rows.map(\.isCurrent), [true, false])
        XCTAssertEqual(
            state.rows[0].usage,
            UsageText(plan: "Pro（非付费）", fiveHour: "62% \(localTime("2026-01-01T03:00:00Z"))", weekly: "—", argon: "—")
        )
        XCTAssertNil(state.rows[1].usage)
        XCTAssertEqual(state.notices, partial.errors)
        XCTAssertTrue(state.notices[0].contains("bob"))
        let listed = fixture.run(["list"])
        XCTAssertEqual(listed.errors, state.notices)
        XCTAssertEqual(cells(listed.output[0]), ["* alice", "alice@example.com"] + (state.rows[0].usage?.cells ?? []))

        let writes = fixture.keychain.writes
        XCTAssertEqual(board.perform(["switch"]).failure, .switchNeedsTerminal)
        XCTAssertEqual(board.perform(["switch", "add"]).failure, .switchAddNeedsTerminal)
        XCTAssertEqual(fixture.keychain.writes, writes)
        XCTAssertFalse(fixture.keychain.missing)

        XCTAssertEqual(board.perform(["rm", "alice"]).failure, .onlyCopy)
        XCTAssertEqual(board.load().rows.count, 2)
        XCTAssertTrue(board.perform(["rm", "alice", "--force"]).succeeded)
        XCTAssertEqual(board.load().rows.map(\.name), ["bob"])

        XCTAssertTrue(board.perform(["language", "en"]).succeeded)
        XCTAssertEqual(board.load().language, "en")
        XCTAssertEqual(board.load().text.line(.panelQuit), "Quit")
        XCTAssertEqual(AccountBoard.languages.map(\.code), ["zh-Hans", "zh-Hant", "en", "ja"])

        // 列出名字之后、读它之前被别的进程删掉的记录：跳过，不算整份名单读不出来。
        try FileManager.default.createSymbolicLink(
            at: fixture.tool.profileURL("ghost"),
            withDestinationURL: fixture.tool.profileURL("gone-meanwhile")
        )
        XCTAssertFalse(board.load().failed)
        XCTAssertEqual(board.load().rows.map(\.name), ["bob"])
        XCTAssertEqual(fixture.run(["list"]).code, 0)

        try Data("{".utf8).write(to: fixture.tool.profileURL("bob"))
        let broken = board.load()
        XCTAssertTrue(broken.failed)
        XCTAssertEqual(broken.rows, [])
        XCTAssertEqual(broken.notices.count, 1)
    }

    func testBoardInitializesOnTheFirstLoadLikeTheCommandLine() throws {
        let fixture = try Fixture(blob: makeBlob(email: "carol@example.com"), markInitialized: false)
        defer { fixture.cleanup() }
        let first = fixture.board.load()
        XCTAssertEqual(first.notices, ["已初始化当前登录: carol  carol@example.com"])
        XCTAssertEqual(first.rows, [AccountRow(name: "carol", email: "carol@example.com", isCurrent: true, usage: nil)])
        XCTAssertEqual(fixture.keychain.reads, 2)
        XCTAssertEqual(fixture.board.load().notices, [])
        XCTAssertEqual(fixture.keychain.reads, 3)
        XCTAssertEqual(fixture.keychain.writes, [])
    }

    // save 不替换另一个登录存的那一份，带 --force 才替换。面板上看到的一行可能已经过时，
    // 带着 --expect 的指令在动手之前核对这个名字下面存的是谁。
    func testExpectedHolderIsCheckedBeforeReplacingOrDeleting() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        let board = fixture.board
        func saved(_ name: String) throws -> String {
            try AccountFiles(locations: fixture.locations, now: { "" }).readSaved(name).meta.email
        }

        XCTAssertTrue(board.perform(["save", "work"]).succeeded)
        XCTAssertTrue(board.perform(["save", "work"]).succeeded)
        fixture.keychain.blob = bob
        let taken = board.perform(["save", "work"])
        XCTAssertEqual(taken.code, 1)
        XCTAssertEqual(taken.failure, .saveWouldReplace)
        XCTAssertEqual(taken.details, ["work", "alice@example.com"])
        XCTAssertTrue(taken.errors.joined().contains("agy-cs save work --force"))
        XCTAssertEqual(try saved("work"), "alice@example.com")
        XCTAssertEqual(board.perform(["save", "work", "--expect", "alice@example.com"]).failure, .saveWouldReplace)
        XCTAssertEqual(board.perform(["save", "work", "--force", "--expect", "carol@example.com"]).failure, .saveWouldReplace)
        XCTAssertEqual(try saved("work"), "alice@example.com")
        XCTAssertTrue(board.perform(["save", "work", "--force", "--expect", "alice@example.com"]).succeeded)
        XCTAssertEqual(try saved("work"), "bob@example.com")
        fixture.keychain.blob = alice
        XCTAssertTrue(board.perform(["save", "work", "--force"]).succeeded)
        XCTAssertEqual(try saved("work"), "alice@example.com")
        XCTAssertTrue(board.perform(["save", "--force", "fresh"]).succeeded)
        XCTAssertEqual(try saved("fresh"), "alice@example.com")
        // 副本读不出邮箱时，也算被别人占着。
        try Data("broken\n".utf8).write(to: fixture.locations.tokenURL("work"))
        XCTAssertEqual(board.perform(["save", "work"]).details, ["work", ""])
        XCTAssertEqual(board.perform(["save", "work", "--force", "--expect", "alice@example.com"]).details, ["work", ""])
        XCTAssertTrue(board.perform(["save", "work", "--force"]).succeeded)
        XCTAssertEqual(try saved("work"), "alice@example.com")

        fixture.keychain.blob = bob
        XCTAssertTrue(board.perform(["save", "spare"]).succeeded)
        let changed = board.perform(["rm", "spare", "--expect", "alice@example.com"])
        XCTAssertEqual(changed.failure, .accountChanged)
        XCTAssertEqual(changed.details, ["spare", "bob@example.com"])
        XCTAssertEqual(board.perform(["rm", "spare", "--force", "--expect", "alice@example.com"]).failure, .accountChanged)
        XCTAssertEqual(try saved("spare"), "bob@example.com")
        XCTAssertEqual(board.perform(["rm", "spare", "--expect", "bob@example.com"]).failure, .onlyCopy)
        XCTAssertTrue(board.perform(["rm", "spare", "--expect", "bob@example.com", "--force"]).succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("spare").path))

        for wrong in [
            ["rm", "work", "--expect"], ["save", "work", "--expect"], ["save", "work", "--other"], ["save", "work", "more"],
            ["save"], ["save", "--force"],
        ] {
            XCTAssertEqual(board.perform(wrong).code, 2, wrong.joined(separator: " "))
        }

        // 以前留下的、名字正好是 add 的记录：switch -- add 是切换，switch add 仍是新增账号。
        fixture.keychain.blob = alice
        try fixture.writeLegacyRecord(name: "add", blob: bob)
        XCTAssertEqual(board.perform(["switch", "add"]).failure, .switchAddNeedsTerminal)
        XCTAssertEqual(fixture.keychain.blob, alice)
        let legacy = board.perform(["switch", "--", "add"])
        XCTAssertTrue(legacy.succeeded)
        XCTAssertEqual(legacy.output.first, "已切换到 add  bob@example.com")
        XCTAssertEqual(fixture.keychain.blob, bob)
        XCTAssertEqual(board.perform(["switch", "--", "work", "extra"]).code, 2)
    }

    // move 把一个账号移到列表的第几位。顺序记在 ~/.agy-cs/order，list、next 和面板都按它。
    func testMoveSetsTheOrderEveryListFollows() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        for name in ["alice", "bob", "carol"] {
            fixture.keychain.blob = makeBlob(email: "\(name)@example.com", refresh: name)
            XCTAssertEqual(fixture.run(["save", name]).code, 0)
        }
        let board = fixture.board
        let reads = fixture.keychain.reads
        func names() -> [String] {
            board.load().rows.map(\.name)
        }
        XCTAssertEqual(names(), ["alice", "bob", "carol"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tool.orderFile.path))

        XCTAssertEqual(board.perform(["move", "carol", "1"]).output, ["已把 carol 移到第 1 位"])
        XCTAssertEqual(names(), ["carol", "alice", "bob"])
        XCTAssertTrue(board.perform(["move", "alice", "3"]).succeeded)
        XCTAssertEqual(names(), ["carol", "bob", "alice"])
        XCTAssertTrue(board.perform(["move", "bob", "2"]).succeeded)
        XCTAssertEqual(names(), ["carol", "bob", "alice"])
        XCTAssertEqual(try String(contentsOf: fixture.tool.orderFile, encoding: .utf8), "carol\nbob\nalice\n")
        XCTAssertEqual(try mode(fixture.tool.orderFile), 0o600)
        XCTAssertEqual(fixture.keychain.reads, reads + 4)
        XCTAssertEqual(fixture.run(["list"]).output.map { cells($0)[0] }, ["* carol", "bob", "alice"])

        // next 按这个顺序往下走，到头回到第一个。
        XCTAssertEqual(fixture.run(["next"]).output.first, "已切换到 bob  bob@example.com")
        XCTAssertEqual(fixture.run(["next"]).output.first, "已切换到 alice  alice@example.com")
        XCTAssertEqual(fixture.run(["next"]).output.first, "已切换到 carol  carol@example.com")

        // 新存的账号排在最后，先存的在前，不按字母。同一个名字再存一次不挪位置。
        fixture.keychain.blob = makeBlob(email: "zoe@example.com", refresh: "z")
        XCTAssertEqual(fixture.run(["save", "zoe"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "dave@example.com", refresh: "d")
        XCTAssertEqual(fixture.run(["save", "aaron"]).code, 0)
        XCTAssertEqual(names(), ["carol", "bob", "alice", "zoe", "aaron"])
        XCTAssertEqual(fixture.run(["save", "aaron"]).code, 0)
        XCTAssertEqual(names(), ["carol", "bob", "alice", "zoe", "aaron"])
        // 改名留在原位。删掉的名字以后再存，不占原来的位置。
        XCTAssertEqual(fixture.run(["rename", "bob", "zed"]).code, 0)
        XCTAssertEqual(names(), ["carol", "zed", "alice", "zoe", "aaron"])
        XCTAssertEqual(fixture.run(["rm", "zed"]).code, 0)
        XCTAssertEqual(fixture.run(["rm", "zoe"]).code, 0)
        XCTAssertEqual(names(), ["carol", "alice", "aaron"])
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "zed"]).code, 0)
        XCTAssertEqual(names(), ["carol", "alice", "aaron", "zed"])

        // 从没排过顺序时改名，也留在原来的位置，不按新名字重新排。
        let plain = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { plain.cleanup() }
        for name in ["alice", "bob", "carol"] {
            plain.keychain.blob = makeBlob(email: "\(name)@example.com", refresh: name)
            XCTAssertEqual(plain.run(["save", name]).code, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.tool.orderFile.path))
        XCTAssertEqual(plain.run(["rename", "bob", "zed"]).code, 0)
        XCTAssertEqual(plain.board.load().rows.map(\.name), ["alice", "zed", "carol"])
        XCTAssertEqual(plain.run(["rename", "carol", "abe"]).code, 0)
        XCTAssertEqual(plain.board.load().rows.map(\.name), ["alice", "zed", "abe"])

        let before = names()
        XCTAssertEqual(board.perform(["move", "nobody", "1"]).failure, .accountMissing)
        for wrong in ["0", "5", "-1", "two", ""] {
            let refused = board.perform(["move", "alice", wrong])
            XCTAssertEqual(refused.code, 1, wrong)
            XCTAssertEqual(refused.failure, .moveBadPosition, wrong)
            XCTAssertEqual(refused.details, ["4"], wrong)
        }
        for wrong in [["move"], ["move", "alice"], ["move", "alice", "1", "2"]] {
            let refused = board.perform(wrong)
            XCTAssertEqual(refused.code, 2)
            XCTAssertEqual(refused.failure, .moveNeedsNameAndPosition)
        }
        XCTAssertEqual(names(), before)

        // order 里写着不存在的名字、重复的名字都不碍事。
        try "ghost\nalice\nalice\n../x\ncarol\n".write(to: fixture.tool.orderFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(names(), ["alice", "carol", "aaron", "zed"])
    }

    // 拖动一行时的位置计算。三行高 50、30、50，挨着排。
    func testDraggedRowFollowsThePointerAndTheOthersMakeRoom() {
        let frames = [
            CGRect(x: 0, y: 0, width: 420, height: 50),
            CGRect(x: 0, y: 50, width: 420, height: 30),
            CGRect(x: 0, y: 80, width: 420, height: 50),
        ]
        func drag(_ index: Int, _ translation: CGFloat) -> RowDrag {
            RowDrag(index: index, frames: frames, translation: translation)
        }
        func shifts(_ drag: RowDrag) -> [CGFloat] {
            frames.indices.map(drag.shift)
        }

        XCTAssertEqual(drag(0, 0).target, 0)
        XCTAssertEqual(shifts(drag(0, 0)), [0, 0, 0])
        // 往下拖：下沿越过下一行的中线才换位。
        XCTAssertEqual(drag(0, 14).target, 0)
        XCTAssertEqual(drag(0, 20).target, 1)
        XCTAssertEqual(drag(0, 20).offset, 20)
        XCTAssertEqual(shifts(drag(0, 20)), [0, -50, 0])
        XCTAssertEqual(drag(1, 30).target, 2)
        XCTAssertEqual(shifts(drag(1, 30)), [0, 0, -30])
        // 拖过头：停在列表的边上，排到最后或最前。
        XCTAssertEqual(drag(0, 1000).offset, 80)
        XCTAssertEqual(drag(0, 1000).target, 2)
        XCTAssertEqual(shifts(drag(0, 1000)), [0, -50, -50])
        XCTAssertEqual(drag(2, -1000).offset, -80)
        XCTAssertEqual(drag(2, -1000).target, 0)
        XCTAssertEqual(shifts(drag(2, -1000)), [50, 50, 0])
        // 往上拖：上沿越过上一行的中线才换位。
        XCTAssertEqual(drag(2, -10).target, 2)
        XCTAssertEqual(drag(2, -20).target, 1)
        XCTAssertEqual(shifts(drag(2, -20)), [0, 50, 0])
        // 对不上的行号什么都不做。
        XCTAssertEqual(drag(7, 40).target, 7)
        XCTAssertEqual(drag(7, 40).offset, 0)
        XCTAssertEqual(shifts(drag(7, 40)), [0, 0, 0])
        XCTAssertEqual(RowDrag(index: 0, frames: [], translation: 40).offset, 0)
    }

    @MainActor
    func testPanelMovesARowAtOnceAndRecordsTheOrder() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        for name in ["alice", "bob", "carol"] {
            fixture.keychain.blob = makeBlob(email: "\(name)@example.com", refresh: name)
            XCTAssertEqual(fixture.run(["save", name]).code, 0)
        }
        let model = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bob", "carol"])

        // 松手的那一下面板上就换好了，不等指令执行完，也不显示“正在处理”。
        model.move(model.state.rows[2], to: 0)
        XCTAssertEqual(model.state.rows.map(\.name), ["carol", "alice", "bob"])
        XCTAssertNil(model.busyLabel)
        XCTAssertFalse(model.isWorking)
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["carol", "alice", "bob"])
        XCTAssertEqual(model.lines, [])
        XCTAssertFalse(model.showsFailure)
        XCTAssertEqual(fixture.run(["list"]).output.map { cells($0)[0] }, ["* carol", "alice", "bob"])
        model.move(model.state.rows[0], to: 2)
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bob", "carol"])

        // 放回原位、位置对不上、这一行已经不在了：什么都不做。
        let order = try String(contentsOf: fixture.tool.orderFile, encoding: .utf8)
        model.move(model.state.rows[1], to: 1)
        model.move(model.state.rows[1], to: 3)
        model.move(model.state.rows[1], to: -1)
        model.move(AccountRow(name: "gone", email: "gone@example.com", isCurrent: false, usage: nil), to: 0)
        XCTAssertNil(model.busy)
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bob", "carol"])
        XCTAssertEqual(try String(contentsOf: fixture.tool.orderFile, encoding: .utf8), order)

        // 面板上的顺序已经过时：指令按名字移，结果以记下来的为准。
        XCTAssertEqual(fixture.run(["rm", "alice"]).code, 0)
        model.move(model.state.rows[2], to: 0)
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["carol", "bob"])
        XCTAssertFalse(model.showsFailure)
    }

    func testAddAccountCommandOnlyNamesThisProgram() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com"))
        defer { fixture.cleanup() }
        let bundled = "/Applications/Agy Switcher.app/Contents/MacOS/agy-cs"
        let url = try fixture.board.writeAddAccountCommand(executable: bundled)
        XCTAssertEqual(url, fixture.tool.addCommandFile)
        XCTAssertEqual(url.pathExtension, "command")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "#!/bin/sh\nexec '/Applications/Agy Switcher.app/Contents/MacOS/agy-cs' switch add\n"
        )
        XCTAssertEqual(try mode(url), 0o700)
        XCTAssertEqual(try mode(fixture.tool.root), 0o700)
        XCTAssertEqual(
            fixture.board.addAccountCommandLine(executable: bundled),
            "'/Applications/Agy Switcher.app/Contents/MacOS/agy-cs' switch add"
        )

        // 路径里的空格、引号、$ 和反引号都不能变成别的指令：真的交给 sh 执行一遍。
        let folder = fixture.home.appendingPathComponent("it's a $HOME `id` folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seen = fixture.home.appendingPathComponent("seen")
        let program = folder.appendingPathComponent("agy-cs")
        try "#!/bin/sh\nprintf '%s\\n' \"$#\" \"$@\" > '\(seen.path)'\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let script = try fixture.board.writeAddAccountCommand(executable: program.path)
        let shell = Process()
        shell.executableURL = script
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), "2\nswitch\nadd\n")
    }

    @MainActor
    func testPanelRunsOneActionAtATimeAndAsksBeforeDeletingTheLastCopy() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        var opened: [URL] = []
        let model = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { url in
            opened.append(url)
            return true
        })
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bob"])
        XCTAssertNil(model.busy)
        XCTAssertEqual(model.lines, [])

        model.switchTo(model.state.rows[0])
        XCTAssertNotNil(model.busy)
        model.refresh()
        await settle(model)
        XCTAssertEqual(model.messages.first, "已切换到 alice  alice@example.com")
        XCTAssertFalse(model.showsFailure)
        XCTAssertTrue(fixture.usage.calls.isEmpty)
        XCTAssertEqual(model.state.rows.map(\.isCurrent), [true, false])

        model.ask(.rename(model.state.rows[0]))
        XCTAssertEqual(model.draft, "alice")
        model.draft = "  anna "
        model.confirm()
        await settle(model)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.state.rows.map(\.name), ["anna", "bob"])

        let anna = model.state.rows[0]
        model.ask(.remove(anna))
        model.confirm()
        await settle(model)
        XCTAssertEqual(model.prompt, .removeLastCopy(anna))
        XCTAssertEqual(model.messages, [])
        XCTAssertFalse(model.showsFailure)
        XCTAssertEqual(model.state.rows.count, 2)
        model.cancel()
        XCTAssertNil(model.prompt)
        model.ask(.remove(anna))
        model.confirm()
        await settle(model)
        model.confirm()
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["bob"])
        XCTAssertFalse(model.showsFailure)

        model.ask(.save)
        model.draft = "add"
        model.confirm()
        await settle(model)
        XCTAssertTrue(model.showsFailure)
        XCTAssertTrue(model.lines.joined().contains("不能当作账号名"))

        model.refresh()
        await settle(model)
        XCTAssertEqual(fixture.usage.calls.count, 1)
        XCTAssertEqual(model.messages, ["套餐和额度已更新。"])
        XCTAssertFalse(model.showsFailure)

        model.setLanguage("en")
        await settle(model)
        XCTAssertEqual(model.messages, ["Language set to en English"])
        XCTAssertEqual(model.text(.panelRenamePrompt, "bob"), "New name for bob")

        model.addAccount()
        await settle(model)
        XCTAssertEqual(opened, [fixture.tool.addCommandFile])
        XCTAssertEqual(model.messages, [model.text(.panelAddOpened)])
        XCTAssertTrue(try String(contentsOf: fixture.tool.addCommandFile, encoding: .utf8).contains("'/somewhere/agy-cs' switch add"))

        let refused = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in false })
        refused.addAccount()
        await settle(refused)
        XCTAssertTrue(refused.showsFailure)
        XCTAssertEqual(refused.messages, ["Couldn't open the terminal. Run this in a terminal yourself: '/somewhere/agy-cs' switch add"])
    }

    @MainActor
    func testPanelAsksBeforeReplacingANameAndRefusesAStaleDelete() async throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "work"]).code, 0)
        XCTAssertEqual(fixture.run(["save", "travel"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        func saved(_ name: String) throws -> String {
            try AccountFiles(locations: fixture.locations, now: { "" }).readSaved(name).meta.email
        }
        func active() -> String {
            ToolProfile(home: fixture.home, now: { "" }, preferredLanguages: []).activeName()
        }
        let model = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        XCTAssertEqual(model.state.rows.map(\.name), ["bob", "travel", "work"])

        // 要存的名字下面是别的登录：先问，问之前什么都不覆盖。
        model.ask(.save)
        model.draft = "work"
        model.confirm()
        await settle(model)
        XCTAssertEqual(model.prompt, .replace(name: "work", holder: "alice@example.com"))
        XCTAssertEqual(model.messages, [])
        XCTAssertFalse(model.showsFailure)
        XCTAssertEqual(try saved("work"), "alice@example.com")
        model.cancel()
        XCTAssertEqual(try saved("work"), "alice@example.com")
        model.ask(.save)
        model.draft = "work"
        model.confirm()
        await settle(model)
        model.confirm()
        await settle(model)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.messages, ["已保存 work  bob@example.com"])
        XCTAssertEqual(try saved("work"), "bob@example.com")
        XCTAssertEqual(active(), "work")

        // 同一个登录存了两个名字：两行都打勾，点另一行把它记成当前项，不改钥匙串。
        // 面板上平时只显示邮箱，这两行邮箱一样，所以带上名字。
        XCTAssertEqual(model.state.rows.map(\.isCurrent), [true, false, true])
        XCTAssertEqual(model.state.rows.map(model.showsName), [true, false, true])
        let writes = fixture.keychain.writes
        model.switchTo(model.state.rows[0])
        await settle(model)
        XCTAssertEqual(model.messages, ["已经是 bob  bob@example.com"])
        XCTAssertEqual(active(), "bob")
        XCTAssertEqual(fixture.keychain.writes, writes)

        // 确认删除的那一下，这个名字已经存成了别的登录：不删。
        model.ask(.remove(model.state.rows[1]))
        fixture.keychain.blob = makeBlob(email: "carol@example.com", refresh: "c")
        XCTAssertEqual(fixture.run(["save", "travel", "--force"]).code, 0)
        model.confirm()
        await settle(model)
        XCTAssertNil(model.prompt)
        XCTAssertTrue(model.showsFailure)
        XCTAssertEqual(model.messages, ["travel 现在保存的是 carol@example.com，和刚才看到的不一样，所以没有删除。"])
        XCTAssertEqual(try saved("travel"), "carol@example.com")
        XCTAssertEqual(model.state.rows[1], AccountRow(name: "travel", email: "carol@example.com", isCurrent: true, usage: nil))

        // 以前留下的、名字正好是 add 的记录：点它是切换，不是新增账号。
        try fixture.writeLegacyRecord(name: "add", blob: alice)
        let later = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        later.switchTo(try XCTUnwrap(later.state.rows.first { $0.name == "add" }))
        await settle(later)
        XCTAssertFalse(later.showsFailure)
        XCTAssertEqual(later.messages.first, "已切换到 add  alice@example.com")
        XCTAssertEqual(fixture.keychain.blob, alice)
    }

    @MainActor
    func testPanelRereadsWhileItIsOpenAndForgetsFinishedWorkOnceClosed() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        var visible = true
        let model = PanelModel(
            board: fixture.board,
            executable: "/somewhere/agy-cs",
            rereadEvery: 0.05,
            shown: { visible },
            open: { _ in true }
        )
        func wait(until done: () -> Bool) async {
            for _ in 0 ..< 300 where !done() {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        model.panelOpened()
        XCTAssertEqual(fixture.run(["rename", "bob", "bobby"]).code, 0)
        await wait { model.state.rows.map(\.name) == ["alice", "bobby"] }
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bobby"])

        model.switchTo(model.state.rows[0])
        await settle(model)
        XCTAssertFalse(model.messages.isEmpty)
        model.ask(.save)
        model.draft = "half typed"
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.prompt, .save)
        XCTAssertEqual(model.draft, "half typed")
        XCTAssertFalse(model.messages.isEmpty)

        visible = false
        await wait { model.prompt == nil }
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.messages, [])
        XCTAssertEqual(fixture.run(["rename", "bobby", "bob"]).code, 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bobby"])

        // 没做成的那句话留到下次打开。
        model.ask(.save)
        model.draft = "add"
        model.confirm()
        await settle(model)
        model.panelOpened()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.showsFailure)
        XCTAssertFalse(model.messages.isEmpty)
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bob"])
    }

    // 当前账号看钥匙串，不看 active：别的进程把钥匙串换成另一个已保存的登录，list、current 和面板都跟着变，active 被改正。
    func testCurrentAccountFollowsTheKeychain() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = bob
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        XCTAssertEqual(try String(contentsOf: fixture.tool.activeFile, encoding: .utf8), "bob\n")

        // 一个还开着的 agy 把自己的登录写回了钥匙串。
        fixture.keychain.blob = makeBlob(email: "alice@example.com", refresh: "a-refreshed")
        let listed = fixture.run(["list"])
        XCTAssertEqual(listed.output, ["* alice  alice@example.com", "  bob  bob@example.com"])
        XCTAssertEqual(listed.errors, [])
        XCTAssertEqual(fixture.run(["current"]).output, ["alice@example.com"])
        XCTAssertEqual(fixture.board.load().rows.map(\.isCurrent), [true, false])
        XCTAssertEqual(try String(contentsOf: fixture.tool.activeFile, encoding: .utf8), "alice\n")
        XCTAssertEqual(try String(contentsOf: fixture.locations.activeURL, encoding: .utf8), "alice\n")
        // 看一眼不回存 token，也不写钥匙串。
        XCTAssertEqual(stripNewlines(try String(contentsOf: fixture.locations.tokenURL("alice"), encoding: .utf8)), alice)
        XCTAssertEqual(fixture.keychain.writes, [])
        XCTAssertEqual(fixture.refresher.started, 0)

        // 同一个邮箱存了几个名字时，active 仍然决定指的是哪个名字。
        XCTAssertEqual(fixture.run(["save", "work"]).code, 0)
        XCTAssertEqual(fixture.run(["rename", "office"]).output, ["已把 work 改名为 office  alice@example.com"])
        XCTAssertEqual(fixture.run(["switch", "alice"]).code, 0)
        XCTAssertEqual(fixture.run(["rename", "home"]).output, ["已把 alice 改名为 home  alice@example.com"])

        // 钥匙串那一项不在：没有打勾，记录不动。
        fixture.keychain.missing = true
        let none = fixture.run(["list"])
        XCTAssertEqual(none.code, 0)
        XCTAssertEqual(none.output.map { $0.hasPrefix("*") }, [false, false, false])
        XCTAssertEqual(none.errors, ["现在没有登录。在 agy 里登录之后会自动保存。"])
        let nobody = fixture.run(["current"])
        XCTAssertEqual(nobody.code, 1)
        XCTAssertEqual(nobody.output, [])
        XCTAssertEqual(nobody.errors, ["现在没有登录。在 agy 里登录之后会自动保存。"])
        XCTAssertEqual(fixture.board.load().notices, ["现在没有登录。在 agy 里登录之后会自动保存。"])
        XCTAssertEqual(try String(contentsOf: fixture.tool.activeFile, encoding: .utf8), "home\n")
        fixture.keychain.missing = false

        // 钥匙串读不出来：退回 active 记的那个，并说一声。
        fixture.keychain.denied = true
        let stale = fixture.run(["list"])
        XCTAssertEqual(stale.output.map { $0.hasPrefix("*") }, [true, false, true])
        XCTAssertEqual(stale.errors, ["读不到钥匙串里的登录，打勾的是上次记下的账号。"])
        XCTAssertEqual(fixture.run(["current"]).output, ["alice@example.com"])
    }

    // 钥匙串里的登录还没保存过时直接存下来，不提示；名字被别的邮箱占着就加 -2；名字起不出来才说一声。
    func testAnUnsavedLoginIsSavedWithoutAsking() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        XCTAssertEqual(fixture.run(["move", "bob", "1"]).code, 0)

        let bob = makeBlob(email: "bob@example.com", refresh: "b")
        fixture.keychain.blob = bob
        let listed = fixture.run(["list"])
        XCTAssertEqual(listed.output, ["  bob  alice@example.com", "* bob-2  bob@example.com"])
        XCTAssertEqual(listed.errors, [])
        XCTAssertEqual(stripNewlines(try String(contentsOf: fixture.locations.tokenURL("bob-2"), encoding: .utf8)), bob)
        XCTAssertEqual(stripNewlines(try String(contentsOf: fixture.locations.tokenURL("bob"), encoding: .utf8)), alice)
        XCTAssertEqual(try mode(fixture.locations.tokenURL("bob-2")), 0o600)
        XCTAssertEqual(try String(contentsOf: fixture.tool.activeFile, encoding: .utf8), "bob-2\n")
        XCTAssertEqual(fixture.refresher.started, 1)
        XCTAssertEqual(fixture.run(["list"]).output, listed.output)
        XCTAssertEqual(fixture.refresher.started, 1)

        // 面板重读时也一样。
        fixture.keychain.blob = makeBlob(email: "carol@example.com", refresh: "c")
        let state = fixture.board.load()
        XCTAssertEqual(state.rows.map(\.name), ["bob", "bob-2", "carol"])
        XCTAssertEqual(state.rows.map(\.isCurrent), [false, false, true])
        XCTAssertEqual(state.notices, [])
        XCTAssertEqual(fixture.run(["current"]).output, ["carol@example.com"])

        fixture.keychain.blob = makeBlob(email: "a+b@example.com", refresh: "x")
        let rejected = fixture.run(["list"])
        XCTAssertEqual(rejected.output.map { $0.hasPrefix("*") }, [false, false, false])
        XCTAssertEqual(rejected.errors, ["当前登录 a+b@example.com 没能自动保存。用 agy-cs save <名字> 保存。"])
        XCTAssertEqual(fixture.run(["current"]).output, ["a+b@example.com"])
        XCTAssertEqual(fixture.keychain.writes, [])

        // refresh quota 先把没保存过的登录存下来，这一次就一起查，不另起进程。
        let fresh = try Fixture(blob: alice)
        defer { fresh.cleanup() }
        XCTAssertEqual(fresh.run(["save", "alice"]).code, 0)
        fresh.keychain.blob = bob
        XCTAssertEqual(fresh.run(["refresh", "quota"]).code, 0)
        XCTAssertEqual(fresh.usage.calls, [["alice", "bob"]])
        XCTAssertEqual(fresh.refresher.started, 0)
        let usageLock = try XCTUnwrap(fresh.board.services.profile.lockUsage(wait: 0))
        XCTAssertNotEqual(fcntl(usageLock.descriptor, F_GETFD) & FD_CLOEXEC, 0)
        close(usageLock.descriptor)

        // 邮箱前缀已经是最长的名字、又被别人占着时，把前面截短再加后缀。
        let long = String(repeating: "a", count: 64)
        let crowded = try Fixture(blob: alice)
        defer { crowded.cleanup() }
        XCTAssertEqual(crowded.run(["save", long]).code, 0)
        crowded.keychain.blob = makeBlob(email: long + "@example.com", refresh: "l")
        XCTAssertEqual(Set(crowded.board.load().rows.map(\.name)), [long, String(repeating: "a", count: 62) + "-2"])
    }

    // 带着 --force 删掉当前登录唯一的一份副本之后，不会又被自动存回来；重新保存或者换了登录之后恢复。
    func testAForcedRemovalIsNotUndoneByTheNextList() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        XCTAssertEqual(fixture.run(["rm", "alice", "--force"]).code, 0)
        XCTAssertEqual(fixture.run(["list"]).output, ["还没有保存的账号。先在 agy 里登录，再执行 agy-cs save <名字>。"])
        XCTAssertEqual(fixture.board.load().rows, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("alice").path))
        XCTAssertEqual(fixture.refresher.started, 0)

        // 开始新增账号又没登录成：原来的登录写回钥匙串，删掉的副本不会回来。
        // 登录期间它在账号名单之外留着一份；没登录成就写回钥匙串，那一份删掉，删掉的副本不会回来。
        fixture.terminal.isInteractive = true
        var kept: String?
        fixture.launcher.supply = {
            kept = try? String(contentsOf: fixture.locations.rollbackURL, encoding: .utf8)
        }
        XCTAssertEqual(fixture.run(["switch", "add"]).code, 1)
        XCTAssertEqual(kept.map(stripNewlines), makeBlob(email: "alice@example.com", refresh: "a"))
        XCTAssertFalse(fixture.keychain.missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.rollbackURL.path))
        XCTAssertEqual(fixture.board.load().rows, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.tokenURL("alice").path))

        // 进程在登录中途没了：钥匙串空着，那一份还在。下一条指令把它写回钥匙串。
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        try Data((alice + "\n").utf8).write(to: fixture.locations.rollbackURL)
        fixture.keychain.missing = true
        XCTAssertEqual(fixture.run(["current"]).output, ["alice@example.com"])
        XCTAssertEqual(fixture.keychain.writes, [alice, alice])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.rollbackURL.path))
        XCTAssertEqual(fixture.board.load().rows, [])

        // 名字相同、邮箱不同的新登录照样能存；存好之后那一份删掉，原来的登录不留。
        fixture.launcher.supply = { fixture.keychain.blob = makeBlob(email: "alice@work.example", refresh: "w"); fixture.keychain.missing = false }
        XCTAssertEqual(fixture.run(["switch", "add"]).code, 0)
        XCTAssertEqual(fixture.run(["list"]).output, ["* alice  alice@work.example"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.rollbackURL.path))
        XCTAssertEqual(fixture.run(["rm", "alice", "--force"]).code, 0)
        fixture.launcher.supply = nil
        fixture.keychain.blob = alice

        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["list"]).output, ["* bob  bob@example.com"])
        fixture.keychain.blob = makeBlob(email: "alice@example.com", refresh: "a")
        XCTAssertEqual(fixture.run(["list"]).output, ["* alice  alice@example.com", "  bob  bob@example.com"])
    }

    // 同一时间只有一个进程改账号。锁被占着时，改动的指令等不到就报忙、什么都不改；看一眼的指令照常，只是不自动保存。
    func testOnlyOneProcessChangesTheAccountsAtATime() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        fixture.stateWait = 0.1
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)

        let held = open(fixture.tool.stateLockFile.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        let board = fixture.board
        for command in [
            ["switch", "--", "alice"], ["next"], ["save", "other"], ["rm", "alice"], ["rename", "alice", "anna"],
            ["move", "bob", "1"],
        ] {
            let outcome = board.perform(command)
            XCTAssertEqual(outcome.code, 1, command.joined(separator: " "))
            XCTAssertEqual(outcome.errors, ["另一个 agy-cs 正在改账号（可能是新增账号还没完成）。稍后再试。"])
        }
        XCTAssertEqual(fixture.keychain.writes, [])
        fixture.keychain.blob = makeBlob(email: "carol@example.com", refresh: "c")
        let watching = board.load()
        XCTAssertEqual(watching.rows.map(\.name), ["alice", "bob"])
        XCTAssertEqual(watching.rows.map(\.isCurrent), [false, false])
        XCTAssertEqual(watching.notices, [])
        XCTAssertEqual(board.perform(["current"]).output, ["carol@example.com"])
        close(held)

        XCTAssertEqual(board.load().rows.map(\.name), ["alice", "bob", "carol"])
        XCTAssertTrue(board.perform(["switch", "--", "alice"]).succeeded)
        XCTAssertEqual(fixture.keychain.writes, [alice])
        XCTAssertNotEqual(fcntl(try XCTUnwrap(fixture.board.services.profile.lockState(wait: 0)), F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertEqual(try mode(fixture.tool.stateLockFile), 0o600)
    }

    // 新增账号从移开钥匙串到新登录存好一直拿着锁：登录期间面板的重读不会抢先把新登录存掉，别的切换也进不来。
    func testAddingAnAccountHoldsTheLockUntilTheNewLoginIsStored() throws {
        let alice = makeBlob(email: "alice@example.com", refresh: "a")
        let carol = makeBlob(email: "carol@example.com", refresh: "c")
        let fixture = try Fixture(blob: alice)
        defer { fixture.cleanup() }
        fixture.stateWait = 0.1
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.terminal.isInteractive = true
        var during: (rows: [String], notices: [String], switching: Int32)?
        fixture.launcher.supply = {
            let empty = fixture.board.load()
            fixture.keychain.blob = carol
            fixture.keychain.missing = false
            let seen = fixture.board.load()
            during = (seen.rows.map(\.name), empty.notices, fixture.board.perform(["switch", "--", "alice"]).code)
        }
        XCTAssertEqual(fixture.run(["switch", "add"]).code, 0)
        XCTAssertEqual(during?.rows, ["alice"])
        XCTAssertEqual(during?.notices, ["现在没有登录。在 agy 里登录之后会自动保存。"])
        XCTAssertEqual(during?.switching, 1)
        XCTAssertEqual(fixture.run(["list"]).output, ["  alice  alice@example.com", "* carol  carol@example.com"])
        XCTAssertEqual(fixture.launcher.started, 1)
        // 重新启动 agy 之前锁已经放开。
        XCTAssertTrue(fixture.board.perform(["switch", "--", "alice"]).succeeded)
    }

    // 同一时间只能有一个菜单栏工具拿到锁；前一个放开之后，下一个才拿得到。
    func testOnlyOneMenuBarToolHoldsTheLock() throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        let first = try XCTUnwrap(fixture.board.lockApp())
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertNotEqual(fcntl(first, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNil(fixture.board.lockApp())
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.tool.appLockFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        close(first)
        let second = try XCTUnwrap(fixture.board.lockApp())
        XCTAssertGreaterThanOrEqual(second, 0)
        close(second)
    }

    // 图标的右键菜单只有退出这一项，用的是当前语言；右键和 control 加左键打开它，左键仍然开关面板。
    @MainActor
    func testStatusItemMenuOnlyQuitsAndOpensOnSecondaryClick() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        XCTAssertEqual(fixture.run(["language", "en"]).code, 0)
        _ = NSApplication.shared
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        var exits = 0
        let controller = MenuBarController { shown in
            PanelModel(
                board: fixture.board, executable: "/somewhere/agy-cs", rereadEvery: 0.05, shown: shown,
                open: { _ in true }, exit: { exits += 1 }
            )
        }
        let menu = controller.makeMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Quit"])
        XCTAssertTrue(menu.items[0].target === controller)
        XCTAssertNotNil(menu.items[0].action)

        let icon = MenuBarController.makeStatusIcon()
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(icon.accessibilityDescription, "Agy Switcher")
        let iconRep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        iconRep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: iconRep)
        let cgIcon = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil))
        NSGraphicsContext.current?.cgContext.draw(cgIcon, in: CGRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        let pixelBytes = try XCTUnwrap(iconRep.bitmapData)
        var transparent = 0
        var drawn = 0
        for index in stride(from: 3, to: 36 * 36 * 4, by: 4) {
            if pixelBytes[index] == 0 {
                transparent += 1
            } else {
                drawn += 1
            }
        }
        XCTAssertGreaterThan(transparent, 0)
        XCTAssertGreaterThan(drawn, 0)

        XCTAssertTrue(MenuBarController.opensMenu(.rightMouseUp, modifiers: []))
        XCTAssertTrue(MenuBarController.opensMenu(.leftMouseUp, modifiers: [.control]))
        XCTAssertFalse(MenuBarController.opensMenu(.leftMouseUp, modifiers: []))
        XCTAssertFalse(MenuBarController.opensMenu(.leftMouseUp, modifiers: [.command]))

        // 切换到一半时点退出：等切换做完再退，当前账号已经记成新的。
        let model = controller.model
        let quit = menu.items[0]
        let alice = try XCTUnwrap(model.state.rows.first { $0.name == "alice" })
        model.switchTo(alice)
        XCTAssertNotNil(model.busy)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quit.action), to: quit.target, from: quit))
        XCTAssertEqual(exits, 0)
        await settle(model)
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(model.state.rows.filter(\.isCurrent).map(\.name), ["alice"])

        // 没有事情在做时马上退出。
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quit.action), to: quit.target, from: quit))
        XCTAssertEqual(exits, 2)
    }

    // 面板的大小跟着内容走：多出几行提示时变高，提示没了、面板关着的时候也要变回去，
    // 不然再打开时内容上下各空出一条。
    @MainActor
    func testPopoverFollowsTheContentAndTellsThePanelWhenItOpensAndCloses() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alice"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "bob@example.com", refresh: "b")
        XCTAssertEqual(fixture.run(["save", "bob"]).code, 0)
        _ = NSApplication.shared
        var asked = 0
        let controller = MenuBarController { shown in
            PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", rereadEvery: 0.05, shown: {
                asked += 1
                return shown()
            }, open: { _ in true })
        }
        let model = controller.model
        let host = try XCTUnwrap(controller.popover.contentViewController)
        XCTAssertNil(controller.item)
        XCTAssertFalse(controller.popover.isShown)

        // 面板还没点开过：内容放进一个不显示的窗口里量。
        let window = NSWindow(contentViewController: host)
        defer { window.close() }
        func height() async -> CGFloat {
            for _ in 0 ..< 20 {
                host.view.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return host.preferredContentSize.height
        }
        let plain = await height()
        XCTAssertEqual(host.preferredContentSize.width, 420)
        XCTAssertGreaterThan(plain, 80)

        model.switchTo(model.state.rows[0])
        await settle(model)
        XCTAssertEqual(model.lines.count, 2)
        let taller = await height()
        XCTAssertGreaterThan(taller, plain + 20)

        model.ask(.rename(model.state.rows[0]))
        let tallest = await height()
        XCTAssertGreaterThan(tallest, taller + 20)

        controller.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(asked, 0)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.lines, [])
        let back = await height()
        XCTAssertEqual(back, plain)

        model.ask(.save)
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertNil(model.prompt)
        let closed = await height()
        XCTAssertEqual(closed, plain)
    }

    // 把真的鼠标事件送进面板：点一行是切换，按住往下拖是排序。改了行上的手势之后跑一遍：
    //   AGY_PANEL_GESTURES=1 swift test --disable-sandbox --filter testPanelGesturesWhenEnabled
    @MainActor
    func testPanelGesturesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGY_PANEL_GESTURES"] == "1" else {
            return
        }
        let fixture = try Fixture(blob: makeBlob(email: "alice@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        for name in ["alice", "bob", "carol"] {
            fixture.keychain.blob = makeBlob(email: "\(name)@example.com", refresh: name)
            XCTAssertEqual(fixture.run(["save", name]).code, 0)
        }
        _ = NSApplication.shared
        let model = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        let host = NSHostingView(rootView: PanelView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func pause(_ seconds: Double = 0.15) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        await pause(0.4)
        // 三行一样高，从面板顶上往下排。面板的高度会随提示变，所以每次送事件之前重新量。
        let rowHeight = (host.fittingSize.height - 45) / 3
        var number = 0
        func send(_ kind: NSEvent.EventType, row: Int, down: CGFloat = 0) {
            host.layoutSubtreeIfNeeded()
            if window.contentLayoutRect.height != host.fittingSize.height {
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
            }
            number += 1
            let point = NSPoint(x: 150, y: host.bounds.height - (CGFloat(row) + 0.5) * rowHeight - down)
            let event = NSEvent.mouseEvent(
                with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1
            )
            window.sendEvent(try! XCTUnwrap(event))
        }

        // 点第一行：切换过去。
        send(.leftMouseDown, row: 0)
        await pause()
        send(.leftMouseUp, row: 0)
        await pause()
        await settle(model)
        XCTAssertEqual(model.messages.first, "已切换到 alice  alice@example.com")
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bob", "carol"])

        // 按住第一行往下拖过第二行：排到第二位，不切换。
        let writes = fixture.keychain.writes
        send(.leftMouseDown, row: 0)
        await pause()
        for step in stride(from: CGFloat(8), through: rowHeight, by: 8) {
            send(.leftMouseDragged, row: 0, down: step)
            await pause(0.03)
        }
        send(.leftMouseUp, row: 0, down: rowHeight)
        await pause()
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["bob", "alice", "carol"])
        XCTAssertEqual(fixture.keychain.writes, writes)
        XCTAssertEqual(fixture.run(["list"]).output.map { cells($0)[0] }, ["bob", "* alice", "carol"])

        // 把最后一行一直拖到顶上之外：排到第一位。
        send(.leftMouseDown, row: 2)
        await pause()
        for step in stride(from: CGFloat(8), through: rowHeight * 4, by: 8) {
            send(.leftMouseDragged, row: 2, down: -step)
            await pause(0.02)
        }
        send(.leftMouseUp, row: 2, down: -rowHeight * 4)
        await pause()
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["carol", "bob", "alice"])

        // 最后一次拖动还没过下一行的中线，松手的位置过了：按松手的位置算。
        send(.leftMouseDown, row: 0)
        await pause()
        send(.leftMouseDragged, row: 0, down: 8)
        await pause(0.03)
        send(.leftMouseUp, row: 0, down: rowHeight * 0.8)
        await pause()
        await settle(model)
        XCTAssertEqual(model.state.rows.map(\.name), ["bob", "carol", "alice"])
    }

    // 把面板画成图片，用来在改界面之后看一眼：
    //   AGY_PANEL_SNAPSHOT=/tmp/agy-panel swift test --disable-sandbox --filter testPanelPicturesWhenEnabled
    @MainActor
    func testPanelPicturesWhenEnabled() async throws {
        guard let folder = ProcessInfo.processInfo.environment["AGY_PANEL_SNAPSHOT"], !folder.isEmpty else {
            return
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try Fixture(blob: makeBlob(email: "alysechen@example.com", refresh: "a"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "alysechen"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "mltnchristen.longer.address@example.com", refresh: "m")
        XCTAssertEqual(fixture.run(["save", "mltnchristen"]).code, 0)
        fixture.keychain.blob = makeBlob(email: "chenmo449@example.com", refresh: "c")
        XCTAssertEqual(fixture.run(["save", "chenmo449"]).code, 0)
        fixture.usage.snapshots = [
            "alysechen": UsageSnapshot(planID: "g1-pro-tier", planName: "", buckets: [
                UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-01-01T03:35:00Z"),
                UsageBucket(id: "gemini-weekly", remaining: 0.99, resetTime: "2026-01-07T10:23:00Z"),
                UsageBucket(id: "gemini-argon-wtu-weekly", remaining: 0.45, resetTime: "2026-01-07T10:23:00Z"),
            ], argonLocked: false),
            "chenmo449": UsageSnapshot(planID: "free-tier", planName: "", buckets: [
                UsageBucket(id: "gemini-weekly", remaining: 0.9962848, resetTime: "2026-01-07T10:23:00Z"),
            ], argonLocked: true),
            "mltnchristen": UsageSnapshot(planID: "g1-pro-tier", planName: "", buckets: [
                UsageBucket(id: "gemini-5h", remaining: 1, resetTime: "2026-01-01T05:00:00Z"),
                UsageBucket(id: "gemini-weekly", remaining: 1, resetTime: "2026-01-08T00:00:00Z"),
            ], argonLocked: true),
        ]
        XCTAssertEqual(fixture.run(["refresh", "quota"]).code, 0)

        let model = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        try picture(PanelView(model: model), to: output.appendingPathComponent("1-accounts.png"))
        model.switchTo(model.state.rows[0])
        await settle(model)
        try picture(PanelView(model: model), to: output.appendingPathComponent("2-switched.png"))
        model.ask(.rename(model.state.rows[2]))
        try picture(PanelView(model: model), to: output.appendingPathComponent("3-rename.png"))
        model.ask(.remove(model.state.rows[2]))
        try picture(PanelView(model: model), to: output.appendingPathComponent("4-remove.png"))
        model.ask(.save)
        model.draft = "add"
        model.confirm()
        await settle(model)
        try picture(PanelView(model: model), to: output.appendingPathComponent("5-refused.png"))
        model.ask(.save)
        model.draft = "chenmo449"
        model.confirm()
        await settle(model)
        try picture(PanelView(model: model), to: output.appendingPathComponent("6-replace.png"))
        model.cancel()
        model.setLanguage("en")
        await settle(model)
        try picture(PanelView(model: model), to: output.appendingPathComponent("7-english.png"))
        // 按住第一行往下拖了 60 个点：它浮在上面，第二行让到它原来的位置。
        let rowFrames = [0, 51, 102].map { CGRect(x: 0, y: CGFloat($0), width: 420, height: 51) }
        try picture(
            PanelView(model: model, dragging: RowDrag(index: 0, frames: rowFrames, translation: 60)),
            to: output.appendingPathComponent("10-dragging.png")
        )
        XCTAssertEqual(fixture.run(["save", "second-name"]).code, 0)
        try picture(
            PanelView(model: PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })),
            to: output.appendingPathComponent("9-same-login-twice.png")
        )
        let jaModel = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        jaModel.setLanguage("ja")
        await settle(jaModel)
        try picture(PanelView(model: jaModel), to: output.appendingPathComponent("14-agy-ja.png"))

        let empty = try Fixture(blob: makeBlob(email: "nobody@example.com"))
        defer { empty.cleanup() }
        empty.keychain.missing = true
        try picture(
            PanelView(model: PanelModel(board: empty.board, executable: "/somewhere/agy-cs", open: { _ in true })),
            to: output.appendingPathComponent("8-empty.png")
        )

        let colabFixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "z"))
        defer { colabFixture.cleanup() }
        let colabKeychain = MemoryKeychain(makeColabBlob(refresh: "colab-r1"))
        let colabUsage = ScriptedUsage()
        colabFixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["colab-r1": "researcher@example.com", "colab-r2": "lab.long.account.name@example.com"])),
            launcher: ScriptedLauncher(),
            usage: colabUsage,
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(colabFixture.run(["colab", "save", "researcher"]).code, 0)
        colabKeychain.blob = makeColabBlob(refresh: "colab-r2")
        XCTAssertEqual(colabFixture.run(["colab", "save", "lab"]).code, 0)
        colabUsage.snapshots = [
            "researcher": UsageSnapshot(planID: "", planName: "", buckets: [], colab: ColabUsageData(balance: 87.5, rateHourly: 1.96, activeAssignments: 1)),
            "lab": UsageSnapshot(planID: "", planName: "", buckets: [], colab: ColabUsageData(balance: 0, rateHourly: 0, activeAssignments: 0)),
        ]
        XCTAssertEqual(colabFixture.run(["colab", "refresh", "quota"]).code, 0)
        try colabFixture.board.setSelectedProvider(.colab)
        let colabModel = PanelModel(board: colabFixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        try picture(PanelView(model: colabModel), to: output.appendingPathComponent("11-colab-zh.png"))
        colabModel.setLanguage("en")
        await settle(colabModel)
        try picture(PanelView(model: colabModel), to: output.appendingPathComponent("12-colab-en.png"))
        colabModel.setLanguage("ja")
        await settle(colabModel)
        try picture(PanelView(model: colabModel), to: output.appendingPathComponent("13-colab-ja.png"))
        colabModel.setLanguage("zh-Hans")
        await settle(colabModel)
        colabModel.ask(.colabWaiting)
        try picture(PanelView(model: colabModel), to: output.appendingPathComponent("15-colab-waiting.png"))
        colabModel.cancel()
        colabModel.ask(.colabCode)
        try picture(PanelView(model: colabModel), to: output.appendingPathComponent("16-colab-code.png"))
    }

    @MainActor
    func testPanelProviderTogglePersistsAndIsolatesProviders() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "a1"))
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.run(["save", "agy1"]).code, 0)

        let colabKeychain = MemoryKeychain(makeColabBlob(refresh: "colab-1"))
        let colabUsage = ScriptedUsage()
        colabUsage.snapshots = [
            "col1": UsageSnapshot(planID: "", planName: "", buckets: [], colab: ColabUsageData(balance: 42.25, rateHourly: 1.25, activeAssignments: 2)),
        ]
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["colab-1": "col1@example.com", "colab-2": "col2@example.com"])),
            launcher: ScriptedLauncher(),
            usage: colabUsage,
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "col1"]).code, 0)
        XCTAssertEqual(fixture.run(["colab", "refresh", "quota"]).code, 0)

        let model = PanelModel(board: fixture.board, executable: "/path with spaces/agy-cs", open: { _ in true })
        XCTAssertEqual(model.provider, .antigravity)
        XCTAssertEqual(model.state.rows.map(\.name), ["agy1"])

        model.toggleProvider()
        await settle(model)
        XCTAssertEqual(model.provider, .colab)
        XCTAssertEqual(fixture.board.selectedProvider(), .colab)
        XCTAssertEqual(model.state.rows.map(\.name), ["col1"])
        XCTAssertEqual(model.state.rows.first?.usage?.colabBalance, "42.25 CU")
        XCTAssertEqual(model.state.rows.first?.usage?.colabActiveCount, 2)

        let cmdURL = try fixture.board.writeAddAccountCommand(executable: "/path with 'quote'/agy-cs", provider: .colab)
        let script = try String(contentsOf: cmdURL, encoding: .utf8)
        XCTAssertEqual(script, "#!/bin/sh\nexec '/path with '\\''quote'\\''/agy-cs' colab switch add\n")

        // New PanelModel restores persisted provider selection.
        let reloaded = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", open: { _ in true })
        XCTAssertEqual(reloaded.provider, .colab)
        XCTAssertEqual(reloaded.state.rows.map(\.name), ["col1"])
        reloaded.toggleProvider()
        await settle(reloaded)
        XCTAssertEqual(reloaded.provider, .antigravity)
        XCTAssertEqual(reloaded.state.rows.map(\.name), ["agy1"])
    }

    @MainActor
    func testPanelColabLoginStaysInThePanel() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "a1"))
        defer { fixture.cleanup() }
        let colabKeychain = MemoryKeychain(makeColabBlob(refresh: "colab-1"))
        fixture.colab = ProviderServices(
            keychain: colabKeychain,
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["colab-1": "researcher@example.com"])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "researcher"]).code, 0)
        try fixture.board.setSelectedProvider(.colab)

        let runner = ScriptedPanelLogin()
        let clip = ClipboardSample()
        var exited = false
        let model = PanelModel(
            board: fixture.board,
            executable: "/somewhere/agy-cs",
            open: { _ in
                XCTFail("Colab add must not open a terminal script")
                return false
            },
            exit: { exited = true },
            loginRunner: runner,
            pasteboard: { (clip.changeCount, clip.string) }
        )
        XCTAssertEqual(model.state.rows.map(\.name), ["researcher"])
        model.addAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tool.addCommandFile.path))
        XCTAssertEqual(runner.arguments, ["colab", "switch", "add", "--handoff"])
        XCTAssertEqual(runner.executable, "/somewhere/agy-cs")
        XCTAssertEqual(model.prompt, .colabWaiting)
        XCTAssertTrue(model.loggingIn)
        XCTAssertTrue(model.isWorking)
        model.toggleProvider()
        XCTAssertEqual(model.provider, .colab)

        model.confirm()
        XCTAssertEqual(runner.channel.sent, ["fallback"])
        runner.emit("\(colabLoginLinePrefix) retry colabLoginCodeRejected")
        XCTAssertEqual(model.prompt, .colabWaiting)
        XCTAssertEqual(model.messages, [model.text(.colabLoginCodeRejected)])
        XCTAssertTrue(model.loggingIn)

        let copied = "4/" + String(repeating: "a", count: 24)
        clip.string = copied
        clip.changeCount += 1
        model.pollClipboard()
        XCTAssertEqual(runner.channel.sent, ["fallback"])

        runner.emit("\(colabLoginLinePrefix) need-code")
        XCTAssertEqual(model.prompt, .colabCode)
        clip.string = String(repeating: "b", count: 30)
        clip.changeCount += 1
        model.pollClipboard()
        XCTAssertEqual(runner.channel.sent, ["fallback"])
        clip.string = copied
        clip.changeCount += 1
        model.pollClipboard()
        XCTAssertEqual(runner.channel.sent, ["fallback", copied])

        model.draft = "short"
        model.confirm()
        XCTAssertEqual(runner.channel.sent, ["fallback", copied])
        XCTAssertEqual(model.messages, [model.text(.colabLoginCodeRejected)])

        let typed = String(repeating: "c", count: 30)
        model.draft = typed
        model.confirm()
        XCTAssertEqual(runner.channel.sent, ["fallback", copied, typed])

        XCTAssertEqual(fixture.run(["colab", "rename", "researcher", "renamed"]).code, 0)
        XCTAssertEqual(model.state.rows.map(\.name), ["researcher"])
        runner.emit("\(colabLoginLinePrefix) saved renamed researcher@example.com")
        XCTAssertTrue(model.messages.contains { $0.contains("renamed") && $0.contains("researcher@example.com") })
        XCTAssertNil(model.prompt)
        runner.emitError("原账号仍有运行中的会话")
        XCTAssertTrue(model.messages.contains("原账号仍有运行中的会话"))
        XCTAssertFalse(model.messages.joined(separator: "\n").contains(copied))
        for _ in 0 ..< 100 where model.state.rows.map(\.name) != ["renamed"] {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.state.rows.map(\.name), ["renamed"])
        runner.finish()
        XCTAssertFalse(model.loggingIn)
        XCTAssertNil(model.prompt)

        model.addAccount()
        runner.emitError("stderr-must-stay-hidden")
        runner.emit("\(colabLoginLinePrefix) error colabBrowserFailed")
        XCTAssertEqual(model.messages, [model.text(.colabBrowserFailed)])
        XCTAssertFalse(model.messages.joined(separator: "\n").contains("stderr-must-stay-hidden"))
        XCTAssertNil(model.prompt)
        XCTAssertTrue(model.loggingIn)
        runner.finish()
        XCTAssertFalse(model.loggingIn)
        XCTAssertEqual(model.messages, [model.text(.colabBrowserFailed)])

        model.addAccount()
        model.cancel()
        XCTAssertEqual(runner.channel.sent.last, "cancel")
        XCTAssertEqual(model.prompt, .colabWaiting)
        model.quit()
        XCTAssertEqual(runner.channel.sent.last, "cancel")
        XCTAssertFalse(exited)
        runner.finish()
        XCTAssertTrue(exited)
        XCTAssertFalse(model.loggingIn)
    }

    @MainActor
    func testPanelQuitKillsAWaitingLoginAndWaitsOnceItIsCommitting() async throws {
        let fixture = try Fixture(blob: makeBlob(email: "agy@example.com", refresh: "a1"))
        defer { fixture.cleanup() }
        fixture.colab = ProviderServices(
            keychain: MemoryKeychain(makeColabBlob(refresh: "colab-1")),
            codec: ColabLoginCodec(emailResolver: StaticColabEmailResolver(["colab-1": "researcher@example.com"])),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        XCTAssertEqual(fixture.run(["colab", "save", "researcher"]).code, 0)
        try fixture.board.setSelectedProvider(.colab)
        let runner = ScriptedPanelLogin()
        var exited = false
        let model = PanelModel(
            board: fixture.board,
            executable: "/somewhere/agy-cs",
            open: { _ in false },
            exit: { exited = true },
            loginRunner: runner,
            pasteboard: { (0, nil) }
        )
        model.addAccount()
        model.quit()
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertEqual(runner.channel.sent.last, "cancel")
        XCTAssertTrue(runner.channel.stopped)
        XCTAssertTrue(exited)
        runner.finish()
        XCTAssertFalse(model.loggingIn)

        exited = false
        model.addAccount()
        runner.emit("\(colabLoginLinePrefix) committing")
        model.quit()
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertEqual(runner.channel.sent.last, "cancel")
        XCTAssertFalse(runner.channel.stopped)
        XCTAssertFalse(exited)
        runner.finish()
        XCTAssertTrue(exited)
    }
}

private final class ScriptedPanelLogin: PanelLoginRunning {
    let channel = ScriptedLoginChannel()
    private(set) var arguments: [String] = []
    private(set) var executable = ""
    private var onLine: (@MainActor (String) -> Void)?
    private var onError: (@MainActor (String) -> Void)?
    private var onExit: (@MainActor () -> Void)?

    func launch(
        executable: String,
        arguments: [String],
        onLine: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor () -> Void
    ) -> any PanelLoginChannel {
        self.executable = executable
        self.arguments = arguments
        self.onLine = onLine
        self.onError = onError
        self.onExit = onExit
        channel.sent = []
        channel.stopped = false
        return channel
    }

    @MainActor
    func emit(_ line: String) {
        onLine?(line)
    }

    @MainActor
    func emitError(_ line: String) {
        onError?(line)
    }

    @MainActor
    func finish() {
        onExit?()
    }
}

private final class ScriptedLoginChannel: PanelLoginChannel {
    var sent: [String] = []
    var stopped = false

    func send(_ line: String) {
        sent.append(line)
    }

    func stop() {
        stopped = true
    }
}

private final class ClipboardSample {
    var changeCount = 1
    var string: String?
}

@MainActor
private func settle(_ model: PanelModel) async {
    for _ in 0 ..< 500 where model.busy != nil {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func picture(_ view: some View, to url: URL) throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let canvas = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: canvas)
    try XCTUnwrap(canvas.representation(using: .png, properties: [:])).write(to: url)
}
