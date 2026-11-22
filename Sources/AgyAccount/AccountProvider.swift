import Foundation

/// 支持切换登录的 CLI 工具类型。
public enum AccountProvider: String, CaseIterable, Equatable, Sendable {
    case antigravity
    case colab

    public var displayName: String {
        switch self {
        case .antigravity:
            return "Antigravity"
        case .colab:
            return "Colab"
        }
    }

    public var next: AccountProvider {
        switch self {
        case .antigravity:
            return .colab
        case .colab:
            return .antigravity
        }
    }

    public var cliPrefix: [String] {
        switch self {
        case .antigravity:
            return []
        case .colab:
            return ["colab"]
        }
    }
}

protocol LoginDecoding {
    func decodeKeychain(_ blob: String, lookupEmailByBlob: (String) -> String?) throws -> LoginMeta
    func decodeSaved(_ blob: String, sidecarEmail: String?) throws -> LoginMeta
    func refreshToken(in blob: String) -> String?
    func canRecover(_ blob: String) -> Bool
}

struct AntigravityLoginCodec: LoginDecoding {
    func decodeKeychain(_ blob: String, lookupEmailByBlob: (String) -> String?) throws -> LoginMeta {
        try decodeLogin(blob, source: .keychain)
    }

    func decodeSaved(_ blob: String, sidecarEmail: String?) throws -> LoginMeta {
        try decodeLogin(blob, source: .saved)
    }

    func refreshToken(in blob: String) -> String? {
        loginRefreshToken(blob)
    }

    func canRecover(_ blob: String) -> Bool {
        (try? decodeLogin(blob, source: .saved)) != nil
    }
}

public func providerTextKey(_ key: TextKey, provider: AccountProvider) -> TextKey {
    guard provider == .colab else {
        return key
    }
    switch key {
    case .keychainMissing: return .colabKeychainMissing
    case .keychainDenied: return .colabKeychainDenied
    case .noSavedAccounts: return .colabNoSavedAccounts
    case .noCurrentAccount: return .colabNoCurrentAccount
    case .currentNoLogin: return .colabCurrentNoLogin
    case .initializedNoLogin: return .colabInitializedNoLogin
    case .loginOpening: return .colabLoginOpening
    case .agyLaunchFailed: return .colabLaunchFailed
    case .panelNoAccounts: return .colabPanelNoAccounts
    case .panelRefreshing: return .colabPanelRefreshing
    case .panelRefreshed: return .colabPanelRefreshed
    default: return key
    }
}

struct ProviderNotice: Equatable {
    var key: TextKey
    var arguments: [String] = []
}

protocol ProviderStateSyncing {
    func prepareSwitch(from previousNames: [String], to targetName: String, sameEmail: Bool) throws
    func afterSwitch(from previousNames: [String], to targetName: String, sameEmail: Bool) -> [ProviderNotice]
    func renameAuxiliary(from source: String, to target: String)
    func removeAuxiliary(_ name: String)
}

extension ProviderStateSyncing {
    func prepareSwitch(from previousNames: [String], to targetName: String, sameEmail: Bool) throws {}
}

struct AntigravityStateSync: ProviderStateSyncing {
    var files: AccountFiles

    func afterSwitch(from previousNames: [String], to targetName: String, sameEmail: Bool) -> [ProviderNotice] {
        guard !sameEmail, let quota = files.clearQuotaCache() else {
            return []
        }
        return [ProviderNotice(key: .quotaFailed, arguments: [quota.path, quota.detail])]
    }

    func renameAuxiliary(from source: String, to target: String) {}

    func removeAuxiliary(_ name: String) {}
}
