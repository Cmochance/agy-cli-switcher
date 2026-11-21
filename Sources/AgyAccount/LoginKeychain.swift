import Foundation
import Security

protocol KeychainStoring {
    func readBlob() throws -> String
    func writeBlob(_ blob: String) throws
    func deleteBlob() throws
}

struct LoginKeychainStore: KeychainStoring {
    func readBlob() throws -> String {
        let data = try copyData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw AccountFailure(.keychainFormat)
        }
        return stripNewlines(text)
    }

    func writeBlob(_ blob: String) throws {
        let original = try? readBlob()
        try store(Data(blob.utf8))
        let written = try readBlob()
        guard written == blob else {
            if let original, original != written {
                try? store(Data(original.utf8))
            }
            throw AccountFailure(.writeMismatch)
        }
    }

    func deleteBlob() throws {
        let status = SecItemDelete(query() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        // /usr/bin/security 创建的项，SecItemDelete 返回 errSecInvalidOwnerEdit (-25244)，项还在。
        if status == errSecInvalidOwnerEdit {
            try deleteItemReference()
            return
        }
        throw statusError(status)
    }

    private func deleteItemReference() throws {
        var spec = query()
        spec[kSecReturnRef as String] = true
        spec[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let found = SecItemCopyMatching(spec as CFDictionary, &result)
        if found == errSecItemNotFound {
            return
        }
        guard found == errSecSuccess, let result else {
            throw statusError(found)
        }
        let deleted = SecKeychainItemDelete(result as! SecKeychainItem)
        if deleted == errSecSuccess || deleted == errSecItemNotFound {
            return
        }
        throw statusError(deleted)
    }

    func matchingItemCount(dataProtection: Bool) throws -> Int {
        var spec = query()
        spec[kSecUseDataProtectionKeychain as String] = dataProtection
        spec[kSecMatchLimit as String] = kSecMatchLimitAll
        spec[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(spec as CFDictionary, &result)
        if status == errSecItemNotFound {
            return 0
        }
        guard status == errSecSuccess else {
            throw statusError(status)
        }
        return (result as? [Any])?.count ?? 0
    }

    private func copyData() throws -> Data {
        var spec = query()
        spec[kSecReturnData as String] = true
        spec[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(spec as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw statusError(status)
        }
        return data
    }

    private func store(_ data: Data) throws {
        let status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var created = query()
            created[kSecValueData as String] = data
            let added = SecItemAdd(created as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw statusError(added)
            }
            return
        }
        guard status == errSecSuccess else {
            throw statusError(status)
        }
    }

    // agy 的登录由 security 写在 login keychain。kSecUseDataProtectionKeychain 为 true 时
    // SecItem 找不到这一条（实测 errSecItemNotFound），所以这里固定查文件钥匙串。
    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    private func statusError(_ status: OSStatus) -> AccountFailure {
        switch status {
        case errSecItemNotFound:
            return AccountFailure(.keychainMissing)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return AccountFailure(.keychainDenied)
        default:
            return AccountFailure(.keychainFailed, String(status))
        }
    }
}

protocol ProcessListing {
    func runningAgyPIDs() -> [Int]
}

struct SystemProcessList: ProcessListing {
    func runningAgyPIDs() -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "agy"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isNewline).compactMap { Int($0) }
    }
}

enum AccountClock {
    static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }
}
