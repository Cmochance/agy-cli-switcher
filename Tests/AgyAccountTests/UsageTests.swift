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
        XCTAssertNil(parsePlan(Data("nope".utf8)))

        let buckets = try XCTUnwrap(parseBuckets(Data(summaryJSON.utf8)))
        XCTAssertEqual(buckets.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly", "gemini-argon-wtu-weekly"])
        XCTAssertEqual(buckets[0], UsageBucket(id: "gemini-weekly", remaining: 0.9962848, resetTime: "2026-11-28T10:23:13Z"))
        XCTAssertEqual(buckets[1].remaining, 0.62)
        XCTAssertEqual(parseBuckets(Data("{}".utf8)), [])
        XCTAssertNil(parseBuckets(Data("nope".utf8)))
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
        XCTAssertEqual(usageCells(pro, now: now, timeZone: utc), ["Pro", "5h 62% 11-21 15:35", "7d 99% 11-28 10:23", "Argon 100%"])
        XCTAssertEqual(usageCells(free, now: now, timeZone: utc), ["Free", "5h —", "7d 100%", "Argon —"])

        XCTAssertEqual(alignedRows([["* alice", "alice@example.com"], ["  bo", "bo@example.com"]]), [
            "* alice  alice@example.com",
            "  bo  bo@example.com",
        ])
        XCTAssertEqual(
            alignedRows([
                ["* alice", "alice@example.com", "Pro", "5h 62% 11-21 15:35", "7d 100%", "Argon 100%"],
                ["  bo", "bo@example.com", "Free", "5h —", "7d 99% 11-28 10:23", "Argon —"],
                ["  carol", "carol@example.com"],
            ]),
            [
                "* alice  alice@example.com  Pro   5h 62% 11-21 15:35  7d 100%             Argon 100%",
                "  bo     bo@example.com     Free  5h —                7d 99% 11-28 10:23  Argon —",
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
        let client = AgyClient(cacheURL: cache, locate: { binary.path }, trusted: { _ in signed }, versionOf: { _ in
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
        let asked = http.requests.filter { $0.url.host == "daily-cloudcode-pa.googleapis.com" }
        XCTAssertEqual(asked.count, 4)
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
        signed = false
        XCTAssertEqual(usage.fetch(logins).count, 2)

        XCTAssertEqual(usage.fetch([(name: "gone", blob: blob(refresh: "revoked")), logins[0]]).keys.sorted(), ["alice"])
        http.summaryStatus = 403
        XCTAssertEqual(usage.fetch([logins[0]])["alice"], UsageSnapshot(planID: "g1-pro-tier", planName: "Google AI Pro", buckets: []))
        http.summaryStatus = 500
        XCTAssertTrue(usage.fetch([logins[0]]).isEmpty)
        http.offline = true
        XCTAssertTrue(usage.fetch(logins).isEmpty)
        XCTAssertTrue(usage.fetch([(name: "plain", blob: "plain")]).isEmpty)
        XCTAssertTrue(
            CloudCodeUsage(http: http, client: AgyClient(cacheURL: cache, locate: { nil }, trusted: { _ in true }, versionOf: { _ in "1" })).fetch(logins).isEmpty
        )
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
        let fetched = CloudCodeUsage(client: AgyClient(cacheURL: cache)).fetch(logins)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        XCTAssertEqual(fetched.count, logins.count)
        for (index, login) in logins.enumerated() {
            let snapshot = try XCTUnwrap(fetched[login.name])
            XCTAssertFalse(snapshot.planID.isEmpty)
            print("LIVE usage account \(index + 1): plan=\(planLabel(id: snapshot.planID, name: snapshot.planName)) buckets=\(snapshot.buckets.map(\.id))")
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
    {"bucketId":"3p-weekly","window":"weekly","resetTime":"2026-11-28T10:36:28Z","remainingFraction":1}]},\
    {"displayName":"Gemini 4 Argon","buckets":[\
    {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","resetTime":"2026-11-28T10:35:35Z","remainingFraction":1},\
    {"bucketId":"switched-off","disabled":true,"remainingFraction":1}]}]}
    """
}

private final class ScriptedHTTP: HTTPPosting {
    var requests: [HTTPRequest] = []
    var tokenSecrets: [String] = []
    var offline = false
    var summaryStatus = 200
    private let rightSecret: String
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
        default:
            return HTTPResponse(status: 404, body: Data())
        }
    }
}
