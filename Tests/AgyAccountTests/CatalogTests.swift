import XCTest
@testable import AgyAccount

final class CatalogTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testParseKeepsInternalBlankLines() {
        let parsed = StringCatalog.parse("[help]\n第一行\n\n第二行\n\n[saved]\n已保存 %1  %2\n")
        XCTAssertEqual(parsed.order, ["help", "saved"])
        XCTAssertEqual(parsed.values["help"], "第一行\n\n第二行")
        XCTAssertEqual(parsed.values["saved"], "已保存 %1  %2")
    }

    func testCatalogMatchesKeysAndPlaceholders() throws {
        let keys = TextKey.allCases.map(\.rawValue)
        var byLanguage: [AppLanguage: ParsedCatalog] = [:]
        for language in AppLanguage.allCases {
            let url = repoRoot.appendingPathComponent("Sources/AgyAccount/i18n/\(language.rawValue).txt")
            let source = try String(contentsOf: url, encoding: .utf8)
            let parsed = StringCatalog.parse(source)
            XCTAssertEqual(parsed.order, keys, language.rawValue)
            XCTAssertEqual(Set(parsed.values.keys), Set(keys), language.rawValue)
            for (key, value) in parsed.values {
                XCTAssertFalse(value.isEmpty, "\(language.rawValue) \(key)")
            }
            XCTAssertEqual(parsed.values, StringCatalog.bundled(language), language.rawValue)
            byLanguage[language] = parsed
        }

        let reference = try XCTUnwrap(byLanguage[.simplifiedChinese]).values
        for language in AppLanguage.allCases where language != .simplifiedChinese {
            let values = try XCTUnwrap(byLanguage[language]).values
            for key in keys {
                XCTAssertEqual(
                    placeholders(try XCTUnwrap(values[key])),
                    placeholders(try XCTUnwrap(reference[key])),
                    "\(language.rawValue) \(key)"
                )
            }
        }

        for language in AppLanguage.allCases {
            let help = try XCTUnwrap(byLanguage[language]?.values["help"])
            for token in ["current", "list", "save", "switch", "switch add", "next", "rename", "rm", "language", "help"] {
                XCTAssertTrue(help.contains(token), "\(language.rawValue) help missing \(token)")
            }
        }
    }

    func testKnownSimplifiedLines() {
        let text = Localizer(language: .simplifiedChinese)
        XCTAssertEqual(text.line(.saved, "alice", "alice@example.com"), "已保存 alice  alice@example.com")
        XCTAssertEqual(text.line(.reopenAgy), "退出已打开的 agy，再开一个新会话才会用这个账号。")
        let help = text.line(.help)
        XCTAssertTrue(help.contains("切换"))
        XCTAssertTrue(help.contains("新增"))
        XCTAssertTrue(help.contains("rename"))
    }

    func testReadmeAndMakefileMentionTheContract() throws {
        let readme = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let english = try String(contentsOf: repoRoot.appendingPathComponent("README.en.md"), encoding: .utf8)
        let makefile = try String(contentsOf: repoRoot.appendingPathComponent("Makefile"), encoding: .utf8)
        let guide = try String(contentsOf: repoRoot.appendingPathComponent("Sources/AgyAccount/i18n/README.md"), encoding: .utf8)
        for document in [readme, english] {
            for token in [
                "current", "list", "save", "switch", "next", "rename", "rm", "language", "help",
                "make install", "make test", "agy-cs", "Sources/AgyAccount/i18n", "macOS 13"
            ] {
                XCTAssertTrue(document.contains(token), token)
            }
        }
        XCTAssertTrue(makefile.contains("swift test --disable-sandbox"))
        XCTAssertTrue(makefile.contains("ln -sfn"))
        XCTAssertTrue(makefile.contains("agy-cs_AgyAccount.bundle"))
        XCTAssertTrue(makefile.contains("rm -f build/agy-cs"))
        XCTAssertTrue(makefile.contains("codesign --force --sign - build/agy-cs"))
        XCTAssertTrue(guide.contains("[saved]"))
        XCTAssertTrue(guide.contains("zh-Hans.txt"))
        XCTAssertTrue(guide.contains("%1"))
    }

    func testKeychainContentOnlyGoesThroughTheSecurityTool() throws {
        let sources = repoRoot.appendingPathComponent("Sources/AgyAccount")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var combined = ""
        for file in files {
            combined += try String(contentsOf: file, encoding: .utf8)
        }
        XCTAssertTrue(combined.contains("\"/usr/bin/security\""))
        for token in ["SecItemUpdate(", "SecItemAdd(", "SecItemDelete(", "SecKeychainItemDelete(", "kSecReturnData", "kSecValueData"] {
            XCTAssertFalse(combined.contains(token), token)
        }
    }

    private func placeholders(_ text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%" {
                var end = text.index(after: index)
                var digits = ""
                while end < text.endIndex, text[end].isASCII && text[end].isNumber {
                    digits.append(text[end])
                    end = text.index(after: end)
                }
                if !digits.isEmpty {
                    found.append("%" + digits)
                    index = end
                    continue
                }
            }
            index = text.index(after: index)
        }
        return Array(Set(found)).sorted()
    }
}
