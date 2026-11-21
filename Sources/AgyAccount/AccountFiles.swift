import Darwin
import Foundation

struct AccountLocations {
    var accountsDirectory: URL
    var quotaCache: URL

    init(home: URL) {
        let base = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
        accountsDirectory = base.appendingPathComponent("accounts", isDirectory: true)
        quotaCache = base.appendingPathComponent(".quota_cache.json")
    }

    func tokenURL(_ name: String) -> URL {
        accountsDirectory.appendingPathComponent("\(name).token")
    }

    func metaURL(_ name: String) -> URL {
        accountsDirectory.appendingPathComponent("\(name).meta.json")
    }

    var activeURL: URL {
        accountsDirectory.appendingPathComponent("active")
    }
}

struct AccountFiles {
    var locations: AccountLocations
    var now: () -> String
    private let manager = FileManager.default

    func savedNames() -> [String] {
        guard let urls = try? manager.contentsOfDirectory(
            at: locations.accountsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var names: [String] = []
        for url in urls where url.lastPathComponent.hasSuffix(".token") {
            let name = url.deletingPathExtension().lastPathComponent
            guard (try? checkName(name)) != nil, manager.fileExists(atPath: locations.metaURL(name).path) else {
                continue
            }
            names.append(name)
        }
        return names.sorted()
    }

    func readSaved(_ name: String) throws -> (blob: String, meta: LoginMeta) {
        let url = locations.tokenURL(name)
        guard manager.fileExists(atPath: url.path) else {
            let existing = savedNames()
            if existing.isEmpty {
                throw AccountFailure(.accountMissingNone, name)
            }
            throw AccountFailure(.accountMissing, name, existing.joined(separator: ", "))
        }
        let blob = stripNewlines(try readText(url))
        return (blob, try decodeLogin(blob, source: .saved))
    }

    func writeSaved(name: String, blob: String, meta: LoginMeta) throws {
        try ensureDirectory()
        try AtomicFile.write(locations.tokenURL(name), blob + "\n")
        let sidecar = encodeSidecar(
            name: name,
            email: meta.email,
            authMethod: meta.authMethod,
            expiry: meta.expiry,
            savedAt: now()
        )
        try AtomicFile.write(locations.metaURL(name), sidecar)
    }

    func setActive(_ name: String) throws {
        try ensureDirectory()
        try AtomicFile.write(locations.activeURL, name + "\n")
    }

    func activeName() -> String {
        guard manager.fileExists(atPath: locations.activeURL.path),
              let text = try? readText(locations.activeURL)
        else {
            return ""
        }
        return stripNewlines(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func slots(forEmail email: String) -> [String] {
        savedNames().filter { name in
            (try? readSaved(name).meta.email) == email
        }
    }

    func secretExists(_ name: String) -> Bool {
        manager.fileExists(atPath: locations.tokenURL(name).path)
            || manager.fileExists(atPath: locations.metaURL(name).path)
    }

    func renameSaved(from source: String, to target: String, meta: LoginMeta, savedAt: String) throws {
        let tokenFrom = locations.tokenURL(source)
        let tokenTo = locations.tokenURL(target)
        let metaFrom = locations.metaURL(source)
        let metaTo = locations.metaURL(target)
        let hadToken = manager.fileExists(atPath: tokenFrom.path)
        let hadMeta = manager.fileExists(atPath: metaFrom.path)
        if !hadToken && !hadMeta {
            return
        }
        if hadToken {
            do {
                try manager.moveItem(at: tokenFrom, to: tokenTo)
            } catch {
                throw AccountFailure(.renameFailed, source)
            }
        }
        do {
            try AtomicFile.write(
                metaTo,
                encodeSidecar(
                    name: target,
                    email: meta.email,
                    authMethod: meta.authMethod,
                    expiry: meta.expiry,
                    savedAt: savedAt
                )
            )
            if hadMeta {
                try manager.removeItem(at: metaFrom)
            }
        } catch {
            if hadToken {
                try? manager.moveItem(at: tokenTo, to: tokenFrom)
            }
            if manager.fileExists(atPath: metaTo.path) {
                try? manager.removeItem(at: metaTo)
            }
            throw AccountFailure(.renameFailed, source)
        }
    }

    func removeSaved(_ name: String) throws {
        do {
            if manager.fileExists(atPath: locations.tokenURL(name).path) {
                try manager.removeItem(at: locations.tokenURL(name))
            }
            if manager.fileExists(atPath: locations.metaURL(name).path) {
                try manager.removeItem(at: locations.metaURL(name))
            }
            if activeName() == name {
                try manager.removeItem(at: locations.activeURL)
            }
        } catch let error as AccountFailure {
            throw error
        } catch {
            throw AccountFailure(.deleteFailed, name)
        }
    }

    func clearQuotaCache() -> (path: String, detail: String)? {
        do {
            try manager.removeItem(at: locations.quotaCache)
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        } catch {
            return (locations.quotaCache.path, error.localizedDescription)
        }
    }

    private func ensureDirectory() throws {
        try manager.createDirectory(at: locations.accountsDirectory, withIntermediateDirectories: true)
        try setPermissions(locations.accountsDirectory, 0o700)
    }

    private func readText(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AccountFailure(.readFailed, url.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AccountFailure(.loginUnreadable)
        }
        return text
    }

    private func setPermissions(_ url: URL, _ mode: Int) throws {
        try manager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }
}

enum AtomicFile {
    static func write(_ url: URL, _ content: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        let temporary = url.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try? FileManager.default.removeItem(at: temporary)
        }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw AccountFailure(.writeFailed, url.path)
        }
        do {
            try writeAll(descriptor, content, url)
            guard fsync(descriptor) == 0 else {
                throw AccountFailure(.writeFailed, url.path)
            }
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        guard close(descriptor) == 0 else {
            unlink(temporary.path)
            throw AccountFailure(.writeFailed, url.path)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporary.path
            )
        } catch {
            unlink(temporary.path)
            throw error
        }
        if rename(temporary.path, url.path) != 0 {
            unlink(temporary.path)
            throw AccountFailure(.writeFailed, url.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private static func writeAll(_ descriptor: Int32, _ content: String, _ url: URL) throws {
        let bytes = Array(content.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else {
                    return -1
                }
                return Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 {
                throw AccountFailure(.writeFailed, url.path)
            }
            offset += written
        }
    }
}

func encodeSidecar(name: String, email: String, authMethod: String, expiry: String, savedAt: String) -> String {
    let fields = [
        ("name", name),
        ("email", email),
        ("auth_method", authMethod),
        ("expiry", expiry),
        ("saved_at", savedAt),
    ]
    let body = fields.enumerated().map { index, field in
        let comma = index == fields.count - 1 ? "" : ","
        return "  \(jsonString(field.0)): \(jsonString(field.1))\(comma)"
    }.joined(separator: "\n")
    return "{\n\(body)\n}\n"
}

private func jsonString(_ value: String) -> String {
    var encoded = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\":
            encoded += "\\\\"
        case "\"":
            encoded += "\\\""
        case "\n":
            encoded += "\\n"
        case "\r":
            encoded += "\\r"
        case "\t":
            encoded += "\\t"
        default:
            if scalar.value < 0x20 {
                encoded += String(format: "\\u%04x", scalar.value)
            } else {
                encoded.unicodeScalars.append(scalar)
            }
        }
    }
    encoded += "\""
    return encoded
}
