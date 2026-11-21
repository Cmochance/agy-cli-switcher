import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"

    var nativeName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        case .english:
            return "English"
        case .japanese:
            return "日本語"
        }
    }

    static func resolve(preferred: [String]) -> AppLanguage {
        for identifier in preferred {
            if let language = match(identifier) {
                return language
            }
        }
        return .english
    }

    static func parse(_ token: String) -> AppLanguage? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "zh", "cn", "chinese":
            return .simplifiedChinese
        case "zht", "traditional":
            return .traditionalChinese
        case "english":
            return .english
        case "japanese":
            return .japanese
        default:
            return match(trimmed)
        }
    }

    private static func match(_ identifier: String) -> AppLanguage? {
        let lowered = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if lowered.hasPrefix("zh-hant") || lowered.hasPrefix("zh-tw") || lowered.hasPrefix("zh-hk") || lowered.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        if lowered.hasPrefix("zh") {
            return .simplifiedChinese
        }
        if lowered.hasPrefix("ja") {
            return .japanese
        }
        if lowered.hasPrefix("en") {
            return .english
        }
        return nil
    }
}

/// 界面句子的键。正文在 `i18n/*.txt`，键名与 case 名相同。
enum TextKey: String, CaseIterable {
    case help
    case operationFailed
    case helpNoExtra
    case unknownCommand
    case commandNoExtra
    case needsName
    case rmUnknownArgument
    case rmOnlyOneName
    case rmNeedsName
    case useRenamed
    case invalidName
    case keychainFormat
    case savedPrefix
    case loginUnreadable
    case loginNotObject
    case missingEmail
    case missingRefresh
    case accountMissing
    case accountMissingNone
    case keychainMissing
    case keychainDenied
    case keychainFailed
    case writeMismatch
    case readFailed
    case writeFailed
    case deleteFailed
    case quotaFailed
    case noSavedAccounts
    case saved
    case alreadyActive
    case refreshedTokens
    case refreshedBeforeSwitch
    case currentNotSaved
    case switched
    case agyStillRunning
    case reopenAgy
    case needTwoAccounts
    case currentNotInSaved
    case sameEmailOnly
    case onlyCopy
    case removed
    case keychainUnchanged
    case noCurrentAccount
    case languageUnknown
    case languageFollowing
    case languageChosen
    case languageSet
    case languageAvailableHeader
    case languageHint
    case languageNoExtra
    case menuCurrentSuffix
    case menuNoCurrent
    case menuAddAccount
    case menuPrompt
    case menuCurrentLocked
    case menuBadChoice
    case switchNeedsTerminal
    case loginOpening
    case loginCancelled
    case loginNotFinished
    case loginRestored
    case startingAgy
    case renamed
    case renameUnchanged
    case renameNeedsName
    case renameTooMany
    case renameFailed
    case nameTaken
    case initializedSaved
    case initializedNoLogin
    case initializedNameRejected
    case agyLaunchFailed
}

struct AccountFailure: Error, Equatable {
    var key: TextKey
    var arguments: [String]

    init(_ key: TextKey, _ arguments: String...) {
        self.key = key
        self.arguments = arguments
    }
}

struct UsageFailure: Error {
    var key: TextKey
    var arguments: [String]

    init(_ key: TextKey, _ arguments: String...) {
        self.key = key
        self.arguments = arguments
    }
}

struct Localizer {
    var language: AppLanguage

    func line(_ key: TextKey, _ arguments: String...) -> String {
        fill(StringCatalog.text(key, language), arguments)
    }
}

private func fill(_ template: String, _ arguments: [String]) -> String {
    var result = template
    for index in stride(from: arguments.count, through: 1, by: -1) {
        result = result.replacingOccurrences(of: "%\(index)", with: arguments[index - 1])
    }
    return result
}

