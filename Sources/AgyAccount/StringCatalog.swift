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

    private static func loadBundled() -> [AppLanguage: [String: String]] {
        var loaded: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let url = Bundle.module.url(
                forResource: language.rawValue,
                withExtension: "txt",
                subdirectory: "i18n"
            ) ?? Bundle.module.url(forResource: language.rawValue, withExtension: "txt")
            guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
                loaded[language] = [:]
                continue
            }
            loaded[language] = parse(source).values
        }
        return loaded
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
