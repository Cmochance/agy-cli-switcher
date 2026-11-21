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
        XCTAssertEqual(fixture.keychain.reads, reads)
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
        XCTAssertEqual(fixture.keychain.reads, 1)
        XCTAssertEqual(fixture.board.load().notices, [])
        XCTAssertEqual(fixture.keychain.reads, 1)
        XCTAssertEqual(fixture.keychain.writes, [])
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

        // 不知道面板在哪个窗口里时不计时：只在打开的那一下读一次。
        let detached = PanelModel(board: fixture.board, executable: "/somewhere/agy-cs", rereadEvery: 0.05, open: { _ in true })
        detached.panelOpened()

        model.panelOpened()
        XCTAssertEqual(fixture.run(["rename", "bob", "bobby"]).code, 0)
        await wait { model.state.rows.map(\.name) == ["alice", "bobby"] }
        XCTAssertEqual(model.state.rows.map(\.name), ["alice", "bobby"])
        XCTAssertEqual(detached.state.rows.map(\.name), ["alice", "bob"])

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
        model.setLanguage("en")
        await settle(model)
        try picture(PanelView(model: model), to: output.appendingPathComponent("6-english.png"))

        let empty = try Fixture(blob: makeBlob(email: "nobody@example.com"))
        defer { empty.cleanup() }
        empty.keychain.missing = true
        try picture(
            PanelView(model: PanelModel(board: empty.board, executable: "/somewhere/agy-cs", open: { _ in true })),
            to: output.appendingPathComponent("7-empty.png")
        )
    }
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
