import Darwin
import Foundation

public enum AgyAccountCLI {
    public static func run(_ arguments: [String]) -> Int32 {
        run(
            arguments,
            home: FileManager.default.homeDirectoryForCurrentUser,
            keychain: LoginKeychainStore(),
            processes: SystemProcessList(),
            now: AccountClock.utcTimestamp,
            preferredLanguages: Locale.preferredLanguages,
            terminal: StandardTerminal(),
            launcher: InteractiveAgy(),
            stdout: { print($0) },
            stderr: { message in
                fputs(message + "\n", stderr)
            }
        )
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
        stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void
    ) -> Int32 {
        let profile = ToolProfile(home: home, now: now, preferredLanguages: preferredLanguages)
        let text = Localizer(language: profile.resolvedLanguage())
        let commands = AccountCommands(
            files: AccountFiles(locations: AccountLocations(home: home), now: now),
            profile: profile,
            keychain: keychain,
            processes: processes,
            terminal: terminal,
            launcher: launcher,
            text: text,
            stdout: stdout,
            stderr: stderr
        )
        do {
            try profile.prepare()
            try commands.initializeIfNeeded()
            try commands.run(try parse(arguments))
            return 0
        } catch let error as AccountFailure {
            stderr(text.line(error.key, argumentList: error.arguments))
            return 1
        } catch let error as UsageFailure {
            let spoken = usageLanguage(commandArguments: arguments, profile: profile, fallback: text)
            stderr(spoken.line(error.key, argumentList: error.arguments))
            return 2
        } catch {
            stderr(text.line(.operationFailed))
            return 1
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
        case 2 where arguments[1] == "add":
            return .add
        case 2:
            return .change(arguments[1])
        default:
            throw UsageFailure(.commandNoExtra, "switch")
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
    func line(_ key: TextKey, argumentList: [String]) -> String {
        var copy = line(key)
        for index in stride(from: argumentList.count, through: 1, by: -1) {
            copy = copy.replacingOccurrences(of: "%\(index)", with: argumentList[index - 1])
        }
        return copy
    }
}
