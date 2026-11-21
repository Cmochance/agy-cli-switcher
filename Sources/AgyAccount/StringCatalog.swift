import Foundation

struct ParsedCatalog {
    var order: [String]
    var values: [String: String]
}

enum StringCatalog {
    private static let tables: [AppLanguage: [String: String]] = loadBundled()

    static func text(_ key: TextKey, _ language: AppLanguage) -> String {
        tables[language]?[key.rawValue] ?? key.rawValue
    }

    static func bundled(_ language: AppLanguage) -> [String: String] {
        tables[language] ?? [:]
    }

    static func parse(_ source: String) -> ParsedCatalog {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var order: [String] = []
        var values: [String: String] = [:]
        var current: String?
        var body: [String] = []

        func flush() {
            guard let key = current else {
                return
            }
            var rows = body
            if rows.last?.isEmpty == true {
                rows.removeLast()
            }
            order.append(key)
            values[key] = rows.joined(separator: "\n")
            body = []
        }

        for line in lines {
            if let key = keyName(line) {
                flush()
                current = key
            } else if current != nil {
                body.append(line)
            }
        }
        flush()
        return ParsedCatalog(order: order, values: values)
    }

    // 四个语言文件编在二进制里（Package.swift 的 embedInCode），运行时不找资源包。
    // 经符号链接运行时 Bundle.main 指向链接所在的目录（实测），按位置找资源包会找不到。
    private static func loadBundled() -> [AppLanguage: [String: String]] {
        var loaded: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            loaded[language] = parse(String(decoding: embedded(language), as: UTF8.self)).values
        }
        return loaded
    }

    private static func embedded(_ language: AppLanguage) -> [UInt8] {
        switch language {
        case .simplifiedChinese:
            return PackageResources.zh_Hans_txt
        case .traditionalChinese:
            return PackageResources.zh_Hant_txt
        case .english:
            return PackageResources.en_txt
        case .japanese:
            return PackageResources.ja_txt
        }
    }

    private static func keyName(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 3 else {
            return nil
        }
        let name = line.dropFirst().dropLast()
        guard let first = name.first, isASCIILetter(first) else {
            return nil
        }
        for character in name where !isASCIILetter(character) && !isASCIIDigit(character) {
            return nil
        }
        return String(name)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        ("A"..."Z").contains(character) || ("a"..."z").contains(character)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }
}
