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
public enum TextKey: String, CaseIterable {
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
    case refreshNeedsQuota
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
    case loginNotWritable
    case readFailed
    case writeFailed
    case deleteFailed
    case quotaFailed
    case usageFailed
    case usageBusy
    case planUnpaid
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
    case currentNoLogin
    case currentUnreadable
    case autoSaveFailed
    case stateBusy
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
    case switchAddNeedsTerminal
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
    case nameReserved
    case initializedSaved
    case initializedNoLogin
    case initializedNameRejected
    case agyLaunchFailed
    case panelNoAccounts
    case panelWorking
    case panelRefresh
    case panelRefreshing
    case panelRefreshed
    case panelAdd
    case panelAddOpened
    case panelAddFailed
    case panelSave
    case panelSavePrompt
    case panelRename
    case panelRenamePrompt
    case panelRemove
    case panelRemoveConfirm
    case panelRemoveLastCopy
    case panelRemoveNow
    case panelLanguage
    case panelQuit
    case panelCancel
    case panelConfirm
    case panelReplaceConfirm
    case panelReplaceNow
    case accountChanged
    case saveWouldReplace
    case moveNeedsNameAndPosition
    case moveBadPosition
    case moved
    case colabNotFound
    case colabLoginFormat
    case colabKeychainMissing
    case colabKeychainDenied
    case colabMissingEmail
    case colabEmailFailed
    case colabActiveSessions
    case colabNoSavedAccounts
    case colabNoCurrentAccount
    case colabCurrentNoLogin
    case colabInitializedNoLogin
    case colabLoginOpening
    case colabLaunchFailed
    case colabPanelNoAccounts
    case colabPanelRefreshing
    case colabPanelRefreshed
    case colabRowBalance
    case colabRowRate
    case colabRowSessions
    case colabActiveBadge
    case colabLoginPressC
    case colabLoginCodePrompt
    case colabLoginCancelled
    case colabLoginCodeRejected
    case colabBrowserFailed
    case colabOAuthConfigMissing
    case colabLoginPageDone
    case panelColabWaiting
    case panelColabUseCode
    case panelColabCodePrompt
    case guardUsage
    case guardAntigravityOnly
    case guardStatusOn
    case guardStatusOff
    case guardEnabled
    case guardDisabled
    case guardWatching
    case guardHint
    case agyGuardedRunning
    case panelGuardToggle
    case telemetryAntigravityOnly
    case statsUsage
    case sessionUsage
    case sessionNotFound
    case telemetryNoSessions
    case statusBarUsage
    case statusBarStatusOn
    case statusBarStatusOff
    case statusBarEnabled
    case statusBarDisabled
    case statusBarHint
    case telemetryModelLabel
    case telemetryContextHeader
    case telemetryCompactedEst
    case telemetryCompactedCount
    case telemetryCachedContext
    case telemetryNewInput
    case telemetryOrchestrator
    case telemetryRoleExec
    case telemetryRolePlan
    case telemetryStatsHeader
    case telemetryTurnsSteps
    case telemetryTotalTokens
    case telemetryApiCost
    case telemetryAvgSpeed
    case telemetryPeakSpeed
    case telemetryLatestSpeed
    case telemetryCacheHit
    case telemetryCacheWindow
    case telemetryCacheUnconfirmed
    case telemetryModelTime
    case telemetryToolTime
    case telemetryTtft
    case telemetrySubagentsHeader
    case telemetrySubagentTokens
    case telemetryCombinedTokens
    case telemetryReqTools
    case telemetrySubagentCache
    case telemetrySubagentCost
    case telemetryCombinedCost
    case telemetryCatMessages
    case telemetryCatSystem
    case telemetryCatTools
    case telemetryCatSkills
    case telemetryCatSubagents
    case telemetryCatPlugins
    case telemetryCatRules
    case telemetryCatMemories
    case telemetryCatOther
    case telemetryCatInput
    case telemetryCatFree
    case telemetryDurationMinSec
    case telemetryDurationSec
    case telemetryAllAccounts
    case telemetryUnattributed
    case telemetryOverviewHeader
    case telemetryReqCount
    case telemetrySuccess
    case telemetryError
    case telemetryInput
    case telemetryOutput
    case telemetryCostLabel
    case telemetryAvgPerReq
    case telemetryHeatmapHeader
    case telemetryHealthHeader
    case telemetryNoRequests
    case telemetryRangeWeekly
    case telemetryRangeToday
    case telemetryRange24h
    case telemetryRangeYesterday
    case telemetryRangeWeek
    case telemetryRangeMonth
    case telemetryRange30d
    case telemetryRangeAll
    case telemetryWeeklyActive
    case telemetryWeeklyUnstarted
    case telemetryWeeklyFallback
    case panelTabAccounts
    case panelTabSession
    case panelTabStats
    case panelStatusBarToggle
    case panelSessionAutoFollow
    case panelSourceAll
    case panelSourceCLI
    case panelSourceApp
    case panelPricingStandard
    case panelPricingPromo
    case panelContextUsed
    case panelMoreStats
    case panelSubagentSummaryHeader
    case panelHeatmapTokens
    case panelHeatmapRequests
    case panelHeatmapCost
    case panelThinkingTokens
    case panelRequestErrors
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

public struct Localizer {
    var language: AppLanguage

    public func line(_ key: TextKey, _ arguments: String...) -> String {
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

