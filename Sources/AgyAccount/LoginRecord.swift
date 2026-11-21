import Foundation

enum LoginSource {
    case keychain
    case saved
}

struct LoginMeta: Equatable {
    var email: String
    var authMethod: String
    var expiry: String
}

let keychainService = "gemini"
let keychainAccount = "antigravity"
let keychainPrefix = "go-keyring-base64:"

func stripNewlines(_ value: String) -> String {
    var text = Substring(value)
    while text.first == "\n" {
        text = text.dropFirst()
    }
    while text.last == "\n" {
        text = text.dropLast()
    }
    return String(text)
}

func checkName(_ name: String) throws -> String {
    let scalars = Array(name.unicodeScalars)
    guard (1 ... 64).contains(scalars.count),
          let first = scalars.first,
          isNameLetter(first),
          scalars.dropFirst().allSatisfy(isNameBody)
    else {
        throw AccountFailure(.invalidName)
    }
    return name
}

func defaultAccountName(email: String) throws -> String {
    guard let separator = email.firstIndex(of: "@"), separator != email.startIndex else {
        throw AccountFailure(.invalidName)
    }
    return try checkName(String(email[..<separator]))
}

func decodeLogin(_ blob: String, source: LoginSource) throws -> LoginMeta {
    guard blob.hasPrefix(keychainPrefix) else {
        switch source {
        case .keychain:
            throw AccountFailure(.keychainFormat)
        case .saved:
            throw AccountFailure(.savedPrefix)
        }
    }
    let encoded = String(blob.dropFirst(keychainPrefix.count))
    guard let payload = decodeBase64(encoded),
          let object = try? JSONSerialization.jsonObject(with: payload)
    else {
        throw AccountFailure(.loginUnreadable)
    }
    guard let data = object as? [String: Any] else {
        throw AccountFailure(.loginNotObject)
    }
    guard let email = data["id_token_email"] as? String, email.contains("@") else {
        throw AccountFailure(.missingEmail)
    }
    guard let token = data["token"] as? [String: Any], token["refresh_token"] is String else {
        throw AccountFailure(.missingRefresh)
    }
    let authMethod = data["auth_method"] as? String ?? ""
    let expiry = token["expiry"] as? String ?? ""
    return LoginMeta(email: email, authMethod: authMethod, expiry: expiry)
}

private func isNameLetter(_ scalar: Unicode.Scalar) -> Bool {
    ("0" ... "9").contains(Character(scalar))
        || ("A" ... "Z").contains(Character(scalar))
        || ("a" ... "z").contains(Character(scalar))
}

private func isNameBody(_ scalar: Unicode.Scalar) -> Bool {
    isNameLetter(scalar) || scalar == "." || scalar == "_" || scalar == "-"
}

private func decodeBase64(_ value: String) -> Data? {
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    guard !value.isEmpty, value.count.isMultiple(of: 4), value.allSatisfy({ alphabet.contains($0) }) else {
        return nil
    }
    return Data(base64Encoded: value)
}
