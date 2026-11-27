import Foundation
import XCTest
@testable import AgyAccount

final class SessionTelemetryTests: XCTestCase {
    func testLargestRemainderContextApportionmentAndPostCompactEstimate() {
        let gen = DecodedGeneration(
            index: 0,
            executionId: "e1",
            error: "",
            stepIndices: [100, 101],
            modelName: "Gemini 4 Carbon (High)",
            modelEnum: nil,
            executionModelEnum: nil,
            role: .none,
            providerInputTokens: 248_366,
            inputTokens: 8_366,
            cacheReadTokens: 240_000,
            outputTokens: 500,
            thinkingTokens: 0,
            responseTokens: 500,
            requestId: "r1",
            retries: 0,
            retryErrors: [],
            ttftMs: 1_000,
            streamingMs: 2_000,
            context: GenerationContextRaw(
                usedTokens: 312_886,
                maxTokens: 256_000,
                categories: [
                    ContextCategoryRaw(key: "g0", label: "Chat Messages", tokens: 293_170, children: []),
                    ContextCategoryRaw(key: "g1", label: "Tools", tokens: 7_336, children: []),
                    ContextCategoryRaw(
                        key: "g2",
                        label: "System Prompt",
                        tokens: 12_380,
                        children: [ContextCategoryChild(label: "skills", tokens: 3_678)]
                    ),
                ]
            )
        )

        let snapshot = SessionTelemetryEngine.contextSnapshot(generation: gen)
        XCTAssertEqual(snapshot.usedTokens, 248_366)
        XCTAssertEqual(snapshot.usedPercent, 97.0)
        XCTAssertEqual(snapshot.source, "provider-usage")
        XCTAssertEqual(snapshot.categories.reduce(0) { $0 + $1.tokens }, 256_000)
        XCTAssertEqual(snapshot.categories.filter { !$0.isFreeSpace }.reduce(0) { $0 + $1.tokens }, 248_366)
        XCTAssertTrue(snapshot.categories.contains { $0.label == "Skills" })

        let postCompact = SessionTelemetryEngine.contextSnapshot(
            generation: gen,
            latestCheckpoint: CheckpointSummary(stepIndex: 105, summaryTokens: 6_200)
        )
        XCTAssertTrue(postCompact.compactedPending)
        XCTAssertEqual(postCompact.source, "post-compact-estimate")
        XCTAssertEqual(postCompact.preCompactUsedTokens, 248_366)
        XCTAssertEqual(postCompact.preCompactPercent, 97.0)
        XCTAssertLessThan(postCompact.usedTokens, 248_366)
    }

    func testOrchestratorMultiModelAndTranscriptFallbackAndSubagents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-session-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let initialized = home.appendingPathComponent(".agy-cs/initialized")
        try FileManager.default.createDirectory(at: initialized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: initialized)

        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let mainID = "main-conv-1"
        let subDBID = "sub-conv-db"
        let subTranscriptID = "sub-conv-tr"

        // Main session transcript with overlapping tool calls and invoke_subagent result.
        let mainLogs = cliRoot.appendingPathComponent("brain/\(mainID)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: mainLogs, withIntermediateDirectories: true)
        let mainSteps: [[String: Any]] = [
            ["step_index": 0, "type": "USER_INPUT", "created_at": "2026-11-26T10:00:00Z", "content": "<USER_REQUEST>Build feature</USER_REQUEST>"],
            [
                "step_index": 1,
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-26T10:00:01Z",
                "content": "Launching subagent",
                "tool_calls": [
                    ["name": "read_file", "args": ["Path": "/a"]],
                    ["name": "invoke_subagent", "args": ["Role": "Code Reviewer", "TypeName": "research"]],
                ],
            ],
            ["step_index": 2, "type": "GENERIC", "created_at": "2026-11-26T10:00:02Z", "content": "Created At: 2026-11-26T10:00:02Z\nCompleted At: 2026-11-26T10:00:06Z\nok"],
            ["step_index": 3, "type": "GENERIC", "created_at": "2026-11-26T10:00:04Z", "content": "Created At: 2026-11-26T10:00:04Z\nCompleted At: 2026-11-26T10:00:10Z\nconversationId: \(subTranscriptID)"],
        ]
        try writeJSONL(mainSteps, to: mainLogs.appendingPathComponent("transcript.jsonl"))

        try SQLiteTestBuilder.createConversationDB(at: cliRoot.appendingPathComponent("conversations/\(mainID).db")) { db in
            let g1 = ProtobufEncoder.makeGeneration(
                requestId: "r-plan",
                model: "Orchestrator (Neon)",
                input: 1_000,
                cache: 9_000,
                output: 100,
                ttftSeconds: 2,
                streamingSeconds: 2,
                stepIndices: [1],
                maxTokens: 512_000,
                usedTokens: 10_000,
                categories: [(label: "Chat Messages", tokens: 10_000, children: [])],
                modelEnum: 1537,
                executionModelEnum: 1669
            )
            let g2 = ProtobufEncoder.makeGeneration(
                requestId: "r-exec",
                model: "Gemini 4 Hydrogen (High)",
                input: 500,
                cache: 19_500,
                output: 200,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [3],
                maxTokens: 512_000,
                usedTokens: 20_000,
                categories: [(label: "Chat Messages", tokens: 20_000, children: [])],
                modelEnum: 1669,
                executionModelEnum: 1669
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g1)
            try SQLiteTestBuilder.insertGeneration(db, idx: 1, data: g2)
        }

        // Subagent 1 via conversation_summaries.db
        try SQLiteTestBuilder.createSummariesDB(
            at: cliRoot.appendingPathComponent("conversation_summaries.db"),
            rows: [
                (cid: mainID, title: "Build feature", parentId: "", source: "CORTEX_TRAJECTORY_SOURCE_CLI", depth: 0),
                (cid: subDBID, title: "DB Researcher", parentId: mainID, source: "CORTEX_TRAJECTORY_SOURCE_CLI", depth: 1),
            ]
        )
        let sub1Logs = cliRoot.appendingPathComponent("brain/\(subDBID)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: sub1Logs, withIntermediateDirectories: true)
        try writeJSONL([["step_index": 0, "type": "USER_INPUT", "content": "Inspect DB"]], to: sub1Logs.appendingPathComponent("transcript.jsonl"))
        try SQLiteTestBuilder.createConversationDB(at: cliRoot.appendingPathComponent("conversations/\(subDBID).db")) { db in
            let g = ProtobufEncoder.makeGeneration(
                requestId: "r-sub1",
                model: "Gemini 4 Hydrogen (High)",
                input: 1_000,
                cache: 4_000,
                output: 50,
                ttftSeconds: 1,
                streamingSeconds: 1,
                stepIndices: [0],
                maxTokens: 512_000,
                usedTokens: 5_000
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g)
        }

        // Subagent 2 via transcript-only fallback (no .db)
        let sub2Logs = cliRoot.appendingPathComponent("brain/\(subTranscriptID)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: sub2Logs, withIntermediateDirectories: true)
        try writeJSONL([
            ["step_index": 0, "type": "USER_INPUT", "content": "Review code"],
            ["step_index": 1, "type": "PLANNER_RESPONSE", "model": "Gemini 4 Carbon (High)", "input_tokens": 200, "cache_read_tokens": 800, "output_tokens": 50, "content": "Looks good"],
        ], to: sub2Logs.appendingPathComponent("transcript.jsonl"))

        let now = parseTimestamp("2026-11-26T10:01:00Z")!
        let loaded = SessionTelemetryEngine.load(home: home, environment: [:], now: now)
        guard case .loaded(let snap) = loaded else {
            return XCTFail("Expected loaded session telemetry")
        }

        XCTAssertEqual(snap.conversationId, mainID)
        XCTAssertTrue(snap.contextWindow.hasOrchestrator)
        XCTAssertEqual(snap.contextWindow.models.count, 2)
        // Tool intervals [02..06] U [04..10] = 8 seconds = 8000 ms
        XCTAssertEqual(snap.telemetry.toolTimeMs, 8_000)
        // Output: 100 + 200 = 300 over (2s + 2s) = 4s -> 75.0 tok/s
        XCTAssertEqual(snap.telemetry.tps, 75.0)
        XCTAssertEqual(snap.subagents.map(\.conversationId), [subDBID, subTranscriptID])
        XCTAssertEqual(snap.subagentTotals.count, 2)
        // Main total (10000+100 + 20000+200 = 30300) + Sub1 (5050) + Sub2 (1050) = 36400
        XCTAssertEqual(snap.subagentTotals.combinedTotalTokens, 36_400)

        // Verify incremental stamp hit
        let unchanged = SessionTelemetryEngine.load(home: home, environment: [:], knownStamp: snap.stateStamp, now: now)
        XCTAssertEqual(unchanged, .unchanged(stamp: snap.stateStamp))

        // CLI invocation must not touch keychain.
        let keychain = NoKeychain()
        let out = Capture()
        let code = AgyAccountCLI.run(
            ["session", "--json"],
            home: home,
            keychain: keychain,
            processes: FixedProcesses(),
            now: { "2026-11-26T10:01:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: ScriptedTerminal(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher(),
            environment: [:],
            clock: { now },
            stdout: { out.output.append($0) },
            stderr: { out.errors.append($0) }
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(keychain.reads, 0)
        let decoded = try JSONDecoder().decode(SessionTelemetrySnapshot.self, from: Data(out.output.joined(separator: "\n").utf8))
        XCTAssertEqual(decoded.conversationId, mainID)
    }

    func testSessionHandlesMissingSessionsGracefully() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-empty-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".agy-cs"), withIntermediateDirectories: true)
        try? Data("1\n".utf8).write(to: home.appendingPathComponent(".agy-cs/initialized"))
        defer { try? FileManager.default.removeItem(at: home) }

        let keychain = NoKeychain()
        let out = Capture()
        let code = AgyAccountCLI.run(
            ["session"],
            home: home,
            keychain: keychain,
            processes: FixedProcesses(),
            now: { "2026-11-26T10:00:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: ScriptedTerminal(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher(),
            environment: [:],
            stdout: { out.output.append($0) },
            stderr: { out.errors.append($0) }
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out.output, ["暂无本地 Antigravity 会话记录。"])
        XCTAssertEqual(keychain.reads, 0)

        let missingExplicit = AgyAccountCLI.run(
            ["session", "non-existent-id"],
            home: home,
            keychain: keychain,
            processes: FixedProcesses(),
            now: { "2026-11-26T10:00:00Z" },
            preferredLanguages: ["zh-Hans"],
            terminal: ScriptedTerminal(),
            launcher: ScriptedLauncher(),
            usage: ScriptedUsage(),
            refresher: ScriptedRefresher(),
            environment: [:],
            stdout: { _ in },
            stderr: { _ in }
        )
        XCTAssertEqual(missingExplicit, 1)
    }

    func testSessionPrefersDatabaseTokenTotalsOverPartialTranscript() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-db-tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let cid = "partial-transcript-conv"
        let logsDir = cliRoot.appendingPathComponent("brain/\(cid)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try writeJSONL([
            ["step_index": 0, "type": "USER_INPUT", "content": "Check totals"],
            ["step_index": 1, "type": "PLANNER_RESPONSE", "model": "Gemini 4 Carbon (High)", "input_tokens": 1_000, "cache_read_tokens": 0, "output_tokens": 100, "content": "Partial"],
            ["step_index": 2, "type": "ERROR_MESSAGE", "content": "Transient failure"],
        ], to: logsDir.appendingPathComponent("transcript.jsonl"))

        try SQLiteTestBuilder.createConversationDB(at: cliRoot.appendingPathComponent("conversations/\(cid).db")) { db in
            let g1 = ProtobufEncoder.makeGeneration(
                requestId: "r-ok",
                model: "Gemini 4 Carbon (High)",
                input: 1_000,
                cache: 0,
                output: 100,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [1]
            )
            let g2 = ProtobufEncoder.makeGeneration(
                requestId: "r-err-or-checkpoint",
                model: "Gemini 4 Carbon (High)",
                input: 5_000,
                cache: 10_000,
                output: 200,
                ttftSeconds: 1,
                streamingSeconds: 2,
                stepIndices: [2],
                error: "interrupted"
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: g1)
            try SQLiteTestBuilder.insertGeneration(db, idx: 1, data: g2)
        }

        let loaded = SessionTelemetryEngine.load(
            home: home,
            environment: [:],
            now: parseTimestamp("2026-11-26T10:01:00Z")!,
            reader: AntigravityDatabaseReader()
        )
        guard case .loaded(let snap) = loaded else {
            return XCTFail("Expected loaded session snapshot")
        }
        XCTAssertEqual(snap.telemetry.requestCount, 2)
        XCTAssertEqual(snap.telemetry.inputTokens, 6_000)
        XCTAssertEqual(snap.telemetry.cacheReadTokens, 10_000)
        XCTAssertEqual(snap.telemetry.outputTokens, 300)
        XCTAssertEqual(snap.telemetry.totalTokens, 16_300)
    }

    private func writeJSONL(_ items: [[String: Any]], to url: URL) throws {
        let lines = try items.map { item -> String in
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
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
