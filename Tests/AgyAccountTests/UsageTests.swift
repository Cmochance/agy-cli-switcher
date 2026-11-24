import XCTest
@testable import AgyAccount

final class UsageTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testPlanAndBucketsAreReadFromCloudCodeAnswers() throws {
        let plan = try XCTUnwrap(parsePlan(Data(planJSON.utf8)))
        XCTAssertEqual(plan.id, "g1-pro-tier")
        XCTAssertEqual(plan.name, "Google AI Pro")
        XCTAssertEqual(plan.project, "project-1")
        let current = try XCTUnwrap(parsePlan(Data(#"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#.utf8)))
        XCTAssertEqual(current.id, "free-tier")
        XCTAssertEqual(current.project, "")
        XCTAssertEqual(parsePlan(Data(#"{"paidTier":"g1-ultra-tier"}"#.utf8))?.id, "g1-ultra-tier")
        let odd = try XCTUnwrap(parsePlan(Data(#"{"cloudaicompanionProject":{"id":"pro\u001b[31mject-\#(String(repeating: "x", count: 80))"}}"#.utf8)))
        XCTAssertFalse(odd.project.contains("\u{1b}"))
        XCTAssertEqual(odd.project.count, 64)
        let kept = encodeUsage(UsageSnapshot(planID: "", planName: "", buckets: [], project: odd.project), email: "a@b.c", fetchedAt: "")
        XCTAssertFalse(kept.contains("\\u001b"))
        XCTAssertNil(parsePlan(Data("nope".utf8)))

        let buckets = try XCTUnwrap(parseBuckets(Data(summaryJSON.utf8)))
        XCTAssertEqual(buckets.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        XCTAssertEqual(buckets[0], UsageBucket(id: "gemini-weekly", remaining: 0.9962848, resetTime: "2026-11-28T10:23:13Z"))
        XCTAssertEqual(buckets[1].remaining, 0.62)
        XCTAssertEqual(parseBuckets(Data("{}".utf8)), [])
        XCTAssertNil(parseBuckets(Data("nope".utf8)))
    }

    func testPaidModelLockIsReadFromTheModelList() {
        func locked(_ json: String) -> Bool? {
            parsePaidModelsLocked(Data(json.utf8))
        }
        XCTAssertEqual(
            locked(#"{"models":{"gemini-4-carbon-disabled":{"disabled":true,"tagDescription":"Gemini 4 Carbon is currently available to Ultra and paid Pro plan subscribers."},"gemini-4-neon-disabled":{"disabled":true},"gemini-4-hydrogen-disabled":{"disabled":true},"gemini-4-hydrogen-sonar":{"recommended":true},"gemini-3.8-flash-high":{}}}"#),
            true
        )
        XCTAssertEqual(
            locked(#"{"models":{"gemini-4-carbon-high":{"recommended":true},"gemini-4-neon-high":{"recommended":true},"gemini-4-hydrogen-high":{"recommended":true}}}"#),
            false
        )
        XCTAssertEqual(
            locked(#"{"models":{"gemini-4-carbon-disabled":{"disabled":true},"gemini-4-neon-high":{"recommended":true}}}"#),
            false
        )
        XCTAssertEqual(
            locked(#"{"models":{"gemini-4-neon-high":{},"gemini-4-neon-disabled":{"disabled":true}}}"#),
            false
        )
        XCTAssertEqual(
            locked(#"{"models":{"gemini-4-future-disabled":{"disabled":true,"tagDescription":"Available to paid Pro and Ultra subscribers."}}}"#),
            true
        )
        XCTAssertNil(locked(#"{"models":{"gemini-5-alpha-disabled":{"disabled":true,"tagDescription":"Available to Ultra plan subscribers."}}}"#))
        XCTAssertNil(locked(#"{"models":{"gemini-3.8-flash-high":{}}}"#))
        XCTAssertNil(locked("{}"))
        XCTAssertNil(locked("nope"))
    }

    func testPlanLabelIsShortAndPlain() {
        XCTAssertEqual(planLabel(id: "g1-pro-tier", name: "Google AI Pro"), "Pro")
        XCTAssertEqual(planLabel(id: "g1-ultra-lite-tier", name: ""), "Ultra Lite")
        XCTAssertEqual(planLabel(id: "free-tier", name: "Antigravity Starter Quota"), "Free")
        XCTAssertEqual(planLabel(id: "", name: "Google AI Pro"), "Google AI Pro")
        XCTAssertEqual(planLabel(id: "", name: ""), "—")
        XCTAssertFalse(planLabel(id: "", name: "Pro\u{1b}[31m").contains("\u{1b}"))
    }

    func testBucketTextHidesTheResetTimeAtFullAndGoesBackToFullAfterIt() throws {
        let now = try XCTUnwrap(parseTimestamp("2026-11-21T10:00:00Z"))
        let later = try XCTUnwrap(parseTimestamp("2026-11-21T15:35:36Z"))
        let fiveHour = UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-11-21T15:35:35.5Z")
        XCTAssertEqual(bucketText(nil, now: now, timeZone: utc), "—")
        XCTAssertEqual(bucketText(fiveHour, now: now, timeZone: utc), "62% 11-21 15:35")
        XCTAssertEqual(bucketText(fiveHour, now: later, timeZone: utc), "100%")
        XCTAssertEqual(
            bucketText(UsageBucket(id: "x", remaining: 1, resetTime: "2026-11-28T10:00:00Z"), now: now, timeZone: utc),
            "100%"
        )
        XCTAssertEqual(
            bucketText(UsageBucket(id: "x", remaining: 0.9962848, resetTime: "2026-11-28T10:23:13Z"), now: now, timeZone: utc),
            "99% 11-28 10:23"
        )
        XCTAssertEqual(
            bucketText(UsageBucket(id: "x", remaining: 0.001, resetTime: "2026-11-28T10:23:13Z"), now: now, timeZone: utc),
            "1% 11-28 10:23"
        )
        XCTAssertEqual(
            bucketText(UsageBucket(id: "x", remaining: 0, resetTime: "2026-11-28T10:23:13Z"), now: now, timeZone: utc),
            "0% 11-28 10:23"
        )
        XCTAssertEqual(bucketText(UsageBucket(id: "x", remaining: 0.5, resetTime: ""), now: now, timeZone: utc), "50%")
        XCTAssertEqual(
            bucketText(fiveHour, now: now, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))),
            "62% 11-21 23:35"
        )
    }

    func testCellsAndAlignment() throws {
        let now = try XCTUnwrap(parseTimestamp("2026-11-21T10:00:00Z"))
        let pro = UsageSnapshot(
            planID: "g1-pro-tier",
            planName: "Google AI Pro",
            buckets: try XCTUnwrap(parseBuckets(Data(summaryJSON.utf8)))
        )
        let free = UsageSnapshot(planID: "free-tier", planName: "", buckets: [
            UsageBucket(id: "gemini-weekly", remaining: 1, resetTime: "2026-11-28T10:00:00Z"),
        ])
        XCTAssertEqual(
            usageText(pro, now: now, timeZone: utc),
            UsageText(plan: "Pro", fiveHour: "62% 11-21 15:35", weekly: "99% 11-28 10:23")
        )
        XCTAssertEqual(usageText(pro, now: now, timeZone: utc).cells, [
            "Pro",
            "5h 62% 11-21 15:35  7d 99% 11-28 10:23",
        ])
        let legacyWithArgon = UsageSnapshot(planID: "g1-pro-tier", planName: "Google AI Pro", buckets: [
            UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-11-21T15:35:35.5Z"),
            UsageBucket(id: "gemini-argon-wtu-weekly", remaining: 1, resetTime: "2026-11-28T10:35:35Z"),
        ])
        XCTAssertEqual(usageText(legacyWithArgon, now: now, timeZone: utc).cells, [
            "Pro",
            "5h 62% 11-21 15:35",
        ])
        XCTAssertEqual(
            usageText(free, now: now, timeZone: utc),
            UsageText(plan: "Free", weekly: "100%")
        )
        XCTAssertEqual(usageText(free, now: now, timeZone: utc).cells, ["Free", "7d 100%"])
        let ultra = UsageSnapshot(planID: "g1-ultra-tier", planName: "Google AI Ultra", buckets: [
            UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-11-21T15:35:35.5Z"),
            UsageBucket(id: "gemini-weekly", remaining: 1, resetTime: "2026-11-28T10:00:00Z"),
            UsageBucket(id: "3p-5h", remaining: 0.1, resetTime: "2026-11-21T15:35:35.5Z"),
        ], modelsLocked: false)
        let ultraText = usageText(ultra, now: now, timeZone: utc)
        XCTAssertEqual(ultraText.plan, "Ultra")
        XCTAssertEqual(ultraText.fiveHour, "62% 11-21 15:35")
        XCTAssertEqual(ultraText.weekly, "100%")
        XCTAssertFalse(ultraText.cells.joined().contains("3p"))
        let empty = UsageSnapshot(planID: "g1-pro-tier", planName: "Google AI Pro", buckets: [], modelsLocked: true)
        let hidden = usageText(empty, now: now, timeZone: utc) { "\($0)（非付费）" }
        XCTAssertEqual(hidden, UsageText(plan: "Pro（非付费）"))
        XCTAssertEqual(hidden.cells, ["Pro（非付费）"])
        let zero = UsageSnapshot(planID: "free-tier", planName: "", buckets: [
            UsageBucket(id: "gemini-weekly", remaining: 0, resetTime: "2026-11-28T10:23:13Z"),
        ])
        XCTAssertEqual(usageText(zero, now: now, timeZone: utc).weekly, "0% 11-28 10:23")
        var marked = pro
        marked.modelsLocked = true
        XCTAssertEqual(usageText(marked, now: now, timeZone: utc) { "\($0)（非付费）" }.plan, "Pro（非付费）")
        marked.modelsLocked = false
        XCTAssertEqual(usageText(marked, now: now, timeZone: utc) { "\($0)（非付费）" }.plan, "Pro")
        var starter = free
        starter.modelsLocked = true
        XCTAssertEqual(usageText(starter, now: now, timeZone: utc) { "\($0)（非付费）" }.plan, "Free")
        XCTAssertEqual(displayWidth("Pro（非付费）"), 13)
        XCTAssertEqual(alignedRows([["* a", "a@b.c", "Pro（非付费）", "5h 100%"], ["  b", "b@b.c", "Free", "5h —"]]), [
            "* a  a@b.c  Pro（非付费）  5h 100%",
            "  b  b@b.c  Free           5h —",
        ])

        XCTAssertEqual(alignedRows([["* alice", "alice@example.com"], ["  bo", "bo@example.com"]]), [
            "* alice  alice@example.com",
            "  bo  bo@example.com",
        ])
        XCTAssertEqual(
            alignedRows([
                ["* alice", "alice@example.com", "Pro", "5h 62% 11-21 15:35  7d 100%"],
                ["  bo", "bo@example.com", "Free", "7d 99% 11-28 10:23"],
                ["  carol", "carol@example.com"],
            ]),
            [
                "* alice  alice@example.com  Pro   5h 62% 11-21 15:35  7d 100%",
                "  bo     bo@example.com     Free  7d 99% 11-28 10:23",
                "  carol  carol@example.com",
            ]
        )
    }

    func testRecordRoundTripKeepsOnlyPlanAndBuckets() throws {
        let snapshot = UsageSnapshot(planID: "g1-pro-tier", planName: "Google AI Pro", buckets: [
            UsageBucket(id: "gemini-5h", remaining: 0.62, resetTime: "2026-11-21T15:35:35Z"),
        ])
        let text = encodeUsage(snapshot, email: "alice@example.com", fetchedAt: "2026-11-21T10:00:00Z")
        XCTAssertTrue(text.contains("\"fetched_at\""))
        XCTAssertEqual(decodeUsage(Data(text.utf8), email: "alice@example.com"), snapshot)
        XCTAssertFalse(text.contains("models_locked"))
        XCTAssertFalse(text.contains("argon_locked"))
        var locked = snapshot
        locked.modelsLocked = true
        let lockedText = encodeUsage(locked, email: "alice@example.com", fetchedAt: "2026-11-21T10:00:00Z")
        XCTAssertTrue(lockedText.contains("\"models_locked\""))
        XCTAssertFalse(lockedText.contains("argon_locked"))
        XCTAssertEqual(decodeUsage(Data(lockedText.utf8), email: "alice@example.com"), locked)
        let legacyLockedText = """
        {"email":"alice@example.com","fetched_at":"2026-11-21T10:00:00Z","plan_id":"g1-pro-tier","plan_name":"Google AI Pro","project":"","buckets":[{"id":"gemini-5h","remaining":0.62,"reset_time":"2026-11-21T15:35:35Z"}],"argon_locked":true}
        """
        XCTAssertEqual(decodeUsage(Data(legacyLockedText.utf8), email: "alice@example.com"), locked)
        XCTAssertNil(decodeUsage(Data(text.utf8), email: "bob@example.com"))
        XCTAssertNil(decodeUsage(Data("[]".utf8), email: "alice@example.com"))
    }

    func testClientSecretsAreFoundInsideABinary() {
        let first = fakeSecret("a")
        let second = fakeSecret("b")
        var bytes = Data("junk".utf8)
        bytes.append(Data(first.utf8))
        bytes.append(Data("cloudcode".utf8))
        bytes.append(Data((marker + "short").utf8))
        bytes.append(Data([0, 1, 2]))
        bytes.append(Data(second.utf8))
        bytes.append(Data(first.utf8))
        bytes.append(Data((marker + String(repeating: "!", count: 28)).utf8))
        let found = clientSecrets(in: bytes)
        XCTAssertEqual(found.map(\.value), [first, second])
        XCTAssertEqual(found.first?.offset, 4)
        XCTAssertTrue(clientSecrets(in: Data()).isEmpty)
    }

    func testFetchFindsTheWorkingSecretOnceAndAsksAsAgy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrong = fakeSecret("w")
        let right = fakeSecret("r")
        let binary = directory.appendingPathComponent("agy")
        try Data(("head" + wrong + "middle" + right + "tail").utf8).write(to: binary)
        let cache = directory.appendingPathComponent("agy-client.json")
        var versionCalls = 0
        var signed = false
        let client = AgyClient(cacheURL: cache, locate: { _ in binary.path }, trusted: { _ in signed }, versionOf: { _ in
            versionCalls += 1
            return "9.9.9"
        })
        let http = ScriptedHTTP(rightSecret: right, plan: planJSON, summary: summaryJSON)
        let usage = CloudCodeUsage(http: http, client: client)
        let logins = [(name: "alice", blob: blob(refresh: "1//alice")), (name: "bob", blob: blob(refresh: "1//bob"))]

        XCTAssertTrue(usage.fetch(logins).isEmpty)
        XCTAssertEqual(versionCalls, 0)
        XCTAssertTrue(http.requests.isEmpty)
        signed = true
        XCTAssertTrue(CloudCodeUsage(http: http, client: client, budget: 0).fetch(logins).isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
        versionCalls = 0
        XCTAssertFalse(isGoogleSigned(binary.path))
        XCTAssertFalse(isGoogleSigned("/bin/ls"))

        let fetched = usage.fetch(logins)
        XCTAssertEqual(Set(fetched.keys), ["alice", "bob"])
        XCTAssertEqual(fetched["alice"]?.planID, "g1-pro-tier")
        XCTAssertEqual(fetched["alice"]?.buckets.count, 4)
        XCTAssertEqual(http.tokenSecrets.filter { $0 == wrong }.count, 1)
        XCTAssertEqual(http.tokenSecrets.count, 3)
        XCTAssertEqual(http.warmed.map(\.host), ["daily-cloudcode-pa.googleapis.com"])
        let asked = http.requests.filter { $0.url.host == "daily-cloudcode-pa.googleapis.com" }
        XCTAssertEqual(asked.count, 6)
        XCTAssertEqual(asked.filter { $0.url.absoluteString.hasSuffix(":fetchAvailableModels") }.count, 2)
        XCTAssertEqual(fetched["alice"]?.modelsLocked, true)
        for request in asked {
            XCTAssertTrue(request.headers["User-Agent"]?.hasPrefix("antigravity/cli/9.9.9 (aidev_client; os_type=darwin; arch=") == true)
            XCTAssertTrue(request.headers["Authorization"]?.hasPrefix("Bearer access-1//") == true)
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("1//"))
        }
        XCTAssertTrue(asked.contains { String(decoding: $0.body, as: UTF8.self).contains("project-1") })
        for request in http.requests {
            XCTAssertEqual(request.url.scheme, "https")
            XCTAssertFalse(request.url.absoluteString.contains("1//"))
        }

        let saved = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertFalse(saved.contains(right))
        XCTAssertFalse(saved.contains(marker))
        XCTAssertTrue(saved.contains("9.9.9"))
        XCTAssertEqual(usage.fetch(logins).count, 2)
        XCTAssertEqual(http.tokenSecrets.filter { $0 == wrong }.count, 1)
        XCTAssertEqual(versionCalls, 1)
        XCTAssertEqual(fetched["alice"]?.project, "project-1")
        XCTAssertEqual(client.resolve(scan: false)?.secrets.map(\.value), [right])
        XCTAssertEqual(client.resolve(scan: false)?.remembered, true)
        XCTAssertEqual(client.resolve()?.secrets.count, 2)

        // 记着的 project 对得上时不多发请求；对不上时按套餐回答里的再问一次额度。
        func cloudCalls() -> Int {
            http.requests.filter { $0.url.host == "daily-cloudcode-pa.googleapis.com" }.count
        }
        var before = cloudCalls()
        XCTAssertEqual(usage.fetch([logins[0]], project: "project-1")["alice"]?.buckets.count, 4)
        XCTAssertEqual(cloudCalls() - before, 3)
        before = cloudCalls()
        XCTAssertEqual(usage.fetch([logins[0]], project: "stale")["alice"]?.buckets.count, 4)
        XCTAssertEqual(cloudCalls() - before, 4)
        let corrected = http.requests.suffix(4)
            .filter { $0.url.absoluteString.hasSuffix(":retrieveUserQuotaSummary") }
            .map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertEqual(corrected.count, 2)
        XCTAssertTrue(corrected.contains { $0.contains("stale") })
        XCTAssertTrue(corrected.contains { $0.contains("project-1") })

        // 记着的 secret 不再可用时，重新找一遍并记下新的。
        http.rightSecret = wrong
        XCTAssertEqual(usage.fetch(logins).count, 2)
        XCTAssertEqual(client.resolve(scan: false)?.secrets.map(\.value), [wrong])
        http.rightSecret = right
        XCTAssertEqual(usage.fetch(logins).count, 2)
        signed = false
        XCTAssertEqual(usage.fetch(logins).count, 2)

        XCTAssertEqual(usage.fetch([(name: "gone", blob: blob(refresh: "revoked")), logins[0]]).keys.sorted(), ["alice"])
        http.summaryStatus = 403
        XCTAssertEqual(usage.fetch([logins[0]])["alice"], UsageSnapshot(planID: "g1-pro-tier", planName: "Google AI Pro", buckets: [], modelsLocked: true, project: "project-1"))
        http.modelsStatus = 500
        http.summaryStatus = 200
        XCTAssertEqual(usage.fetch([logins[0]])["alice"]?.buckets.count, 4)
        XCTAssertNil(usage.fetch([logins[0]])["alice"]?.modelsLocked)
        http.summaryStatus = 500
        XCTAssertTrue(usage.fetch([logins[0]]).isEmpty)
        http.offline = true
        XCTAssertTrue(usage.fetch(logins).isEmpty)
        XCTAssertTrue(usage.fetch([(name: "plain", blob: "plain")]).isEmpty)
        XCTAssertTrue(
            CloudCodeUsage(http: http, client: AgyClient(cacheURL: cache, locate: { _ in nil }, trusted: { _ in true }, versionOf: { _ in "1" })).fetch(logins).isEmpty
        )
    }

    func testClientRemembersWhereAgyIsAndLooksThereWhenPathHasNone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let elsewhere = directory.appendingPathComponent("else where", isDirectory: true)
        let usual = home.appendingPathComponent(".local/bin", isDirectory: true)
        for folder in [elsewhere, usual] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        func install(_ folder: URL) throws -> String {
            let binary = folder.appendingPathComponent("agy")
            try Data(("head" + fakeSecret("s") + "tail").utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            return binary.path
        }
        let recorded = try install(elsewhere)
        // 被系统打开的菜单栏进程只有这四个目录。
        let bare = "/usr/bin:/bin:/usr/sbin:/sbin"
        XCTAssertEqual(agyBinary(path: bare + ":" + elsewhere.path, recorded: nil, home: home), recorded)
        XCTAssertEqual(agyBinary(path: bare, recorded: recorded, home: home), recorded)
        let fallback = try install(usual)
        XCTAssertEqual(agyBinary(path: bare, recorded: recorded, home: home), recorded)
        XCTAssertEqual(agyBinary(path: bare, recorded: nil, home: home), fallback)
        XCTAssertEqual(agyBinary(path: bare, recorded: elsewhere.path + "/missing", home: home), fallback)
        XCTAssertEqual(agyBinary(path: bare, recorded: "agy", home: home), fallback)

        let cache = directory.appendingPathComponent("agy-client.json")
        var asked: [String?] = []
        let client = AgyClient(cacheURL: cache, locate: { known in
            asked.append(known)
            return agyBinary(path: bare, recorded: known ?? recorded, home: home)
        }, trusted: { _ in true }, versionOf: { _ in "1.2.3" })
        let identity = try XCTUnwrap(client.resolve())
        client.remember(identity, secretOffset: try XCTUnwrap(identity.secrets.first).offset)
        let resolved = (recorded as NSString).resolvingSymlinksInPath
        XCTAssertEqual(client.resolve(scan: false)?.path, resolved)
        XCTAssertEqual(asked.count, 2)
        XCTAssertNil(asked[0])
        XCTAssertEqual(asked[1], resolved)
        let saved = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertFalse(saved.contains(marker))

        // 以前的记录里没有位置：下一次读到时补上。
        func record() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        }
        var older = try record()
        older["path"] = nil
        try JSONSerialization.data(withJSONObject: older).write(to: cache)
        XCTAssertEqual(client.resolve(scan: false)?.remembered, true)
        XCTAssertEqual(try record()["path"] as? String, resolved)
        XCTAssertEqual(try record()["secret_offset"] as? Int, identity.secrets.first?.offset)
    }

    func testSpawnerHandsOffWithoutWaitingForTheWorker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = directory.appendingPathComponent("calls")
        let script = directory.appendingPathComponent("fake-agy-cs")
        let lines = [
            "#!/bin/sh",
            "case \"$*\" in *detach*) ;; *) sleep 1 ;; esac",
            "echo \"$* tty=$(test -t 0 && echo yes || echo no) leader=$(test \"$(ps -o pgid= -p $$ | tr -d ' ')\" = $$ && echo yes || echo no)\" >> '\(calls.path)'",
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let spawner = SelfSpawner(executable: script.path)

        spawner.startDetached()
        let handed = try String(contentsOf: calls, encoding: .utf8)
        XCTAssertEqual(handed, "refresh quota --detach tty=no leader=no\n")

        let started = Date()
        spawner.spawnWorker()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        var seen = handed
        for _ in 0 ..< 60 where !seen.contains("refresh quota tty=no") {
            usleep(100_000)
            seen = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        }
        XCTAssertEqual(seen, handed + "refresh quota tty=no leader=yes\n")
        SelfSpawner(executable: directory.appendingPathComponent("missing").path).startDetached()
    }

    func testLiveUsageFetchWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["AGY_USAGE_LIVE"] == "1" else {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = AccountFiles(locations: AccountLocations(home: home), now: { "" })
        let logins = files.savedNames().compactMap { name in
            (try? files.readSaved(name)).map { (name: name, blob: $0.blob) }
        }
        XCTAssertFalse(logins.isEmpty)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let started = Date()
        XCTAssertTrue(isGoogleSigned(try agyExecutable()))
        let fetched = CloudCodeUsage(client: AgyClient(cacheURL: cache)).fetch(logins.map { (name: $0.name, blob: $0.blob, project: "") }, within: 10)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        XCTAssertEqual(fetched.count, logins.count)
        for (index, login) in logins.enumerated() {
            let snapshot = try XCTUnwrap(fetched[login.name])
            XCTAssertFalse(snapshot.planID.isEmpty)
            print("LIVE usage account \(index + 1): plan=\(planLabel(id: snapshot.planID, name: snapshot.planName)) modelsLocked=\(String(describing: snapshot.modelsLocked)) buckets=\(snapshot.buckets.map(\.id))")
        }
        print("LIVE usage: \(logins.count) accounts in \(seconds)s, cold cache")
    }

    private let marker = "GOCSPX" + "-"

    private func fakeSecret(_ letter: Character) -> String {
        marker + String(repeating: letter, count: 28)
    }

    private func blob(refresh: String) -> String {
        let object: [String: Any] = [
            "id_token_email": "someone@example.com",
            "auth_method": "consumer",
            "token": ["refresh_token": refresh, "access_token": "old", "expiry": "2026-01-01T00:00:00Z"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "go-keyring-base64:" + data.base64EncodedString()
    }

    private let planJSON = """
    {"currentTier":{"id":"free-tier","name":"Antigravity"},"cloudaicompanionProject":"project-1",\
    "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro","availableCredits":[{"creditType":"GOOGLE_ONE_AI"}]}}
    """

    private let summaryJSON = """
    {"groups":[\
    {"displayName":"Gemini Models","buckets":[\
    {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-11-28T10:23:13Z","remainingFraction":0.9962848},\
    {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-11-21T15:35:35.5Z","remainingFraction":0.62}]},\
    {"displayName":"Claude and GPT models","buckets":[\
    {"bucketId":"3p-weekly","window":"weekly","resetTime":"2026-11-28T10:36:28Z","remainingFraction":1},\
    {"bucketId":"3p-5h","window":"5h","resetTime":"2026-11-21T15:35:35Z","remainingFraction":1},\
    {"bucketId":"switched-off","disabled":true,"remainingFraction":1}]}]}
    """
}

private extension CloudCodeUsage {
    func fetch(_ logins: [(name: String, blob: String)], project: String = "") -> [String: UsageSnapshot] {
        fetch(logins.map { (name: $0.name, blob: $0.blob, project: project) }, within: budget)
    }
}

private final class ScriptedHTTP: HTTPPosting {
    var requests: [HTTPRequest] = []
    var tokenSecrets: [String] = []
    var offline = false
    var summaryStatus = 200
    var modelsStatus = 200
    var warmed: [URL] = []

    func warm(_ url: URL) {
        lock.lock()
        warmed.append(url)
        lock.unlock()
    }
    var rightSecret: String
    private let plan: String
    private let summary: String
    private let lock = NSLock()

    init(rightSecret: String, plan: String, summary: String) {
        self.rightSecret = rightSecret
        self.plan = plan
        self.summary = summary
    }

    func post(_ request: HTTPRequest) -> HTTPResponse? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if offline {
            return nil
        }
        switch request.url.absoluteString {
        case "https://oauth2.googleapis.com/token":
            var fields: [String: String] = [:]
            for pair in String(decoding: request.body, as: UTF8.self).split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : ""
            }
            tokenSecrets.append(fields["client_secret"] ?? "")
            guard fields["client_secret"] == rightSecret else {
                return HTTPResponse(status: 401, body: Data(#"{"error":"invalid_client"}"#.utf8))
            }
            guard let refresh = fields["refresh_token"], refresh != "revoked" else {
                return HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return HTTPResponse(status: 200, body: Data(#"{"access_token":"access-\#(refresh)","expires_in":3599}"#.utf8))
        case "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist":
            return HTTPResponse(status: 200, body: Data(plan.utf8))
        case "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary":
            return HTTPResponse(status: summaryStatus, body: Data(summary.utf8))
        case "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels":
            return HTTPResponse(status: modelsStatus, body: Data(#"{"models":{"gemini-4-carbon-disabled":{"disabled":true},"gemini-4-neon-disabled":{"disabled":true},"gemini-4-hydrogen-sonar":{"recommended":true}}}"#.utf8))
        default:
            return HTTPResponse(status: 404, body: Data())
        }
    }
}
