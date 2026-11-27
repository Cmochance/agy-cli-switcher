import Foundation
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
