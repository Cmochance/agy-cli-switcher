import Foundation
import SQLite3
import XCTest
@testable import AgyAccount

final class UsageAnalyticsTests: XCTestCase {
    func testPricingCatalogStandardPromoAndOrchestrator() {
        let rates = PricingCatalog.baselineRates
        let promoTime = parseTimestamp("2026-11-24T12:00:00Z")!.timeIntervalSince1970 * 1000.0
        let postPromoTime = parseTimestamp("2026-12-02T12:00:00Z")!.timeIntervalSince1970 * 1000.0

        let promoCost = PricingCatalog.estimateCost(
            model: "Gemini 4 Carbon (High)",
            role: .none,
            inputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            outputTokens: 1_000_000,
            timestampMs: promoTime,
            rates: rates,
            mode: .promo
        )
        XCTAssertEqual(promoCost ?? -1, 12.1, accuracy: 1e-6)

        let standardCost = PricingCatalog.estimateCost(
            model: "Gemini 4 Carbon (High)",
            role: .none,
            inputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            outputTokens: 1_000_000,
            timestampMs: promoTime,
            rates: rates,
            mode: .standard
        )
        XCTAssertEqual(standardCost ?? -1, 24.2, accuracy: 1e-6)

        let postPromo = PricingCatalog.estimateCost(
            model: "Gemini 4 Carbon (High)",
            role: .none,
            inputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            outputTokens: 1_000_000,
            timestampMs: postPromoTime,
            rates: rates,
            mode: .promo
        )
        XCTAssertEqual(postPromo ?? -1, 24.2, accuracy: 1e-6)

        let orchExec = PricingCatalog.estimateCost(
            model: "Orchestrator (Neon)",
            role: .execution,
            inputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            outputTokens: 1_000_000,
            timestampMs: promoTime,
            rates: rates,
            mode: .standard
        )
        XCTAssertEqual(orchExec ?? -1, 9.075, accuracy: 1e-6)

        XCTAssertNil(PricingCatalog.estimateCost(
            model: "unknown-experimental-model",
            role: .none,
            inputTokens: 1_000,
            cacheReadTokens: 0,
            outputTokens: 100,
            timestampMs: promoTime,
            rates: rates,
            mode: .standard
        ))
    }

    func testDeduplicationArchiveWeeklyWindowAndAccountTimeline() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-analytics-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let alice = makeBlob(email: "alice@example.com", refresh: "ra")
        let bob = makeBlob(email: "bob@example.com", refresh: "rb")
        let keychain = MemoryKeychain(alice)

        let t1 = Int64(parseTimestamp("2026-11-24T10:00:00Z")!.timeIntervalSince1970 * 1000.0)
        let t2 = Int64(parseTimestamp("2026-11-25T10:00:00Z")!.timeIntervalSince1970 * 1000.0)
        var currentClock = "2026-11-24T09:00:00Z"

        func run(_ args: [String]) -> Int32 {
            AgyAccountCLI.run(
                args,
                home: home,
                keychain: keychain,
                processes: FixedProcesses(),
                now: { currentClock },
                preferredLanguages: ["zh-Hans"],
                terminal: ScriptedTerminal(),
                launcher: ScriptedLauncher(),
                usage: ScriptedUsage(),
                refresher: ScriptedRefresher(),
                environment: [:],
                stdout: { _ in },
                stderr: { _ in }
            )
        }

        XCTAssertEqual(run(["save", "alice"]), 0)
        currentClock = "2026-11-25T09:00:00Z"
        keychain.blob = bob
        XCTAssertEqual(run(["save", "bob"]), 0)
        XCTAssertEqual(run(["switch", "bob"]), 0)

        // Write weekly usage snapshot for bob (reset at 2026-11-30T10:00:00Z -> window starts 2026-11-23T10:00:00Z).
        let profile = ToolProfile(home: home, now: { currentClock }, preferredLanguages: ["zh-Hans"], provider: .antigravity)
        try profile.writeUsage(
            "bob",
            UsageSnapshot(
                planID: "g1-pro-tier",
                planName: "Google AI Pro",
                buckets: [
                    UsageBucket(id: "gemini-weekly", remaining: 0.90, resetTime: "2026-11-30T10:00:00Z"),
                    UsageBucket(id: "3p-weekly", remaining: 0.95, resetTime: "2026-12-01T10:00:00Z"),
                ]
            ),
            email: "bob@example.com"
        )

        let cliConvDir = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        let appConvDir = home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)

        // Seed duplicate req-1 across CLI & App, plus req-2 (error) for bob.
        let cliDB = cliConvDir.appendingPathComponent("c-dup.db")
        try SQLiteTestBuilder.createConversationDB(at: cliDB) { db in
            let g1 = ProtobufEncoder.makeGeneration(
                requestId: "req-dup-1",
                model: "Gemini 4 Carbon (High)",
                input: 1_000,
                cache: 3_000,
                output: 200,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [1]
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g1)
            try SQLiteTestBuilder.insertStep(
                db,
                idx: 1,
                stepType: 2,
                status: 3,
                metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t1 / 1000))
            )
        }
        let appDB = appConvDir.appendingPathComponent("c-dup.db")
        try SQLiteTestBuilder.createConversationDB(at: appDB) { db in
            let g1 = ProtobufEncoder.makeGeneration(
                requestId: "req-dup-1",
                model: "Gemini 4 Carbon (High)",
                input: 1_000,
                cache: 3_000,
                output: 200,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [1]
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g1)
            try SQLiteTestBuilder.insertStep(
                db,
                idx: 1,
                stepType: 2,
                status: 3,
                metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t1 / 1000))
            )
        }

        let bobDB = cliConvDir.appendingPathComponent("c-bob.db")
        try SQLiteTestBuilder.createConversationDB(at: bobDB) { db in
            let g2 = ProtobufEncoder.makeGeneration(
                requestId: "req-bob-2",
                model: "Claude Opus 5.5",
                input: 2_000,
                cache: 8_000,
                output: 500,
                ttftSeconds: 1,
                streamingSeconds: 4,
                stepIndices: [1],
                error: "rate limited"
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g2)
            try SQLiteTestBuilder.insertStep(
                db,
                idx: 1,
                stepType: 2,
                status: 3,
                metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t2 / 1000))
            )
        }

        let now = parseTimestamp("2026-11-26T12:00:00Z")!
        let allSnap = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            now: now
        )
        XCTAssertEqual(allSnap.totalRequests, 2)
        XCTAssertEqual(allSnap.successCount, 1)
        XCTAssertEqual(allSnap.errorCount, 1)
        XCTAssertEqual(allSnap.heatmapCells.count, 371)
        XCTAssertEqual(allSnap.sparkline.count, 32)
        XCTAssertEqual(allSnap.models.count, 2)

        // Delete bob's DB and verify 90-day archive retains req-bob-2!
        try FileManager.default.removeItem(at: bobDB)
        let bobWeekly = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .weekly,
            accountFilter: "bob",
            now: now
        )
        XCTAssertEqual(bobWeekly.accountFilter, "bob@example.com")
        XCTAssertEqual(bobWeekly.totalRequests, 1)
        XCTAssertEqual(bobWeekly.errorCount, 1)

        // Test stats/statusbar CLI with NoKeychain (0 keychain reads) & Colab rejection (exit 2).
        let exploding = NoKeychain()
        let out = Capture()
        let err = Capture()
        let statsCode = AgyAccountCLI.run(
            ["stats", "--range", "all", "--account", "all", "--json"],
            home: home,
            keychain: exploding,
            processes: FixedProcesses(),
            now: { "2026-11-26T12:00:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: ScriptedTerminal(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher(),
            environment: [:],
            clock: { now },
            stdout: { out.output.append($0) },
            stderr: { err.errors.append($0) }
        )
        XCTAssertEqual(statsCode, 0)
        XCTAssertEqual(exploding.reads, 0)
        let decoded = try JSONDecoder().decode(UsageOverviewSnapshot.self, from: Data(out.output.joined(separator: "\n").utf8))
        XCTAssertEqual(decoded.totalRequests, 2)

        XCTAssertEqual(AgyAccountCLI.run(
            ["statusbar", "on"],
            home: home,
            keychain: exploding,
            processes: FixedProcesses(),
            now: { "2026-11-26T12:00:00Z" },
            terminal: ScriptedTerminal(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher(),
            stdout: { _ in },
            stderr: { _ in }
        ), 0)
        XCTAssertTrue(profile.statusTelemetryEnabled())
        XCTAssertEqual(exploding.reads, 0)

        let colabInit = home.appendingPathComponent(".agy-cs/colab/initialized")
        try FileManager.default.createDirectory(at: colabInit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: colabInit)
        let colabServices = ProviderServices(
            keychain: exploding,
            codec: ColabLoginCodec(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        for subcommand in ["stats", "session", "statusbar"] {
            XCTAssertEqual(AgyAccountCLI.run(
                ["colab", subcommand],
                home: home,
                keychain: exploding,
                processes: FixedProcesses(),
                now: { "2026-11-26T12:00:00Z" },
                terminal: ScriptedTerminal(),
                launcher: ScriptedLauncher(),
                usage: ScriptedUsage(),
                refresher: ScriptedRefresher(),
                colab: colabServices,
                stdout: { _ in },
                stderr: { _ in }
            ), 2)
        }
        XCTAssertEqual(exploding.reads, 0)
    }

    func testSourceFilterIsolatesArchiveAndPreservesOppositeDBCache() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-source-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let t1 = Int64(parseTimestamp("2026-11-25T10:00:00Z")!.timeIntervalSince1970 * 1000.0)
        let t2 = Int64(parseTimestamp("2026-11-25T11:00:00Z")!.timeIntervalSince1970 * 1000.0)
        let cliConvDir = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        let appConvDir = home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)

        let cliDB = cliConvDir.appendingPathComponent("c-cli.db")
        try SQLiteTestBuilder.createConversationDB(at: cliDB) { db in
            let g = ProtobufEncoder.makeGeneration(
                requestId: "req-cli-only",
                model: "Gemini 4 Carbon (High)",
                input: 1_000,
                cache: 2_000,
                output: 100,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [1]
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g)
            try SQLiteTestBuilder.insertStep(db, idx: 1, stepType: 2, status: 3, metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t1 / 1000)))
        }
        let appDB = appConvDir.appendingPathComponent("c-app.db")
        try SQLiteTestBuilder.createConversationDB(at: appDB) { db in
            let g = ProtobufEncoder.makeGeneration(
                requestId: "req-app-only",
                model: "Claude Opus 5.5",
                input: 1_500,
                cache: 3_500,
                output: 200,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [1]
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g)
            try SQLiteTestBuilder.insertStep(db, idx: 1, stepType: 2, status: 3, metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t2 / 1000)))
        }

        let profile = ToolProfile(home: home, now: { "2026-11-26T12:00:00Z" }, preferredLanguages: ["zh-Hans"], provider: .antigravity)
        let now = parseTimestamp("2026-11-26T12:00:00Z")!
        let reader = AntigravityDatabaseReader()

        let allSnap = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            sourceFilter: .all,
            now: now,
            reader: reader
        )
        XCTAssertEqual(allSnap.totalRequests, 2)

        let cliSnap = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            sourceFilter: .cli,
            now: now,
            reader: reader
        )
        XCTAssertEqual(cliSnap.totalRequests, 1)
        XCTAssertEqual(cliSnap.models.map(\.modelId), ["gemini-4-carbon"])

        // Confirm telemetry-db-cache.json did NOT wipe c-app.db when scanning --source cli.
        let cacheURL = ToolLocations(home: home, provider: .antigravity).telemetryCacheFile
        let cacheRaw = try Data(contentsOf: cacheURL)
        let cacheDict = try XCTUnwrap(JSONSerialization.jsonObject(with: cacheRaw) as? [String: Any])
        XCTAssertTrue(cacheDict.keys.contains(where: { $0.hasSuffix("/c-cli.db") }))
        XCTAssertTrue(cacheDict.keys.contains(where: { $0.hasSuffix("/c-app.db") }))

        // Delete c-app.db and confirm --source app recovers it from archive while --source cli stays isolated.
        try FileManager.default.removeItem(at: appDB)
        let appArchivedSnap = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            sourceFilter: .app,
            now: now,
            reader: reader
        )
        XCTAssertEqual(appArchivedSnap.totalRequests, 1)
        XCTAssertEqual(appArchivedSnap.models.map(\.modelId), ["claude-opus-5-5"])

        let cliAfterDeleteSnap = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            sourceFilter: .cli,
            now: now,
            reader: reader
        )
        XCTAssertEqual(cliAfterDeleteSnap.totalRequests, 1)
        XCTAssertEqual(cliAfterDeleteSnap.models.map(\.modelId), ["gemini-4-carbon"])
    }

    func testBusyWALDatabaseDoesNotPoisonCacheOrArchive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-busy-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let t1 = Int64(parseTimestamp("2026-11-25T10:00:00Z")!.timeIntervalSince1970 * 1000.0)
        let t2 = Int64(parseTimestamp("2026-11-25T11:00:00Z")!.timeIntervalSince1970 * 1000.0)
        let cliDB = home.appendingPathComponent(".gemini/antigravity-cli/conversations/c-busy.db")
        try SQLiteTestBuilder.createConversationDB(at: cliDB) { db in
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
            let g1 = ProtobufEncoder.makeGeneration(
                requestId: "req-busy-1",
                model: "Gemini 4 Carbon (High)",
                input: 1_000,
                cache: 2_000,
                output: 100,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [1]
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g1)
            try SQLiteTestBuilder.insertStep(db, idx: 1, stepType: 2, status: 3, metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t1 / 1000)))
        }

        let profile = ToolProfile(home: home, now: { "2026-11-26T12:00:00Z" }, preferredLanguages: ["zh-Hans"], provider: .antigravity)
        let now = parseTimestamp("2026-11-26T12:00:00Z")!
        let reader = AntigravityDatabaseReader()

        let initial = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            now: now,
            reader: reader
        )
        XCTAssertEqual(initial.totalRequests, 1)

        // Hold an EXCLUSIVE lock while writing a second generation into WAL so the DB stamp changes and readers hit SQLITE_BUSY.
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(cliDB.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer {
            if let writer {
                _ = sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
                sqlite3_close_v2(writer)
            }
        }
        let lockedDB = try XCTUnwrap(writer)
        XCTAssertEqual(sqlite3_exec(lockedDB, "PRAGMA locking_mode = EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lockedDB, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        let g2 = ProtobufEncoder.makeGeneration(
            requestId: "req-busy-2",
            model: "Gemini 4 Carbon (High)",
            input: 2_000,
            cache: 3_000,
            output: 200,
            ttftSeconds: 1,
            streamingSeconds: 2,
            stepIndices: [2]
        )
        try SQLiteTestBuilder.insertGeneration(lockedDB, idx: 1, data: g2)
        try SQLiteTestBuilder.insertStep(lockedDB, idx: 2, stepType: 2, status: 3, metadata: ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, t2 / 1000)))

        // Reader must fail cleanly (nil) rather than returning empty or falling back to ?immutable=1 on an active WAL DB.
        XCTAssertNil(reader.readConversationDatabase(at: cliDB, force: true))

        // Overview must still serve the preserved archive entry instead of wiping it.
        let duringLock = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            now: now,
            reader: reader
        )
        XCTAssertEqual(duringLock.totalRequests, 1)

        // Once committed, the fresh read succeeds and picks up both requests.
        XCTAssertEqual(sqlite3_exec(lockedDB, "COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(lockedDB)
        writer = nil

        let afterCommit = UsageAnalyticsEngine.loadOverview(
            home: home,
            profile: profile,
            environment: [:],
            range: .all,
            accountFilter: "all",
            now: now,
            reader: reader
        )
        XCTAssertEqual(afterCommit.totalRequests, 2)
    }

    func testTelemetryCommandsSkipFirstRunInitAndKeychainOnFreshHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-fresh-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let exploding = NoKeychain()
        let colabServices = ProviderServices(
            keychain: exploding,
            codec: ColabLoginCodec(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher()
        )
        let now = parseTimestamp("2026-11-26T12:00:00Z")!

        func invoke(_ args: [String]) -> (code: Int32, out: [String], err: [String]) {
            let out = Capture()
            let err = Capture()
            let code = AgyAccountCLI.run(
                args,
                home: home,
                keychain: exploding,
                processes: FixedProcesses(),
                now: { "2026-11-26T12:00:00Z" },
                preferredLanguages: ["zh-Hans"],
                terminal: ScriptedTerminal(),
                launcher: ScriptedLauncher(),
                usage: ScriptedUsage(),
                refresher: ScriptedRefresher(),
                colab: colabServices,
                environment: [:],
                clock: { now },
                stdout: { out.output.append($0) },
                stderr: { err.errors.append($0) }
            )
            return (code, out.output, err.errors)
        }

        // Fresh home without .agy-cs/initialized: --json output must be pure JSON with 0 keychain reads.
        let statsRes = invoke(["stats", "--json"])
        XCTAssertEqual(statsRes.code, 0)
        _ = try JSONDecoder().decode(UsageOverviewSnapshot.self, from: Data(statsRes.out.joined(separator: "\n").utf8))

        let sessionRes = invoke(["session", "--json"])
        XCTAssertEqual(sessionRes.code, 0)
        XCTAssertEqual(sessionRes.out.joined(separator: "\n"), "{}")

        let barRes = invoke(["statusbar"])
        XCTAssertEqual(barRes.code, 0)

        // Fresh home without .agy-cs/colab/initialized: colab telemetry must exit 2 with 0 keychain reads & no colab dir.
        for subcommand in ["stats", "session", "statusbar"] {
            let res = invoke(["colab", subcommand])
            XCTAssertEqual(res.code, 2)
        }
        XCTAssertEqual(exploding.reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agy-cs/initialized").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agy-cs/colab").path))
    }

    func testAtomicFileConcurrentWritesDoNotCorruptOrFail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-atomic-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("cache.json")
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [Error] = []

        for worker in 0 ..< 8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                for iter in 0 ..< 25 {
                    let payload = "{\"worker\":\(worker),\"iter\":\(iter)}\n"
                    do {
                        try AtomicFile.write(target, payload)
                    } catch {
                        lock.lock()
                        failures.append(error)
                        lock.unlock()
                    }
                }
            }
        }
        group.wait()
        XCTAssertTrue(failures.isEmpty, "Unexpected concurrent AtomicFile.write errors: \(failures)")
        let finalData = try Data(contentsOf: target)
        let decoded = try JSONSerialization.jsonObject(with: finalData) as? [String: Int]
        XCTAssertNotNil(decoded?["worker"])
        XCTAssertNotNil(decoded?["iter"])
    }
}

private final class NoKeychain: KeychainStoring {
    var reads = 0

    func readBlob() throws -> String {
        reads += 1
        throw AccountFailure(.keychainDenied)
    }

    func writeBlob(_ blob: String) throws {
        throw AccountFailure(.writeMismatch)
    }

    func deleteBlob() throws {
        throw AccountFailure(.keychainDenied)
    }

    func checkWritable(_ blob: String) throws {}
}
