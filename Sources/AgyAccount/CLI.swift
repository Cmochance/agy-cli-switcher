import Darwin
import Foundation

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

    static func system(terminal: any LineReading) -> CommandServices {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CommandServices(
            home: home,
            keychain: LoginKeychainStore(),
            processes: SystemProcessList(),
            now: AccountClock.utcTimestamp,
            preferredLanguages: Locale.preferredLanguages,
            terminal: terminal,
            launcher: InteractiveAgy(),
            usage: CloudCodeUsage(client: AgyClient(cacheURL: ToolLocations(home: home).clientFile)),
            refresher: SelfSpawner()
        )
    }

    var profile: ToolProfile {
        ToolProfile(home: home, now: now, preferredLanguages: preferredLanguages)
    }

    func commands(
        text: Localizer,
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void
    ) -> AccountCommands {
        AccountCommands(
            files: AccountFiles(locations: AccountLocations(home: home), now: now),
            profile: profile,
            keychain: keychain,
            processes: processes,
            terminal: terminal,
            launcher: launcher,
            usage: usage,
            refresher: refresher,
            text: text,
            stdout: stdout,
            stderr: stderr
        )
    }
}

public enum AgyAccountCLI {
    public static func run(_ arguments: [String]) -> Int32 {
        execute(
            arguments,
            services: .system(terminal: StandardTerminal()),
            stdout: { print($0) },
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
                refresher: refresher
            ),
            stdout: stdout,
            stderr: stderr
        ).code
    }

    // failure 是没做成时的那句话的键。面板靠它分辨“这是唯一的副本”这样要再问一次的情况。
    static func execute(
        _ arguments: [String],
        services: CommandServices,
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void
    ) -> (code: Int32, failure: TextKey?) {
        let profile = services.profile
        let text = Localizer(language: profile.resolvedLanguage())
        let commands = services.commands(text: text, stdout: stdout, stderr: stderr)
        do {
            try profile.prepare()
            try commands.initializeIfNeeded()
            try commands.run(try parse(arguments))
            return (0, nil)
        } catch let error as AccountFailure {
            stderr(text.line(error.key, argumentList: error.arguments))
            return (1, error.key)
        } catch let error as UsageFailure {
            let spoken = usageLanguage(commandArguments: arguments, profile: profile, fallback: text)
            stderr(spoken.line(error.key, argumentList: error.arguments))
            return (2, error.key)
        } catch {
            stderr(text.line(.operationFailed))
            return (1, .operationFailed)
        }
    }
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
        return .save(try singleName(arguments, command: "save"))
    case "switch":
        switch arguments.count {
        case 1:
            return .choose
        case 2 where arguments[1] == reservedName:
            return .add
        case 2:
            return .change(arguments[1])
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
    case "next":
        try rejectExtra(arguments, command: "next")
        return .next
    case "rm":
        return try parseRemove(arguments)
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

private func singleName(_ arguments: [String], command: String) throws -> String {
    guard arguments.count == 2 else {
        throw UsageFailure(.needsName, command)
    }
    return arguments[1]
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
    var name: String?
    var force = false
    for argument in arguments.dropFirst() {
        if argument == "--force" {
            force = true
        } else if argument.hasPrefix("-") {
            throw UsageFailure(.rmUnknownArgument, argument)
        } else if name == nil {
            name = argument
        } else {
            throw UsageFailure(.rmOnlyOneName)
        }
    }
    guard let name else {
        throw UsageFailure(.rmNeedsName)
    }
    return .remove(name, force: force)
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
