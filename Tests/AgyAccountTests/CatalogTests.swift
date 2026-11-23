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
            for token in ["current", "list", "save", "switch", "switch add", "next", "refresh quota", "rename", "move", "rm", "language", "help"] {
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
                "current", "list", "save", "switch", "next", "refresh quota", "rename", "move", "rm", "language", "help",
                "make install", "make test", "agy-cs", "Sources/AgyAccount/i18n", "macOS 13"
            ] {
                XCTAssertTrue(document.contains(token), token)
            }
        }
        // 发布包的名字带版本号，README 里的下载链接每版跟着改。
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: repoRoot.appendingPathComponent("Packaging/Info.plist")) as? [String: Any]
        )
        let version = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        let downloads = "https://github.com/Cmochance/agy-cli-switcher/releases/download/v\(version)/"
        for document in [readme, english] {
            for token in [
                "Agy Switcher", downloads + "Agy-Switcher-v\(version)-macOS-universal.dmg",
                downloads + "agy-cs-v\(version)-macOS-universal.tar.gz",
                "Agy-Switcher-v\(version)-macOS-universal.dmg.sha256", "hdiutil attach",
                "make app", "make dist", "com.apple.quarantine", "Contents/MacOS/agy-cs"
            ] {
                XCTAssertTrue(document.contains(token), token)
            }
        }
        XCTAssertTrue(makefile.contains("swift test --disable-sandbox"))
        XCTAssertTrue(makefile.contains("ln -sfn"))
        XCTAssertFalse(makefile.contains(".bundle"))
        XCTAssertTrue(makefile.contains("rm -f build/agy-cs"))
        XCTAssertTrue(makefile.contains("codesign --force --sign - build/agy-cs"))
        for token in [
            "rm -rf \"$(2)\"", "Packaging/Info.plist", "Packaging/AppIcon.icns", "Contents/MacOS/agy-cs",
            "for arch in arm64 x86_64", "--arch $$arch", "lipo -create",
            "Agy-Switcher-v$(VERSION)-macOS-universal.dmg", "agy-cs-v$(VERSION)-macOS-universal.tar.gz",
            "hdiutil create", "ln -s /Applications", "$$file.sha256"
        ] {
            XCTAssertTrue(makefile.contains(token), token)
        }
        // 一次传两个 --arch 在 Xcode 26.6 上编译不过（CI 实测），见 Makefile 里的说明。
        XCTAssertFalse(makefile.contains("--arch arm64 --arch x86_64"))
        XCTAssertTrue(guide.contains("[saved]"))
        XCTAssertTrue(guide.contains("zh-Hans.txt"))
        XCTAssertTrue(guide.contains("%1"))
    }

    // 语言文件编在二进制里。按位置找资源包的写法在符号链接和 app 包里都会找不到。
    func testLanguageFilesAreCompiledIntoTheBinary() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        for language in AppLanguage.allCases {
            XCTAssertTrue(package.contains(".embedInCode(\"i18n/\(language.rawValue).txt\")"), language.rawValue)
        }
        XCTAssertFalse(package.contains(".copy("))
        XCTAssertFalse(package.contains(".process("))
        let walker = FileManager.default.enumerator(at: repoRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        var checked = 0
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else {
                continue
            }
            checked += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains("Bundle.module"), url.lastPathComponent)
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testAppBundleDescriptionMatchesTheCodeAndTheDocuments() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Packaging/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "agy-cs")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.cmochance.agy-cs")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Agy Switcher")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "13.0")
        XCTAssertEqual(plist["LSEnvironment"] as? [String: String], [menuBarMarker: "1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Packaging/AppIcon.icns").path))

        let version = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(plist["CFBundleVersion"] as? String, version)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
        for name in ["README.md", "README.en.md"] {
            let document = try String(contentsOf: repoRoot.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(document.contains("**v\(version)**"), name)
        }
        let changelog = try String(contentsOf: repoRoot.appendingPathComponent("documents/CHANGELOG.md"), encoding: .utf8)
        XCTAssertEqual(changelog.components(separatedBy: "\n").first { $0.hasPrefix("## ") }, "## \(version)")
    }

    func testReleaseWorkflowStopsAtADraft() throws {
        let workflows = repoRoot.appendingPathComponent(".github/workflows")
        let release = try String(contentsOf: workflows.appendingPathComponent("release.yml"), encoding: .utf8)
        for token in [
            "tags:", "swift test --disable-sandbox", "make dist", "gh release create", "--draft",
            "dist/*.dmg", "dist/*.dmg.sha256", "dist/*.tar.gz", "dist/*.tar.gz.sha256"
        ] {
            XCTAssertTrue(release.contains(token), token)
        }
        XCTAssertFalse(release.contains("--latest"))
        XCTAssertFalse(release.contains("draft=false"))
        let checks = try String(contentsOf: workflows.appendingPathComponent("ci.yml"), encoding: .utf8)
        XCTAssertTrue(checks.contains("make dist"))
        XCTAssertTrue(checks.contains("contents: read"))
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

    func testNoOAuthClientSecretIsWrittenInTheRepository() throws {
        var files = ["AGENTS.md", "README.md", "README.en.md", "SECURITY_MODEL.md"].map { repoRoot.appendingPathComponent($0) }
        for folder in ["Sources", "Tests"] {
            let walker = FileManager.default.enumerator(at: repoRoot.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                if ["swift", "txt", "md"].contains(url.pathExtension) {
                    files.append(url)
                }
            }
        }
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(text.range(of: "GOCSPX-[A-Za-z0-9_-]{28}", options: .regularExpression), file.lastPathComponent)
        }
    }

    func testColabContractMatchesCode() throws {
        let contractURL = repoRoot.appendingPathComponent("documents/COLAB_CONTRACT.md")
        let contract = try String(contentsOf: contractURL, encoding: .utf8)
        for token in [
            "baseline_repo`: `googlecolab/google-colab-cli`",
            "baseline_version`: `0.8.0`",
            "baseline_tag`: `v0.8.0`",
            "baseline_commit`:",
            colabKeychainService,
            colabKeychainAccount,
            "sessions.json",
            "sessions.attached.json",
            "settings.json",
            "public_api_supported",
            "tunnel_api_supported",
            ColabUsageFetcher.ccuInfoURL.path,
            "X-Colab-Client-Agent",
            "colab-cli",
            "127.0.0.1",
            "access_denied",
            "accounts.google.com",
            "oauth2.googleapis.com",
            "applicationdefaultauthcode.html",
            "universe_domain",
        ] {
            XCTAssertTrue(contract.contains(token), "COLAB_CONTRACT.md missing \(token)")
        }

        let watchURL = repoRoot.appendingPathComponent(".github/workflows/colab-upstream-watch.yml")
        let watch = try String(contentsOf: watchURL, encoding: .utf8)
        XCTAssertTrue(watch.contains("documents/COLAB_CONTRACT.md"))
        XCTAssertTrue(watch.contains("continue-on-error: true"))
        XCTAssertTrue(watch.contains("contents: read"))
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
