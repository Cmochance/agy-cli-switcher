import Foundation
import SQLite3
import XCTest
@testable import AgyAccount

final class ProtobufAndDatabaseTests: XCTestCase {
    func testProtobufVarintPackedAndMilliseconds() throws {
        let context = ProtobufEncoder.concat([
            ProtobufEncoder.intField(1, 48_000),
            ProtobufEncoder.intField(4, 200_000),
            ProtobufEncoder.bytesField(3, ProtobufEncoder.bytesField(1, ProtobufEncoder.concat([
                ProtobufEncoder.stringField(1, "System Prompt"),
                ProtobufEncoder.intField(4, 6_000),
            ]))),
        ])
        let generation = ProtobufEncoder.concat([
            ProtobufEncoder.bytesField(1, ProtobufEncoder.concat([
                ProtobufEncoder.intField(3, 1537),
                ProtobufEncoder.bytesField(4, ProtobufEncoder.concat([
                    ProtobufEncoder.intField(2, 500),
                    ProtobufEncoder.intField(3, 100),
                    ProtobufEncoder.intField(5, 1_500),
                    ProtobufEncoder.intField(9, 40),
                    ProtobufEncoder.intField(10, 60),
                ])),
                ProtobufEncoder.bytesField(9, ProtobufEncoder.bytesField(10, context)),
                ProtobufEncoder.bytesField(11, ProtobufEncoder.concat([
                    ProtobufEncoder.intField(1, 2),
                    ProtobufEncoder.intField(2, 500_000_000),
                ])),
                ProtobufEncoder.bytesField(12, ProtobufEncoder.intField(1, 5)),
                ProtobufEncoder.bytesField(20, ProtobufEncoder.concat([
                    ProtobufEncoder.stringField(1, "request_id"),
                    ProtobufEncoder.stringField(2, "req-pb-1"),
                ])),
                ProtobufEncoder.stringField(21, "Gemini 4 Carbon (High)"),
            ])),
            ProtobufEncoder.bytesField(2, ProtobufEncoder.concat([
                ProtobufEncoder.varint(1),
                ProtobufEncoder.varint(2),
            ])),
            ProtobufEncoder.bytesField(3, ProtobufEncoder.bytesField(60, ProtobufEncoder.intField(1, 1669))),
            ProtobufEncoder.stringField(4, "exec-1"),
        ])

        let decoded = try AntigravityDatabaseReader.decodeGeneration(index: 0, data: generation)
        XCTAssertEqual(decoded.modelName, "Gemini 4 Carbon (High)")
        XCTAssertEqual(decoded.role, .planner)
        XCTAssertEqual(decoded.stepIndices, [1, 2])
        XCTAssertEqual(decoded.providerInputTokens, 2_000)
        XCTAssertEqual(decoded.inputTokens, 500)
        XCTAssertEqual(decoded.cacheReadTokens, 1_500)
        XCTAssertEqual(decoded.outputTokens, 100)
        XCTAssertEqual(decoded.thinkingTokens, 40)
        XCTAssertEqual(decoded.responseTokens, 60)
        XCTAssertEqual(decoded.requestId, "req-pb-1")
        XCTAssertEqual(decoded.ttftMs, 2_500)
        XCTAssertEqual(decoded.streamingMs, 5_000)
        XCTAssertEqual(decoded.context?.maxTokens, 200_000)
        XCTAssertEqual(decoded.context?.usedTokens, 48_000)
        XCTAssertEqual(decoded.context?.categories.first?.label, "System Prompt")
        XCTAssertEqual(decoded.context?.categories.first?.tokens, 6_000)

        XCTAssertThrowsError(try ProtobufMessage(data: Data([10, 8, 1]))) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
        XCTAssertThrowsError(try ProtobufMessage(data: Data([0x08 | 0x03]))) { error in
            XCTAssertEqual(error as? ProtobufError, .unsupportedWireType(3))
        }
    }

    func testSQLiteReadOnlyWithWalCheckpointAndReadOnlyDirectoryFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-db-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let dbURL = root.appendingPathComponent("conv-1.db")
        try SQLiteTestBuilder.createConversationDB(at: dbURL, walMode: true) { db in
            let gen = ProtobufEncoder.makeGeneration(
                requestId: "req-wal-1",
                model: "Gemini 4 Neon (XHigh)",
                input: 300,
                cache: 900,
                output: 120,
                ttftSeconds: 1,
                streamingSeconds: 3,
                stepIndices: [1],
                maxTokens: 256_000
            )
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: gen)
            let stepMeta = ProtobufEncoder.concat([
                ProtobufEncoder.bytesField(1, ProtobufEncoder.intField(1, 1_735_689_601)),
                ProtobufEncoder.bytesField(8, ProtobufEncoder.intField(1, 1_735_689_605)),
            ])
            try SQLiteTestBuilder.insertStep(db, idx: 1, stepType: 2, status: 3, metadata: stepMeta)
            let cpPayload = ProtobufEncoder.bytesField(30, ProtobufEncoder.concat([
                ProtobufEncoder.stringField(5, "Summary of prior turns"),
                ProtobufEncoder.bytesField(30, ProtobufEncoder.stringField(1, "User asked to implement feature")),
                ProtobufEncoder.bytesField(14, Data([1])),
            ]))
            try SQLiteTestBuilder.insertStep(db, idx: 2, stepType: 23, status: 3, metadata: stepMeta, payload: cpPayload)
        }

        let reader = AntigravityDatabaseReader()
        let beforeData = try Data(contentsOf: dbURL)
        let snapshot = try XCTUnwrap(reader.readConversationDatabase(at: dbURL))
        XCTAssertEqual(snapshot.generations.count, 1)
        XCTAssertEqual(snapshot.generations[0].requestId, "req-wal-1")
        XCTAssertEqual(snapshot.checkpointSteps, [2])
        XCTAssertEqual(snapshot.latestCheckpoint?.stepIndex, 2)
        XCTAssertGreaterThanOrEqual(snapshot.latestCheckpoint?.summaryTokens ?? 0, 500)
        XCTAssertEqual(try Data(contentsOf: dbURL), beforeData)

        // Verify fallback to ?immutable=1 when parent directory is read-only.
        let roDir = root.appendingPathComponent("ro-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let roDB = roDir.appendingPathComponent("ro.db")
        try SQLiteTestBuilder.createConversationDB(at: roDB, walMode: false) { db in
            let gen = ProtobufEncoder.makeGeneration(requestId: "req-ro", model: "Gemini 4 Carbon", input: 10, cache: 0, output: 5, ttftSeconds: 1, streamingSeconds: 1, stepIndices: [0])
            try SQLiteTestBuilder.insertGeneration(db, idx: 0, data: gen)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: roDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: roDir.path)
        }
        let roSnapshot = try XCTUnwrap(reader.readConversationDatabase(at: roDB, force: true))
        XCTAssertEqual(roSnapshot.generations.first?.requestId, "req-ro")

        XCTAssertTrue(isValidConversationID("00c464dc-2639-445f-8791-1b69377d6c4c"))
        XCTAssertFalse(isValidConversationID("../escape"))
        XCTAssertFalse(isValidConversationID(".hidden"))
        XCTAssertFalse(isValidConversationID(""))
    }
}

enum ProtobufEncoder {
    static func varint(_ value: Int64) -> Data {
        var raw = UInt64(bitPattern: value)
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(raw & 0x7F)
            raw >>= 7
            if raw != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while raw != 0
        return Data(bytes)
    }

    static func intField(_ number: Int, _ value: Int64) -> Data {
        var data = varint(Int64(number * 8))
        data.append(varint(value))
        return data
    }

    static func bytesField(_ number: Int, _ payload: Data) -> Data {
        var data = varint(Int64(number * 8 + 2))
        data.append(varint(Int64(payload.count)))
        data.append(payload)
        return data
    }

    static func stringField(_ number: Int, _ text: String) -> Data {
        bytesField(number, Data(text.utf8))
    }

    static func concat(_ chunks: [Data]) -> Data {
        var combined = Data()
        for chunk in chunks {
            combined.append(chunk)
        }
        return combined
    }

    static func makeGeneration(
        requestId: String,
        model: String,
        input: Int,
        cache: Int,
        output: Int,
        thinking: Int = 0,
        ttftSeconds: Int64 = 1,
        streamingSeconds: Int64 = 2,
        stepIndices: [Int],
        maxTokens: Int? = nil,
        usedTokens: Int? = nil,
        categories: [(label: String, tokens: Int, children: [(String, Int)])] = [],
        modelEnum: Int64? = nil,
        executionModelEnum: Int64? = nil,
        error: String = "",
        retryErrors: [String] = []
    ) -> Data {
        var chatParts: [Data] = [
            bytesField(4, concat([
                intField(2, Int64(input)),
                intField(3, Int64(output)),
                intField(5, Int64(cache)),
                intField(9, Int64(thinking)),
            ])),
            bytesField(11, intField(1, ttftSeconds)),
            bytesField(12, intField(1, streamingSeconds)),
            bytesField(20, concat([
                stringField(1, "request_id"),
                stringField(2, requestId),
            ])),
            stringField(21, model),
        ]
        if let modelEnum {
            chatParts.append(intField(3, modelEnum))
        }
        for retryErr in retryErrors {
            chatParts.append(bytesField(17, stringField(3, retryErr)))
        }
        if let maxTokens {
            var ctxParts: [Data] = [
                intField(1, Int64(usedTokens ?? (input + cache))),
                intField(4, Int64(maxTokens)),
            ]
            if !categories.isEmpty {
                let groupMsgs = categories.map { cat -> Data in
                    var parts: [Data] = [
                        stringField(1, cat.label),
                        intField(4, Int64(cat.tokens)),
                    ]
                    for child in cat.children {
                        parts.append(bytesField(5, concat([
                            stringField(1, child.0),
                            intField(3, Int64(child.1)),
                        ])))
                    }
                    return bytesField(1, concat(parts))
                }
                ctxParts.append(bytesField(3, concat(groupMsgs)))
            }
            chatParts.append(bytesField(9, bytesField(10, concat(ctxParts))))
        }

        var genParts: [Data] = [bytesField(1, concat(chatParts))]
        for idx in stepIndices {
            genParts.append(intField(2, Int64(idx)))
        }
        if let executionModelEnum {
            genParts.append(bytesField(3, bytesField(60, intField(1, executionModelEnum))))
        }
        genParts.append(stringField(4, "exec-\(requestId)"))
        if !error.isEmpty {
            genParts.append(stringField(5, error))
        }
        return concat(genParts)
    }
}

enum SQLiteTestBuilder {
    static func createConversationDB(
        at url: URL,
        walMode: Bool = false,
        populate: (OpaquePointer) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "SQLiteTestBuilder", code: 1)
        }
        defer { sqlite3_close_v2(db) }
        if walMode {
            _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS gen_metadata(idx INTEGER PRIMARY KEY, data BLOB, size INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS steps(idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL DEFAULT 0, status INTEGER NOT NULL DEFAULT 0, metadata BLOB, step_payload BLOB);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteTestBuilder", code: 2)
        }
        try populate(db)
    }

    static func createSummariesDB(at url: URL, rows: [(cid: String, title: String, parentId: String, source: String, depth: Int)]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "SQLiteTestBuilder", code: 3)
        }
        defer { sqlite3_close_v2(db) }
        let schema = """
        CREATE TABLE IF NOT EXISTS conversation_summaries(
            conversation_id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT "",
            workspace_uris TEXT NOT NULL DEFAULT "",
            source TEXT NOT NULL DEFAULT "",
            agent_name TEXT NOT NULL DEFAULT "",
            parent_conversation_id TEXT NOT NULL DEFAULT "",
            nesting_depth INTEGER NOT NULL DEFAULT 0,
            not_fully_idle NUMERIC NOT NULL DEFAULT 0,
            killed NUMERIC NOT NULL DEFAULT 0,
            step_count INTEGER NOT NULL DEFAULT 0,
            last_modified_time DATETIME NOT NULL DEFAULT ""
        );
        CREATE TABLE IF NOT EXISTS conversation_parents(
            conversation_id TEXT PRIMARY KEY,
            parent_id TEXT NOT NULL
        ) WITHOUT ROWID;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteTestBuilder", code: 4)
        }
        for row in rows {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO conversation_summaries(conversation_id, title, source, parent_conversation_id, nesting_depth) VALUES (?, ?, ?, ?, ?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_text(stmt, 1, row.cid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, row.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, row.source, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 4, row.parentId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(stmt, 5, Int64(row.depth))
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            if !row.parentId.isEmpty {
                var pStmt: OpaquePointer?
                let pSql = "INSERT INTO conversation_parents(conversation_id, parent_id) VALUES (?, ?);"
                if sqlite3_prepare_v2(db, pSql, -1, &pStmt, nil) == SQLITE_OK, let pStmt {
                    sqlite3_bind_text(pStmt, 1, row.cid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(pStmt, 2, row.parentId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    _ = sqlite3_step(pStmt)
                    sqlite3_finalize(pStmt)
                }
            }
        }
    }

    static func insertGeneration(_ db: OpaquePointer, idx: Int, data: Data) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO gen_metadata(idx, data, size) VALUES (?, ?, ?);", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "SQLiteTestBuilder", code: 5)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(idx))
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int64(stmt, 3, Int64(data.count))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "SQLiteTestBuilder", code: 6)
        }
    }

    static func insertStep(
        _ db: OpaquePointer,
        idx: Int,
        stepType: Int,
        status: Int,
        metadata: Data,
        payload: Data? = nil
    ) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO steps(idx, step_type, status, metadata, step_payload) VALUES (?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "SQLiteTestBuilder", code: 7)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(idx))
        sqlite3_bind_int64(stmt, 2, Int64(stepType))
        sqlite3_bind_int64(stmt, 3, Int64(status))
        _ = metadata.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(metadata.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        if let payload {
            _ = payload.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 5, raw.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "SQLiteTestBuilder", code: 8)
        }
    }
}
