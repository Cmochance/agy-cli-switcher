import Foundation

public enum LaunchMode: Equatable {
    case menuBar
    case commandLine
}

// Packaging/Info.plist 的 LSEnvironment 里设着这个标记。
public let menuBarMarker = "AGY_CS_MENU_BAR"

// 同一个二进制两用。被系统打开（Finder、Dock、open）时没有参数、父进程是 launchd、带着上面的标记（实测）；
// 在终端里运行包里的同一个文件时对不上，照旧是命令行。三样都要对上，少一样就是命令行。
public func launchMode(arguments: [String], environment: [String: String], parent: Int32) -> LaunchMode {
    arguments.isEmpty && parent == 1 && environment[menuBarMarker] == "1" ? .menuBar : .commandLine
}

public struct AccountRow: Equatable, Identifiable {
    public var name: String
    public var email: String
    public var isCurrent: Bool
    public var usage: UsageText?

    public var id: String { name }
}

public struct BoardState {
    public var rows: [AccountRow]
    // 首次运行时初始化说的话，以及后台那次额度查询没查到的账号。
    public var notices: [String]
    public var failed: Bool
    public var text: Localizer
    public var language: String
    public var provider: AccountProvider = .antigravity
    public var blockOldWriteback: Bool = false
    public var statusTelemetry: Bool = false
}

public struct ActionOutcome {
    public var code: Int32
    public var failure: TextKey?
    // 填进 failure 那句话里的名字和邮箱，顺序和句子里的 %1、%2 一样。
    public var details: [String]
    public var output: [String]
    public var errors: [String]

    public var succeeded: Bool { code == 0 }
}

// 菜单栏面板用的入口。每个动作就是一条 agy-cs 指令，在本进程里执行，说的话收集起来交给面板显示。
// 建好之后不再改动，面板只在一个后台队列里按顺序调用它。
public struct AccountBoard: @unchecked Sendable {
    var services: CommandServices

    public static let languages: [(code: String, name: String)] = AppLanguage.allCases.map { ($0.rawValue, $0.nativeName) }

    public init() {
        services = .system(terminal: NoTerminal())
    }

    init(services: CommandServices) {
        self.services = services
    }

    public func selectedProvider() -> AccountProvider {
        services.profile.selectedProvider()
    }

    public func setSelectedProvider(_ provider: AccountProvider) throws {
        try services.profile.setSelectedProvider(provider)
    }

    // 只读 ~/.agy-cs/ 里的记录，不联网。还没初始化过时，和命令行一样读一次钥匙串。
    public func load() -> BoardState {
        load(provider: selectedProvider())
    }

    public func load(provider: AccountProvider) -> BoardState {
        let scoped = services.forProvider(provider)
        let profile = scoped.profile
        let text = Localizer(language: profile.resolvedLanguage())
        let said = Lines()
        let commands = scoped.commands(text: text, stdout: said.add, stderr: said.add)
        func state(_ rows: [AccountRow], failed: Bool) -> BoardState {
            BoardState(
                rows: rows,
                notices: said.all,
                failed: failed,
                text: text,
                language: text.language.rawValue,
                provider: provider,
                blockOldWriteback: provider == .antigravity ? profile.blockOldWritebackEnabled() : false,
                statusTelemetry: provider == .antigravity ? profile.statusTelemetryEnabled() : false
            )
        }
        do {
            try profile.prepare()
            try commands.initializeIfNeeded()
            let rows = try commands.listing()
            if let notice = commands.failedRefreshNotice() {
                said.add(notice)
            }
            return state(rows, failed: false)
        } catch let error as AccountFailure {
            said.add(text.line(providerTextKey(error.key, provider: provider), argumentList: error.arguments))
        } catch {
            said.add(text.line(.operationFailed))
        }
        return state([], failed: true)
    }

    public func perform(_ arguments: [String]) -> ActionOutcome {
        let output = Lines()
        let errors = Lines()
        let result = AgyAccountCLI.execute(arguments, services: services, stdout: output.add, stderr: errors.add)
        return ActionOutcome(
            code: result.code, failure: result.failure, details: result.details, output: output.all, errors: errors.all
        )
    }

    public func loadSessionTelemetry(
        conversationId: String? = nil,
        sourceFilter: TelemetrySourceFilter = .auto,
        pricingMode: PricingMode = .standard,
        knownStamp: String? = nil
    ) -> SessionTelemetryLoadResult {
        let locations = ToolLocations(home: services.home, provider: .antigravity)
        var environment = services.environment
        environment.removeValue(forKey: "ANTIGRAVITY_CONVERSATION_ID")
        return SessionTelemetryEngine.load(
            requestedId: conversationId,
            home: services.home,
            environment: environment,
            sourceFilter: sourceFilter,
            pricingMode: pricingMode,
            pricingFile: locations.pricingFile,
            knownStamp: knownStamp,
            now: services.clock()
        )
    }

    public func loadUsageOverview(
        range: UsageRangePreset = .weekly,
        accountFilter: String? = nil,
        sourceFilter: TelemetrySourceFilter = .all,
        pricingMode: PricingMode = .standard
    ) -> UsageOverviewSnapshot {
        let scoped = services.forProvider(.antigravity)
        return UsageAnalyticsEngine.loadOverview(
            home: services.home,
            profile: scoped.profile,
            environment: services.environment,
            range: range,
            accountFilter: accountFilter,
            sourceFilter: sourceFilter,
            pricingMode: pricingMode,
            now: services.clock()
        )
    }

    public func watchedTelemetryDirectories() -> [URL] {
        var dirs = [ToolLocations(home: services.home).globalRoot]
        for root in AntigravityDataRoots.resolve(home: services.home, environment: services.environment, filter: .all) {
            dirs.append(root.url)
            dirs.append(root.conversationsDirectory)
            dirs.append(root.brainDirectory)
        }
        return dirs
    }

    public func isStatusTelemetryActive() -> Bool {
        selectedProvider() == .antigravity
            && services.forProvider(.antigravity).profile.statusTelemetryEnabled()
    }

    public func loadStatusBarSummary(knownStamp: String? = nil) -> (changed: Bool, stamp: String, badge: String?) {
        guard isStatusTelemetryActive() else {
            return (changed: true, stamp: "", badge: nil)
        }
        let result = loadSessionTelemetry(
            conversationId: nil,
            sourceFilter: .auto,
            pricingMode: .standard,
            knownStamp: knownStamp
        )
        switch result {
        case .unchanged(let stamp):
            return (changed: false, stamp: stamp, badge: nil)
        case .empty:
            return (changed: true, stamp: "", badge: nil)
        case .loaded(let snapshot):
            var parts: [String] = []
            if let pct = snapshot.contextWindow.usedPercent {
                let prefix = snapshot.contextWindow.compactedPending ? "≈" : ""
                parts.append("\(prefix)\(Int(pct.rounded()))%")
            } else if snapshot.contextWindow.usedTokens > 0 {
                parts.append(formatCompactTokens(snapshot.contextWindow.usedTokens))
            }
            if let tps = snapshot.telemetry.latestTps ?? snapshot.telemetry.tps, tps > 0 {
                parts.append("\(formatOneDecimal(tps))t/s")
            }
            let badge = parts.isEmpty ? nil : parts.joined(separator: " · ")
            return (changed: true, stamp: snapshot.stateStamp, badge: badge)
        }
    }

    // agy / colab 的登录界面要一个终端，面板里登录不了。这里写一个两行的 .command 文件，由面板交给系统默认的终端程序打开。
    // 文件里只有本程序自己的路径和固定的 switch add（或 colab switch add），登录和回滚仍是命令行那一套。
    public func writeAddAccountCommand(executable: String, provider: AccountProvider = .antigravity) throws -> URL {
        let url = ToolLocations(home: services.home).addCommandFile
        try AtomicFile.write(url, addAccountScript(executable: executable, provider: provider))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
        return url
    }

    public func addAccountCommandLine(executable: String, provider: AccountProvider = .antigravity) -> String {
        shellQuoted(executable) + " " + (provider.cliPrefix + ["switch", "add"]).joined(separator: " ")
    }

    // 同一时间只让一个菜单栏工具运行：几份 app 用的是同一份记录和同一条钥匙串项。
    // 返回 nil 表示已经有一个在运行。拿到的描述符一直开着，进程结束时锁自动释放；
    // 带 O_CLOEXEC，不传给之后启动的进程，不然退出之后查额度的进程还占着锁。
    // 锁文件打不开时返回 -1，不拦着启动。
    public func lockApp() -> Int32? {
        let locations = ToolLocations(home: services.home)
        try? FileManager.default.createDirectory(
            at: locations.root, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let descriptor = open(locations.appLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return -1
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                return errno == EWOULDBLOCK ? nil : -1
            }
        }
        return descriptor
    }
}

func addAccountScript(executable: String, provider: AccountProvider = .antigravity) -> String {
    let command = (provider.cliPrefix + ["switch", "add"]).joined(separator: " ")
    return "#!/bin/sh\nexec \(shellQuoted(executable)) \(command)\n"
}

// 单引号里只有单引号自己需要处理，空格、$ 和换行都按原样。
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// 面板进程里没有终端。不带名字的 switch 和 switch add 在这里会按“需要终端”报错，不会去动钥匙串。
// Colab 登录不走这条路：面板另起子进程做浏览器登录。
struct NoTerminal: LineReading {
    var isInteractive: Bool { false }

    func readLine() -> String? {
        nil
    }
}

private final class Lines {
    private(set) var all: [String] = []

    func add(_ line: String) {
        all.append(line)
    }
}
