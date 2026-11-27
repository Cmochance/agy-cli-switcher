import Darwin
import Foundation
import SQLite3

public enum TelemetrySource: String, Codable, Equatable, Sendable {
    case cli
    case app
}

public enum TelemetrySourceFilter: String, Codable, Equatable, Sendable {
    case all
    case cli
    case app
    case auto
}

public enum OrchestratorRole: String, Codable, Equatable, Sendable {
    case none
    case planner
    case execution
}

public struct ContextCategoryChild: Equatable, Codable, Sendable {
    public var label: String
    public var tokens: Int
}

public struct ContextCategoryRaw: Equatable, Codable, Sendable {
    public var key: String
    public var label: String
    public var tokens: Int
    public var children: [ContextCategoryChild]
}

public struct GenerationContextRaw: Equatable, Codable, Sendable {
    public var usedTokens: Int
    public var maxTokens: Int
    public var categories: [ContextCategoryRaw]
}

public struct DecodedGeneration: Equatable, Sendable {
    public var index: Int
    public var executionId: String
    public var error: String
    public var stepIndices: [Int]
    public var modelName: String
    public var modelEnum: Int64?
    public var executionModelEnum: Int64?
    public var role: OrchestratorRole
    public var providerInputTokens: Int?
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var thinkingTokens: Int
    public var responseTokens: Int
    public var requestId: String
    public var retries: Int
    public var retryErrors: [String]
    public var ttftMs: Double?
    public var streamingMs: Double?
    public var context: GenerationContextRaw?
}

public struct StepTiming: Equatable, Sendable {
    public var createdMs: Double?
    public var viewableMs: Double?
    public var finishedMs: Double?
    public var completedMs: Double?
    public var startedMs: Double?
}

public struct CheckpointSummary: Equatable, Sendable {
    public var stepIndex: Int
    public var summaryTokens: Int
}

public struct ConversationDatabaseSnapshot: Equatable, Sendable {
    public var generations: [DecodedGeneration]
    public var times: [Int: StepTiming]
    public var checkpointSteps: [Int]
    public var latestCheckpoint: CheckpointSummary?
}

public struct ConversationSummaryRecord: Equatable, Sendable {
    public var conversationId: String
    public var title: String
    public var workspaceUris: String
    public var source: String
    public var agentName: String
    public var parentConversationId: String
    public var nestingDepth: Int
    public var notFullyIdle: Bool
    public var killed: Bool
    public var stepCount: Int
    public var lastModifiedIso: String
}

public struct AntigravityDataRoot: Equatable, Sendable {
    public var source: TelemetrySource
    public var url: URL

    public var conversationsDirectory: URL {
        url.appendingPathComponent("conversations", isDirectory: true)
    }

    public var brainDirectory: URL {
        url.appendingPathComponent("brain", isDirectory: true)
    }

    public var summariesDatabaseURL: URL {
        url.appendingPathComponent("conversation_summaries.db")
    }
}

public enum AntigravityDataRoots {
    public static func resolve(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filter: TelemetrySourceFilter = .all
    ) -> [AntigravityDataRoot] {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let cliDir: URL = {
            if let override = environment["ANTIGRAVITY_CLI_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty
            {
                return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            }
            return gemini.appendingPathComponent("antigravity-cli", isDirectory: true).standardizedFileURL
        }()
        let appDir: URL = {
            if let override = environment["ANTIGRAVITY_APP_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty
            {
                return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            }
            return gemini.appendingPathComponent("antigravity", isDirectory: true).standardizedFileURL
        }()

        var ordered: [AntigravityDataRoot] = []
        switch filter {
        case .cli:
            ordered = [AntigravityDataRoot(source: .cli, url: cliDir)]
        case .app:
            ordered = [AntigravityDataRoot(source: .app, url: appDir)]
        case .all, .auto:
            ordered = [
                AntigravityDataRoot(source: .cli, url: cliDir),
                AntigravityDataRoot(source: .app, url: appDir),
            ]
        }

        var seenPaths = Set<String>()
        return ordered.filter { seenPaths.insert($0.url.path).inserted }
    }
}

public func isValidConversationID(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 128 else {
        return false
    }
    guard let first = id.unicodeScalars.first, isConversationIDLeading(first) else {
        return false
    }
    return id.unicodeScalars.allSatisfy { scalar in
        isConversationIDLeading(scalar) || scalar == "_" || scalar == "-"
    }
}

private func isConversationIDLeading(_ scalar: UnicodeScalar) -> Bool {
    (scalar.value >= 0x30 && scalar.value <= 0x39)
        || (scalar.value >= 0x41 && scalar.value <= 0x5A)
        || (scalar.value >= 0x61 && scalar.value <= 0x7A)
}

/// Read-only SQLite + protobuf reader for Antigravity conversation databases.
final class AntigravityDatabaseReader {
    static let shared = AntigravityDatabaseReader()

    private struct CachedSnapshot {
        var stamp: String
        var snapshot: ConversationDatabaseSnapshot
    }

    private let lock = NSLock()
    private var cache: [String: CachedSnapshot] = [:]
    private var cacheOrder: [String] = []
    private let maxCachedDatabases = 16

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        cacheOrder.removeAll()
    }

    static func databaseStamp(at dbURL: URL) -> String {
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        return [dbURL, walURL].map { fileStamp(at: $0) }.joined(separator: "|")
    }

    static func fileStamp(at url: URL) -> String {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else {
            return ""
        }
        let sec = st.st_mtimespec.tv_sec
        let nsec = st.st_mtimespec.tv_nsec
        return "\(sec).\(nsec):\(st.st_size)"
    }

    static func decodeGeneration(index: Int, data: Data) throws -> DecodedGeneration {
        let generation = try ProtobufMessage(data: data)
        let chat = generation.nested(1)
        let plannerConfig = generation.nested(3)
        let planExecute = plannerConfig.nested(60)
        let usage = chat.nested(4)
        let start = chat.nested(9)
        let contextMsg = start.nested(10)
        let breakdown = contextMsg.nested(3)

        let rawModelEnum = chat.optionalInt(3)
        let modelEnum = (rawModelEnum ?? 0) != 0 ? rawModelEnum : nil
        let rawExecEnum = planExecute.optionalInt(1)
        let executionModelEnum = (rawExecEnum ?? 0) != 0 ? rawExecEnum : nil

        let role: OrchestratorRole
        if let executionModelEnum {
            role = (modelEnum == executionModelEnum) ? .execution : .planner
        } else {
            role = .none
        }

        let inputTokens = Int(clamping: max(0, usage.int(2)))
        let cacheReadTokens = Int(clamping: max(0, usage.int(5)))
        let outputTokens = Int(clamping: max(0, usage.int(3)))
        let thinkingTokens = Int(clamping: max(0, usage.int(9)))
        let responseTokens = Int(clamping: max(0, usage.int(10)))
        let providerInputTokens: Int? = (usage.has(2) || usage.has(5)) ? (inputTokens + cacheReadTokens) : nil

        let modelPrimary = chat.string(21)
        let modelName = modelPrimary.isEmpty ? chat.string(19) : modelPrimary

        var requestId = ""
        for entry in chat.messages(20) where entry.string(1) == "request_id" {
            requestId = entry.string(2)
            break
        }

        let retryErrors = chat.messages(17)
            .map { $0.string(3) }
            .filter { !$0.isEmpty }

        let contextMax = Int(clamping: max(0, contextMsg.int(4)))
        let context: GenerationContextRaw? = contextMax > 0 ? GenerationContextRaw(
            usedTokens: Int(clamping: max(0, contextMsg.int(1))),
            maxTokens: contextMax,
            categories: breakdown.messages(1).enumerated().map { groupIndex, group in
                let children = group.messages(5).map { child in
                    ContextCategoryChild(
                        label: child.string(1),
                        tokens: Int(clamping: max(0, child.int(3)))
                    )
                }
                return ContextCategoryRaw(
                    key: "group-\(groupIndex)",
                    label: group.string(1),
                    tokens: Int(clamping: max(0, group.int(4))),
                    children: children
                )
            }
        ) : nil

        return DecodedGeneration(
            index: index,
            executionId: generation.string(4),
            error: generation.string(5),
            stepIndices: generation.packedOrRepeatedInts(2),
            modelName: modelName,
            modelEnum: modelEnum,
            executionModelEnum: executionModelEnum,
            role: role,
            providerInputTokens: providerInputTokens,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            thinkingTokens: thinkingTokens,
            responseTokens: responseTokens,
            requestId: requestId,
            retries: Int(clamping: max(0, chat.int(14))),
            retryErrors: retryErrors,
            ttftMs: ProtobufMessage.milliseconds(chat.data(11)),
            streamingMs: ProtobufMessage.milliseconds(chat.data(12)),
            context: context
        )
    }

    static func decodeCheckpointTokens(_ stepPayload: Data?) -> Int {
        guard let stepPayload, !stepPayload.isEmpty,
              let payload = try? ProtobufMessage(data: stepPayload)
        else {
            return 0
        }
        let cp = payload.nested(30)
        guard !cp.isEmpty else {
            return 0
        }
        var tokens = estimateTextTokens(cp.string(5))
        for reqData in cp.datas(30) {
            if let reqMsg = try? ProtobufMessage(data: reqData) {
                tokens += estimateTextTokens(reqMsg.string(1))
            }
        }
        let artifactCount = cp.datas(14).count
        tokens += min(artifactCount, 200) * 35
        return tokens > 0 ? max(500, tokens) : 0
    }

    static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }
        var cjk = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            let v = scalar.value
            if (0x4E00 ... 0x9FFF).contains(v)
                || (0x3400 ... 0x4DBF).contains(v)
                || (0x3000 ... 0x303F).contains(v)
                || (0xFF00 ... 0xFFEF).contains(v)
            {
                cjk += 1
            }
        }
        let other = total - cjk
        return Int(ceil(Double(cjk) * 1.15 + Double(other) / 3.8))
    }

    func readConversationDatabase(at dbURL: URL, force: Bool = false) -> ConversationDatabaseSnapshot? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }
        let stamp = Self.databaseStamp(at: dbURL)
        let cacheKey = dbURL.path
        if !force, !stamp.isEmpty {
            lock.lock()
            let hit = cache[cacheKey]
            lock.unlock()
            if let hit, hit.stamp == stamp {
                return hit.snapshot
            }
        }

        guard let snapshot = Self.queryConversationDatabase(at: dbURL) else {
            return nil
        }
        if !stamp.isEmpty {
            lock.lock()
            cache[cacheKey] = CachedSnapshot(stamp: stamp, snapshot: snapshot)
            cacheOrder.removeAll { $0 == cacheKey }
            cacheOrder.append(cacheKey)
            while cacheOrder.count > maxCachedDatabases {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
            lock.unlock()
        }
        return snapshot
    }

    private static func queryConversationDatabase(at dbURL: URL) -> ConversationDatabaseSnapshot? {
        guard let db = openReadOnlyDatabase(at: dbURL) else {
            return nil
        }
        defer { sqlite3_close_v2(db) }

        var generations: [DecodedGeneration] = []
        if let stmt = prepare(db, "SELECT idx, data FROM gen_metadata ORDER BY idx") {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idx = Int(sqlite3_column_int64(stmt, 0))
                guard let blob = columnData(stmt, 1) else {
                    continue
                }
                if let decoded = try? decodeGeneration(index: idx, data: blob) {
                    generations.append(decoded)
                }
            }
        }

        let stepColumns = tableColumns(db, table: "steps")
        let hasStepType = stepColumns.contains("step_type")
        let hasStatus = stepColumns.contains("status")
        let hasPayload = stepColumns.contains("step_payload")

        var times: [Int: StepTiming] = [:]
        var checkpointSteps: [Int] = []
        var latestCompletedCpIdx = -1

        if !stepColumns.isEmpty {
            var selectCols = ["idx"]
            if hasStepType { selectCols.append("step_type") }
            if hasStatus { selectCols.append("status") }
            selectCols.append("metadata")
            let sql = "SELECT \(selectCols.joined(separator: ", ")) FROM steps ORDER BY idx"
            if let stmt = prepare(db, sql) {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var col: Int32 = 0
                    let idx = Int(sqlite3_column_int64(stmt, col)); col += 1
                    let stepType = hasStepType ? Int(sqlite3_column_int64(stmt, col)) : 0
                    if hasStepType { col += 1 }
                    let status = hasStatus ? Int(sqlite3_column_int64(stmt, col)) : 3
                    if hasStatus { col += 1 }
                    let metadataBlob = columnData(stmt, col)

                    if hasStepType, stepType == 23 {
                        checkpointSteps.append(idx)
                        if !hasStatus || status == 3 {
                            latestCompletedCpIdx = idx
                        }
                    }

                    if let metadataBlob, let meta = try? ProtobufMessage(data: metadataBlob) {
                        times[idx] = StepTiming(
                            createdMs: ProtobufMessage.milliseconds(meta.data(1)),
                            viewableMs: ProtobufMessage.milliseconds(meta.data(6)),
                            finishedMs: ProtobufMessage.milliseconds(meta.data(7)),
                            completedMs: ProtobufMessage.milliseconds(meta.data(8)),
                            startedMs: ProtobufMessage.milliseconds(meta.data(32))
                        )
                    }
                }
            }
        }

        var latestCheckpoint: CheckpointSummary?
        if latestCompletedCpIdx >= 0 {
            var summaryTokens = 0
            if hasPayload,
               let stmt = prepare(db, "SELECT step_payload FROM steps WHERE idx = ?")
            {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, Int64(latestCompletedCpIdx))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    summaryTokens = decodeCheckpointTokens(columnData(stmt, 0))
                }
            }
            latestCheckpoint = CheckpointSummary(stepIndex: latestCompletedCpIdx, summaryTokens: summaryTokens)
        }

        return ConversationDatabaseSnapshot(
            generations: generations,
            times: times,
            checkpointSteps: checkpointSteps,
            latestCheckpoint: latestCheckpoint
        )
    }

    func readConversationSummaries(at summariesDB: URL) -> [String: ConversationSummaryRecord] {
        guard FileManager.default.fileExists(atPath: summariesDB.path),
              let db = Self.openReadOnlyDatabase(at: summariesDB)
        else {
            return [:]
        }
        defer { sqlite3_close_v2(db) }

        let sql = """
        SELECT conversation_id, title, workspace_uris, source, agent_name,
               parent_conversation_id, nesting_depth, not_fully_idle, killed,
               step_count, last_modified_time
        FROM conversation_summaries
        """
        guard let stmt = Self.prepare(db, sql) else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var records: [String: ConversationSummaryRecord] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = Self.columnText(stmt, 0)
            guard isValidConversationID(cid) else {
                continue
            }
            records[cid] = ConversationSummaryRecord(
                conversationId: cid,
                title: Self.columnText(stmt, 1),
                workspaceUris: Self.columnText(stmt, 2),
                source: Self.columnText(stmt, 3),
                agentName: Self.columnText(stmt, 4),
                parentConversationId: Self.columnText(stmt, 5),
                nestingDepth: Int(sqlite3_column_int64(stmt, 6)),
                notFullyIdle: sqlite3_column_int64(stmt, 7) != 0,
                killed: sqlite3_column_int64(stmt, 8) != 0,
                stepCount: Int(sqlite3_column_int64(stmt, 9)),
                lastModifiedIso: Self.columnText(stmt, 10)
            )
        }
        return records
    }

    func readConversationChildren(at summariesDB: URL) -> [String: [String]] {
        guard FileManager.default.fileExists(atPath: summariesDB.path),
              let db = Self.openReadOnlyDatabase(at: summariesDB)
        else {
            return [:]
        }
        defer { sqlite3_close_v2(db) }

        guard let stmt = Self.prepare(db, "SELECT conversation_id, parent_id FROM conversation_parents") else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var children: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let child = Self.columnText(stmt, 0)
            let parent = Self.columnText(stmt, 1)
            guard isValidConversationID(child), isValidConversationID(parent) else {
                continue
            }
            children[parent, default: []].append(child)
        }
        return children
    }

    private static func openReadOnlyDatabase(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let directFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE
        if sqlite3_open_v2(url.path, &db, directFlags, nil) == SQLITE_OK, let opened = db {
            sqlite3_busy_timeout(opened, 500)
            if sqlite3_exec(opened, "PRAGMA query_only = ON;", nil, nil, nil) == SQLITE_OK,
               hasReadableSchema(opened)
            {
                return opened
            }
        }
        if let opened = db {
            sqlite3_close_v2(opened)
            db = nil
        }

        let escaped = escapeSQLiteURIPath(url.path)
        let uri = "file:\(escaped)?immutable=1"
        let uriFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE
        if sqlite3_open_v2(uri, &db, uriFlags, nil) == SQLITE_OK, let opened = db {
            sqlite3_busy_timeout(opened, 500)
            _ = sqlite3_exec(opened, "PRAGMA query_only = ON;", nil, nil, nil)
            return opened
        }
        if let opened = db {
            sqlite3_close_v2(opened)
        }
        return nil
    }

    private static func hasReadableSchema(_ db: OpaquePointer) -> Bool {
        guard let stmt = prepare(db, "SELECT count(*) FROM sqlite_master") else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func escapeSQLiteURIPath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
    }

    private static func tableColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        guard let stmt = prepare(db, "PRAGMA table_info(\(table))") else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = columnText(stmt, 1)
            if !name.isEmpty {
                columns.insert(name)
            }
        }
        return columns
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let stmt {
                sqlite3_finalize(stmt)
            }
            return nil
        }
        return stmt
    }

    private static func columnData(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else {
            return nil
        }
        let byteCount = Int(sqlite3_column_bytes(stmt, index))
        guard byteCount > 0, let pointer = sqlite3_column_blob(stmt, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: byteCount)
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, index) else {
            return ""
        }
        return String(cString: pointer)
    }
}
