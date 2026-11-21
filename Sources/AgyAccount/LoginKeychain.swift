import Foundation
import Security

protocol KeychainStoring {
    func readBlob() throws -> String
    func writeBlob(_ blob: String) throws
    func deleteBlob() throws
}

struct SecurityToolResult {
    var status: Int32
    var output: Data
}

protocol SecurityToolRunning {
    func run(_ arguments: [String], input: Data?) throws -> SecurityToolResult
}

// agy 通过 /usr/bin/security 读写这一项。钥匙串只信任这个程序，分区名单里也只有它的 apple-tool:。
// 在本进程里读，每次都要输钥匙串密码；在本进程里写，分区名单会被换成本程序的 cdhash，
// 之后 agy 自己读取也会被拦（实测）。所以这里和 agy 用同一个程序。
struct LoginKeychainStore: KeychainStoring {
    var tool: any SecurityToolRunning = SecurityTool()
    var service = keychainService
    var account = keychainAccount

    func readBlob() throws -> String {
        let result = try tool.run(["find-generic-password", "-s", service, "-a", account, "-w"], input: nil)
        guard result.status == 0 else {
            throw securityFailure(exitStatus: result.status)
        }
        guard let text = String(data: result.output, encoding: .utf8) else {
            throw AccountFailure(.keychainFormat)
        }
        return stripNewlines(text)
    }

    func writeBlob(_ blob: String) throws {
        let original = try? readBlob()
        try store(blob)
        let written = try readBlob()
        guard written == blob else {
            if let original, original != written {
                try? store(original)
            }
            throw AccountFailure(.writeMismatch)
        }
    }

    func deleteBlob() throws {
        let result = try tool.run(["delete-generic-password", "-s", service, "-a", account], input: nil)
        if result.status != 0, result.status != securityExitCode(errSecItemNotFound) {
            throw securityFailure(exitStatus: result.status)
        }
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
            throw AccountFailure(.keychainFailed, String(status))
        }
        return (result as? [Any])?.count ?? 0
    }

    // 内容从标准输入送给 security -i，不出现在任何进程的参数里。
    private func store(_ blob: String) throws {
        guard let line = securityAddLine(service: service, account: account, blob: blob) else {
            throw AccountFailure(.keychainFailed, "login")
        }
        let result = try tool.run(["-i"], input: Data(line.utf8))
        guard result.status == 0 else {
            throw securityFailure(exitStatus: result.status)
        }
    }

    // agy 的登录由 security 写在 login keychain。kSecUseDataProtectionKeychain 为 true 时
    // SecItem 找不到这一条（实测 errSecItemNotFound），所以这里固定查文件钥匙串。
    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
}

struct SecurityTool: SecurityToolRunning {
    func run(_ arguments: [String], input: Data?) throws -> SecurityToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let feed = Pipe()
        let output = Pipe()
        process.standardInput = feed
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AccountFailure(.keychainFailed, "security")
        }
        let writer = feed.fileHandleForWriting
        // security 提前退出时，写管道得到错误，本进程不会收到 SIGPIPE。
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let fed = input.map { (try? writer.write(contentsOf: $0)) != nil } ?? true
        try? writer.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard fed, process.terminationReason == .exit else {
            throw AccountFailure(.keychainFailed, "security")
        }
        return SecurityToolResult(status: process.terminationStatus, output: data)
    }
}

// 实测整行连换行在 4096 个字节以内能完整写入。从 4097 起，security -i 把前 4095 个字节当成一条指令执行，
// 剩下的当成下一条指令。这里留一个字节的余量，并且只放行 go-keyring-base64 前缀加 base64 字符，
// 换行、空格和引号都进不来。
let securityLineLimit = 4095

func securityAddLine(service: String, account: String, blob: String) -> String? {
    guard (try? checkName(service)) != nil, (try? checkName(account)) != nil,
          blob.hasPrefix(keychainPrefix), isBase64Text(blob.dropFirst(keychainPrefix.count))
    else {
        return nil
    }
    let line = "add-generic-password -U -s \(service) -a \(account) -w \(blob)\n"
    return line.utf8.count <= securityLineLimit ? line : nil
}

// security 的退出码是 OSStatus 的低 8 位。找不到这一项时是 44（实测）。
func securityExitCode(_ status: OSStatus) -> Int32 {
    Int32(UInt8(truncatingIfNeeded: status))
}

func securityFailure(exitStatus: Int32) -> AccountFailure {
    switch exitStatus {
    case securityExitCode(errSecItemNotFound):
        return AccountFailure(.keychainMissing)
    case securityExitCode(errSecUserCanceled), securityExitCode(errSecAuthFailed),
         securityExitCode(errSecInteractionNotAllowed):
        return AccountFailure(.keychainDenied)
    default:
        return AccountFailure(.keychainFailed, String(exitStatus))
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
