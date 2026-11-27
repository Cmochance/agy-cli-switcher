import Darwin
import Foundation

struct ProviderServices {
    var keychain: any KeychainStoring
    var codec: any LoginDecoding
    var launcher: any AgyLaunching
    var usage: any UsageFetching
    var refresher: any QuotaRefreshStarting
    var signer: (any ColabSigning)? = nil
}

// 一条指令要用到的外部东西。命令行和菜单栏面板各自配一份，指令本身是同一套。
struct CommandServices {
    var home: URL
    var keychain: any KeychainStoring
    var processes: any ProcessListing
    var now: () -> String
    var preferredLanguages: [String]
    var terminal: any LineReading
    var launcher: any AgyLaunching
    var usage: any UsageFetching
    var refresher: any QuotaRefreshStarting
    var guarder: any GuardStarting
    var stateWait: TimeInterval = 5
    var provider: AccountProvider = .antigravity
    var colab: ProviderServices? = nil
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var clock: () -> Date = Date.init

    static func system(terminal: any LineReading, provider: AccountProvider = .antigravity) -> CommandServices {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let processes = SystemProcessList()
        let keychain = LoginKeychainStore()
        let guarder = GuardSpawner(
            home: home,
            keychain: keychain,
            processes: processes,
            now: AccountClock.utcTimestamp
        )
        switch provider {
        case .antigravity:
            return CommandServices(
                home: home,
                keychain: keychain,
                processes: processes,
                now: AccountClock.utcTimestamp,
                preferredLanguages: Locale.preferredLanguages,
                terminal: terminal,
                launcher: InteractiveAgy(),
                usage: CloudCodeUsage(client: AgyClient(cacheURL: ToolLocations(home: home).clientFile)),
                refresher: SelfSpawner(),
                guarder: guarder,
                provider: .antigravity
            )
        case .colab:
            let colabClient = ToolLocations(home: home, provider: .colab).clientFile
            return CommandServices(
                home: home,
                keychain: ColabKeychainStore(cacheURL: colabClient),
                processes: processes,
                now: AccountClock.utcTimestamp,
                preferredLanguages: Locale.preferredLanguages,
                terminal: terminal,
                launcher: InteractiveColab(cacheURL: colabClient),
                usage: ColabUsageFetcher(),
                refresher: SelfSpawner(prefix: ["colab"]),
                guarder: guarder,
                provider: .colab
            )
        }
    }

    var profile: ToolProfile {
        ToolProfile(home: home, now: now, preferredLanguages: preferredLanguages, provider: provider)
    }

    func forProvider(_ target: AccountProvider) -> CommandServices {
        if target == provider {
            return self
        }
        switch target {
        case .antigravity:
            var copy = self
            copy.provider = .antigravity
            return copy
        case .colab:
            let colabClient = ToolLocations(home: home, provider: .colab).clientFile
            let overrides = colab ?? ProviderServices(
                keychain: ColabKeychainStore(cacheURL: colabClient),
                codec: ColabLoginCodec(),
                launcher: InteractiveColab(cacheURL: colabClient),
                usage: ColabUsageFetcher(),
                refresher: SelfSpawner(prefix: ["colab"])
            )
            return CommandServices(
                home: home,
                keychain: overrides.keychain,
                processes: processes,
                now: now,
                preferredLanguages: preferredLanguages,
                terminal: terminal,
                launcher: overrides.launcher,
                usage: overrides.usage,
                refresher: overrides.refresher,
                guarder: guarder,
                stateWait: stateWait,
                provider: .colab,
                colab: overrides,
                environment: environment,
                clock: clock
            )
        }
    }

    func commands(
        text: Localizer,
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void
    ) -> AccountCommands {
        let locations = AccountLocations(home: home, provider: provider)
        let activeCodec: any LoginDecoding = provider == .colab
            ? (colab?.codec ?? ColabLoginCodec())
            : AntigravityLoginCodec()
        let files = AccountFiles(locations: locations, now: now, codec: activeCodec)
        let sync: any ProviderStateSyncing = provider == .colab
            ? ColabStateSync(locations: locations)
            : AntigravityStateSync(files: files)
        return AccountCommands(
            files: files,
            profile: profile,
            keychain: keychain,
            processes: processes,
            terminal: terminal,
            launcher: launcher,
            usage: usage,
            refresher: refresher,
            guarder: guarder,
            stateWait: stateWait,
            provider: provider,
            codec: activeCodec,
            stateSync: sync,
            signer: provider == .colab ? colab?.signer : nil,
            environment: environment,
            clock: clock,
            text: text,
            stdout: stdout,
            stderr: stderr
        )
    }
}

// `print` 在管道上是整段缓冲。面板要在子进程还等着的时候读到 `need-code`，所以每一行都立刻送出去。
func writeStdoutLine(_ line: String) {
    print(line)
    fflush(stdout)
}

public enum AgyAccountCLI {
    public static func run(_ arguments: [String]) -> Int32 {
        execute(
            arguments,
            services: .system(terminal: StandardTerminal()),
            stdout: writeStdoutLine,
            stderr: { message in
                fputs(message + "\n", stderr)
            }
        ).code
    }

    static func run(
        _ arguments: [String],
        home: URL,
        keychain: any KeychainStoring,
        processes: any ProcessListing,
        now: @escaping () -> String,
        preferredLanguages: [String] = Locale.preferredLanguages,
        terminal: any LineReading,
        launcher: any AgyLaunching,
        usage: any UsageFetching,
        refresher: any QuotaRefreshStarting,
        guarder: any GuardStarting = NoopGuardStarter(),
        colab: ProviderServices? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping () -> Date = Date.init,
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void
    ) -> Int32 {
        execute(
            arguments,
            services: CommandServices(
                home: home,
                keychain: keychain,
                processes: processes,
                now: now,
                preferredLanguages: preferredLanguages,
                terminal: terminal,
                launcher: launcher,
                usage: usage,
                refresher: refresher,
                guarder: guarder,
                colab: colab,
                environment: environment,
                clock: clock
            ),
            stdout: stdout,
            stderr: stderr
        ).code
    }

    // failure 是没做成时的那句话的键，details 是填进那句话里的名字和邮箱。
    // 面板靠它们分辨“这是唯一的副本”“名字被别人占着”这样要再问一次的情况。
    static func execute(
        _ arguments: [String],
        services: CommandServices,
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void
    ) -> (code: Int32, failure: TextKey?, details: [String]) {
        let route = routeProvider(arguments, defaultProvider: services.provider)
        let scoped = services.forProvider(route.provider)
        let profile = scoped.profile
        let text = Localizer(language: profile.resolvedLanguage())
        let commands = scoped.commands(text: text, stdout: stdout, stderr: stderr)
        do {
            let command = try parse(route.arguments)
            if isTelemetryCommand(command) {
                try commands.run(command)
                return (0, nil, [])
            }
            try profile.prepare()
            try commands.initializeIfNeeded()
            try commands.run(command)
            return (0, nil, [])
        } catch let error as AccountFailure {
            let key = providerTextKey(error.key, provider: scoped.provider)
            stderr(text.line(key, argumentList: error.arguments))
            return (1, error.key, error.arguments)
        } catch let error as UsageFailure {
            let spoken = usageLanguage(commandArguments: route.arguments, profile: profile, fallback: text)
            let key = providerTextKey(error.key, provider: scoped.provider)
            stderr(spoken.line(key, argumentList: error.arguments))
            return (2, error.key, error.arguments)
        } catch {
            stderr(text.line(.operationFailed))
            return (1, .operationFailed, [])
        }
    }
}

private func isTelemetryCommand(_ command: AccountCommandKind) -> Bool {
    switch command {
    case .stats, .session, .statusBarStatus, .statusBarSet:
        return true
    default:
        return false
    }
}

private func routeProvider(
    _ arguments: [String],
    defaultProvider: AccountProvider
) -> (provider: AccountProvider, arguments: [String]) {
    if arguments.first == AccountProvider.colab.rawValue {
        return (.colab, Array(arguments.dropFirst()))
    }
    return (defaultProvider, arguments)
}

func parse(_ arguments: [String]) throws -> AccountCommandKind {
    guard let first = arguments.first else {
        return .list
    }
    switch first {
    case "help", "-h", "--help":
        guard arguments.count == 1 else {
            throw UsageFailure(.helpNoExtra)
        }
        return .help
    case "current":
        try rejectExtra(arguments, command: "current")
        return .current
    case "list", "ls":
        try rejectExtra(arguments, command: first)
        return .list
    case "save":
        return try parseSave(arguments)
    case "switch":
        switch arguments.count {
        case 1:
            return .choose
        case 2 where arguments[1] == reservedName:
            return .add(handoff: false)
        case 3 where arguments[1] == reservedName && arguments[2] == "--handoff":
            return .add(handoff: true)
        case 2:
            return .change(arguments[1])
        // 面板点一行用这种写法。以前留下的、名字正好是 add 的记录也能切过去，不会被当成新增账号。
        case 3 where arguments[1] == "--":
            return .change(arguments[2])
        default:
            throw UsageFailure(.commandNoExtra, "switch")
        }
    case "refresh":
        switch Array(arguments.dropFirst()) {
        case ["quota"]:
            return .refreshQuota
        case ["quota", "--detach"]:
            return .refreshQuotaDetached
        default:
            throw UsageFailure(.refreshNeedsQuota)
        }
    case "use":
        throw UsageFailure(.useRenamed)
    case "rename":
        return try parseRename(arguments)
    case "move":
        guard arguments.count == 3 else {
            throw UsageFailure(.moveNeedsNameAndPosition)
        }
        return .move(arguments[1], to: arguments[2])
    case "next":
        try rejectExtra(arguments, command: "next")
        return .next
    case "rm":
        return try parseRemove(arguments)
    case "guard":
        return try parseGuard(arguments)
    case "stats":
        return try parseStats(arguments)
    case "session":
        return try parseSession(arguments)
    case "statusbar":
        return try parseStatusBar(arguments)
    case "language", "lg":
        return try parseLanguage(arguments)
    default:
        throw UsageFailure(.unknownCommand, first)
    }
}

private func rejectExtra(_ arguments: [String], command: String) throws {
    guard arguments.count == 1 else {
        throw UsageFailure(.commandNoExtra, command)
    }
}

private enum FlagProblem: Error {
    case unknown(String)
    case secondName
}

// save 和 rm 都是一个名字加 --force。--expect 只给面板用，不写进 help，后面跟着面板上这个名字下面显示的邮箱。
// 面板上看到的可能已经过时：指令动手之前核对一次，对不上就不替换、不删除。
private func nameAndFlags(_ arguments: [String]) throws -> (name: String?, force: Bool, expecting: String?) {
    var name: String?
    var force = false
    var expecting: String?
    var rest = arguments.dropFirst()
    while let argument = rest.popFirst() {
        if argument == "--force" {
            force = true
        } else if argument == "--expect", let email = rest.popFirst() {
            expecting = email
        } else if argument.hasPrefix("-") {
            throw FlagProblem.unknown(argument)
        } else if name == nil {
            name = argument
        } else {
            throw FlagProblem.secondName
        }
    }
    return (name, force, expecting)
}

private func parseSave(_ arguments: [String]) throws -> AccountCommandKind {
    guard let parsed = try? nameAndFlags(arguments), let name = parsed.name else {
        throw UsageFailure(.needsName, "save")
    }
    return .save(name, force: parsed.force, expecting: parsed.expecting)
}

private func parseRename(_ arguments: [String]) throws -> AccountCommandKind {
    let rest = Array(arguments.dropFirst())
    switch rest.count {
    case 1:
        return .rename(from: nil, to: rest[0])
    case 2:
        return .rename(from: rest[0], to: rest[1])
    case 0:
        throw UsageFailure(.renameNeedsName)
    default:
        throw UsageFailure(.renameTooMany)
    }
}

private func parseRemove(_ arguments: [String]) throws -> AccountCommandKind {
    do {
        let parsed = try nameAndFlags(arguments)
        guard let name = parsed.name else {
            throw UsageFailure(.rmNeedsName)
        }
        return .remove(name, force: parsed.force, expecting: parsed.expecting)
    } catch FlagProblem.unknown(let argument) {
        throw UsageFailure(.rmUnknownArgument, argument)
    } catch FlagProblem.secondName {
        throw UsageFailure(.rmOnlyOneName)
    }
}

private func parseLanguage(_ arguments: [String]) throws -> AccountCommandKind {
    let rest = Array(arguments.dropFirst())
    if rest.isEmpty {
        return .languageShow
    }
    guard rest.count == 1 else {
        throw UsageFailure(.languageNoExtra)
    }
    return .languageSet(rest[0])
}

private func parseGuard(_ arguments: [String]) throws -> AccountCommandKind {
    switch Array(arguments.dropFirst()) {
    case []:
        return .guardStatus
    case ["on"]:
        return .guardSet(true)
    case ["off"]:
        return .guardSet(false)
    case ["--detach"]:
        return .guardDetach
    case ["--worker"]:
        return .guardWorker
    default:
        throw UsageFailure(.guardUsage)
    }
}

private func parseStats(_ arguments: [String]) throws -> AccountCommandKind {
    var range: UsageRangePreset = .weekly
    var accountFilter: String?
    var sourceFilter: TelemetrySourceFilter = .all
    var pricingMode: PricingMode = .standard
    var jsonOutput = false
    var rest = arguments.dropFirst()
    while let arg = rest.popFirst() {
        switch arg {
        case "--range":
            guard let value = rest.popFirst(), let parsed = UsageRangePreset.parse(value) else {
                throw UsageFailure(.statsUsage)
            }
            range = parsed
        case "--account":
            guard let value = rest.popFirst(), !value.isEmpty else {
                throw UsageFailure(.statsUsage)
            }
            accountFilter = value
        case "--source":
            guard let value = rest.popFirst(),
                  let parsed = TelemetrySourceFilter(rawValue: value.lowercased()),
                  parsed != .auto
            else {
                throw UsageFailure(.statsUsage)
            }
            sourceFilter = parsed
        case "--pricing":
            guard let value = rest.popFirst(), let parsed = PricingMode(rawValue: value.lowercased()) else {
                throw UsageFailure(.statsUsage)
            }
            pricingMode = parsed
        case "--json":
            jsonOutput = true
        default:
            throw UsageFailure(.statsUsage)
        }
    }
    return .stats(range: range, accountFilter: accountFilter, sourceFilter: sourceFilter, pricingMode: pricingMode, jsonOutput: jsonOutput)
}

private func parseSession(_ arguments: [String]) throws -> AccountCommandKind {
    var conversationId: String?
    var sourceFilter: TelemetrySourceFilter = .auto
    var pricingMode: PricingMode = .standard
    var jsonOutput = false
    var rest = arguments.dropFirst()
    while let arg = rest.popFirst() {
        switch arg {
        case "--source":
            guard let value = rest.popFirst(),
                  let parsed = TelemetrySourceFilter(rawValue: value.lowercased()),
                  parsed != .all
            else {
                throw UsageFailure(.sessionUsage)
            }
            sourceFilter = parsed
        case "--pricing":
            guard let value = rest.popFirst(), let parsed = PricingMode(rawValue: value.lowercased()) else {
                throw UsageFailure(.sessionUsage)
            }
            pricingMode = parsed
        case "--json":
            jsonOutput = true
        default:
            if arg.hasPrefix("-") || conversationId != nil {
                throw UsageFailure(.sessionUsage)
            }
            conversationId = arg
        }
    }
    return .session(conversationId: conversationId, sourceFilter: sourceFilter, pricingMode: pricingMode, jsonOutput: jsonOutput)
}

private func parseStatusBar(_ arguments: [String]) throws -> AccountCommandKind {
    switch Array(arguments.dropFirst()) {
    case []:
        return .statusBarStatus
    case ["on"]:
        return .statusBarSet(true)
    case ["off"]:
        return .statusBarSet(false)
    default:
        throw UsageFailure(.statusBarUsage)
    }
}

private func usageLanguage(commandArguments: [String], profile: ToolProfile, fallback: Localizer) -> Localizer {
    guard commandArguments.first == "language" || commandArguments.first == "lg",
          commandArguments.count == 2,
          let selected = AppLanguage.parse(commandArguments[1])
    else {
        return Localizer(language: profile.resolvedLanguage())
    }
    return Localizer(language: selected)
}

extension Localizer {
    public func line(_ key: TextKey, argumentList: [String]) -> String {
        var copy = line(key)
        for index in stride(from: argumentList.count, through: 1, by: -1) {
            copy = copy.replacingOccurrences(of: "%\(index)", with: argumentList[index - 1])
        }
        return copy
    }
}
