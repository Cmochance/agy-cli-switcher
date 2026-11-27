import Foundation

public struct SessionSummaryItem: Equatable, Codable, Identifiable, Sendable {
    public var conversationId: String
    public var title: String
    public var source: TelemetrySource
    public var updatedAtMs: Double
    public var isSubagent: Bool

    public var id: String { conversationId }

    public init(
        conversationId: String,
        title: String,
        source: TelemetrySource,
        updatedAtMs: Double,
        isSubagent: Bool = false
    ) {
        self.conversationId = conversationId
        self.title = title
        self.source = source
        self.updatedAtMs = updatedAtMs
        self.isSubagent = isSubagent
    }
}

public struct ContextCategorySlice: Equatable, Codable, Sendable {
    public var key: String
    public var label: String
    public var tokens: Int
    public var percent: Double?
    public var estimated: Bool
    public var isFreeSpace: Bool

    public init(
        key: String,
        label: String,
        tokens: Int,
        percent: Double?,
        estimated: Bool,
        isFreeSpace: Bool = false
    ) {
        self.key = key
        self.label = label
        self.tokens = tokens
        self.percent = percent
        self.estimated = estimated
        self.isFreeSpace = isFreeSpace
    }
}

public struct ModelContextProgress: Equatable, Codable, Identifiable, Sendable {
    public var key: String
    public var role: OrchestratorRole
    public var shortName: String
    public var fullName: String
    public var usedTokens: Int
    public var maxTokens: Int?
    public var usedPercent: Double?
    public var compactions: Int
    public var isCurrent: Bool

    public var id: String { key }
}

public struct ContextWindowSnapshot: Equatable, Codable, Sendable {
    public var usedTokens: Int
    public var maxTokens: Int?
    public var reportedMaxTokens: Int?
    public var estimatedUsedTokens: Int?
    public var usedPercent: Double?
    public var freePercent: Double?
    public var categories: [ContextCategorySlice]
    public var compactedPending: Bool
    public var preCompactUsedTokens: Int?
    public var preCompactPercent: Double?
    public var compactions: Int
    public var hasOrchestrator: Bool
    public var models: [ModelContextProgress]
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var source: String
}

public struct CacheObservationWindow: Equatable, Codable, Sendable {
    public var model: String
    public var lastRequestAtMs: Double
    public var ageMs: Double
    public var hitPercent: Double
    public var assumedWindowMs: Double?
    public var remainingMs: Double?
}

public struct SessionStatsMetrics: Equatable, Codable, Sendable {
    public var turnCount: Int
    public var stepCount: Int
    public var modelTimeMs: Double?
    public var toolTimeMs: Double?
    public var avgTtftMs: Double?
    public var tps: Double?
    public var peakTps: Double?
    public var latestTps: Double?
    public var requestCount: Int
    public var errorCount: Int
    public var thinkingTokens: Int
    public var toolCount: Int
    public var totalTokens: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var cacheHitPercent: Double?
    public var costUsd: Double?
    public var cacheObservation: CacheObservationWindow?
}

public struct SubagentTelemetryItem: Equatable, Codable, Identifiable, Sendable {
    public var conversationId: String
    public var title: String
    public var status: String
    public var modelName: String
    public var shortModel: String
    public var usedTokens: Int
    public var maxTokens: Int?
    public var usedPercent: Double?
    public var compactions: Int
    public var totalTokens: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var cacheHitPercent: Double?
    public var tps: Double?
    public var requestCount: Int
    public var errorCount: Int
    public var toolCount: Int
    public var costUsd: Double?

    public var id: String { conversationId }
}

public struct SubagentTotalsSummary: Equatable, Codable, Sendable {
    public var count: Int
    public var totalTokens: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var cacheHitPercent: Double?
    public var requestCount: Int
    public var errorCount: Int
    public var toolCount: Int
    public var costUsd: Double?
    public var combinedTotalTokens: Int
    public var combinedCostUsd: Double?
}

public struct SessionTelemetrySnapshot: Equatable, Codable, Sendable {
    public var conversationId: String
    public var title: String
    public var source: TelemetrySource
    public var modelName: String
    public var stateStamp: String
    public var sessions: [SessionSummaryItem]
    public var contextWindow: ContextWindowSnapshot
    public var telemetry: SessionStatsMetrics
    public var subagents: [SubagentTelemetryItem]
    public var subagentTotals: SubagentTotalsSummary
}

public enum SessionTelemetryLoadResult: Equatable, Sendable {
    case unchanged(stamp: String)
    case loaded(SessionTelemetrySnapshot)
    case empty
}

enum SessionTelemetryEngine {
    static func load(
        requestedId: String? = nil,
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceFilter: TelemetrySourceFilter = .auto,
        pricingMode: PricingMode = .standard,
        pricingFile: URL? = nil,
        knownStamp: String? = nil,
        now: Date = Date(),
        reader: AntigravityDatabaseReader = .shared
    ) -> SessionTelemetryLoadResult {
        let roots = AntigravityDataRoots.resolve(home: home, environment: environment, filter: sourceFilter)
        let summariesByRoot = loadAllSummaries(roots: roots, reader: reader)
        let recent = listRecentConversations(roots: roots, summariesByRoot: summariesByRoot, reader: reader)

        let resolved = resolveTargetConversation(
            requestedId: requestedId,
            environment: environment,
            roots: roots,
            recent: recent
        )
        guard let target = resolved else {
            return .empty
        }

        let stamp = stateStamp(conversationId: target.conversationId, root: target.root)
        if let knownStamp, !knownStamp.isEmpty, knownStamp == stamp {
            return .unchanged(stamp: stamp)
        }

        let rates = PricingCatalog.loadRates(from: pricingFile)
        guard let parsed = parseSingleSession(
            conversationId: target.conversationId,
            root: target.root,
            rates: rates,
            pricingMode: pricingMode,
            now: now,
            reader: reader
        ) else {
            return .empty
        }

        let summaryMap = Dictionary(uniqueKeysWithValues: recent.map { ($0.conversationId, $0) })
        let title = summaryMap[target.conversationId]?.title
            ?? parsed.firstPromptTitle
            ?? target.conversationId

        let subagents = collectSubagents(
            parentId: target.conversationId,
            parentRoot: target.root,
            allRoots: roots,
            summariesByRoot: summariesByRoot,
            parentSteps: parsed.steps,
            rates: rates,
            pricingMode: pricingMode,
            now: now,
            reader: reader
        )
        let totals = aggregateSubagents(
            subagents,
            mainTokens: parsed.telemetry.totalTokens,
            mainCostUsd: parsed.telemetry.costUsd
        )

        return .loaded(SessionTelemetrySnapshot(
            conversationId: target.conversationId,
            title: title,
            source: target.root.source,
            modelName: parsed.modelName,
            stateStamp: stamp,
            sessions: recent,
            contextWindow: parsed.contextWindow,
            telemetry: parsed.telemetry,
            subagents: subagents,
            subagentTotals: totals
        ))
    }

    static func stateStamp(conversationId: String, root: AntigravityDataRoot) -> String {
        guard isValidConversationID(conversationId) else {
            return ""
        }
        let brain = root.brainDirectory.appendingPathComponent(conversationId, isDirectory: true)
        let logs = brain.appendingPathComponent(".system_generated/logs", isDirectory: true)
        let db = root.conversationsDirectory.appendingPathComponent("\(conversationId).db")
        let paths = [
            logs.appendingPathComponent("transcript.jsonl"),
            db,
            URL(fileURLWithPath: db.path + "-wal"),
            logs.appendingPathComponent("telemetry.jsonl"),
            logs.appendingPathComponent("powertools-telemetry.jsonl"),
            brain.appendingPathComponent("task.md"),
        ]
        return paths.map { AntigravityDatabaseReader.fileStamp(at: $0) }.joined(separator: "|")
    }

    static func contextSnapshot(
        generation: DecodedGeneration?,
        fallbackTokens: Int = 0,
        latestCheckpoint: CheckpointSummary? = nil
    ) -> ContextWindowSnapshot {
        let metadata = generation?.context
        let reportedMaxTokens = (metadata?.maxTokens ?? 0) > 0 ? metadata?.maxTokens : nil
        let actual = generation?.providerInputTokens
        let hasActual = actual != nil && (actual ?? 0) > 0
        let estimatedUsedTokens = metadata?.usedTokens
        let baseUsedTokens = hasActual ? (actual ?? 0) : max(0, estimatedUsedTokens ?? fallbackTokens)

        var rawGroups: [ContextCategoryRaw] = []
        for group in metadata?.categories ?? [] {
            if group.label == "System Prompt",
               let skills = group.children.first(where: { $0.label == "skills" })
            {
                let remaining = max(0, group.tokens - skills.tokens)
                if remaining > 0 {
                    rawGroups.append(ContextCategoryRaw(
                        key: group.key,
                        label: group.label,
                        tokens: remaining,
                        children: group.children
                    ))
                }
                if skills.tokens > 0 {
                    rawGroups.append(ContextCategoryRaw(
                        key: "skills",
                        label: "Skills",
                        tokens: skills.tokens,
                        children: []
                    ))
                }
            } else if group.tokens > 0 {
                rawGroups.append(group)
            }
        }

        let genMaxStep = generation?.stepIndices.max() ?? -1
        let isPostCompact: Bool = {
            guard let latestCheckpoint,
                  genMaxStep >= 0,
                  latestCheckpoint.stepIndex > genMaxStep,
                  baseUsedTokens > 0
            else {
                return false
            }
            return true
        }()

        var usedTokens = baseUsedTokens
        var groups = rawGroups
        var compactedPending = false
        var preCompactUsedTokens: Int?
        var preCompactPercent: Double?

        if isPostCompact, let latestCheckpoint {
            let summaryEst = latestCheckpoint.summaryTokens > 0
                ? latestCheckpoint.summaryTokens
                : min(Int((Double(baseUsedTokens) * 0.12).rounded()), 12_000)
            let nonMessages = rawGroups.filter {
                $0.label.range(of: #"^(?:chat\s+)?messages$"#, options: [.regularExpression, .caseInsensitive]) == nil
            }
            let fixedTokens = !nonMessages.isEmpty
                ? nonMessages.reduce(0) { $0 + max(0, $1.tokens) }
                : min(Int((Double(baseUsedTokens) * 0.12).rounded()), 18_000)
            let estTotal = fixedTokens + summaryEst
            if estTotal < baseUsedTokens {
                compactedPending = true
                preCompactUsedTokens = baseUsedTokens
                let baseMax = (reportedMaxTokens != nil && baseUsedTokens <= (reportedMaxTokens ?? 0)) ? reportedMaxTokens : nil
                preCompactPercent = baseMax.map { round1(Double(baseUsedTokens) / Double($0) * 100.0) }
                usedTokens = estTotal
                if !nonMessages.isEmpty {
                    groups = nonMessages + [ContextCategoryRaw(
                        key: "messages-compacted",
                        label: "Chat Messages",
                        tokens: summaryEst,
                        children: []
                    )]
                } else {
                    groups = []
                }
            }
        }

        let maxTokens = (reportedMaxTokens != nil && usedTokens <= (reportedMaxTokens ?? 0)) ? reportedMaxTokens : nil
        func percentOf(_ tokens: Int) -> Double? {
            guard let maxTokens, maxTokens > 0 else {
                return nil
            }
            return round1(Double(tokens) / Double(maxTokens) * 100.0)
        }

        let totalGroupTokens = groups.reduce(0) { $0 + max(0, $1.tokens) }
        var categories: [ContextCategorySlice] = []
        if totalGroupTokens > 0 {
            let apportioned = groups.map { Double(usedTokens) * Double(max(0, $0.tokens)) / Double(totalGroupTokens) }
            var counts = apportioned.map { Int(floor($0)) }
            let order = apportioned.enumerated()
                .map { (index: $0.offset, remainder: $0.element - Double(counts[$0.offset])) }
                .sorted { lhs, rhs in
                    if lhs.remainder != rhs.remainder {
                        return lhs.remainder > rhs.remainder
                    }
                    return lhs.index < rhs.index
                }
            let remaining = max(0, usedTokens - counts.reduce(0, +))
            if remaining > 0, !order.isEmpty {
                for idx in 0 ..< remaining {
                    counts[order[idx % order.count].index] += 1
                }
            }
            categories = groups.enumerated().map { idx, group in
                ContextCategorySlice(
                    key: group.key,
                    label: group.label,
                    tokens: counts[idx],
                    percent: percentOf(counts[idx]),
                    estimated: true
                )
            }
        } else if usedTokens > 0 {
            categories = [
                ContextCategorySlice(
                    key: "input",
                    label: "Input Context",
                    tokens: usedTokens,
                    percent: percentOf(usedTokens),
                    estimated: !hasActual || compactedPending
                )
            ]
        }

        var freePercent: Double?
        if let maxTokens {
            let freeTokens = max(0, maxTokens - usedTokens)
            freePercent = percentOf(freeTokens)
            categories.append(ContextCategorySlice(
                key: "free",
                label: "Free Space",
                tokens: freeTokens,
                percent: freePercent,
                estimated: false,
                isFreeSpace: true
            ))
        }

        let source = compactedPending
            ? "post-compact-estimate"
            : hasActual ? "provider-usage" : metadata != nil ? "client-estimate" : "transcript"

        return ContextWindowSnapshot(
            usedTokens: usedTokens,
            maxTokens: maxTokens,
            reportedMaxTokens: reportedMaxTokens,
            estimatedUsedTokens: estimatedUsedTokens,
            usedPercent: percentOf(usedTokens),
            freePercent: freePercent,
            categories: categories,
            compactedPending: compactedPending,
            preCompactUsedTokens: preCompactUsedTokens,
            preCompactPercent: preCompactPercent,
            compactions: 0,
            hasOrchestrator: false,
            models: [],
            inputTokens: generation?.inputTokens ?? 0,
            cacheReadTokens: generation?.cacheReadTokens ?? 0,
            outputTokens: generation?.outputTokens ?? 0,
            source: source
        )
    }

    static func modelContexts(
        generations: [DecodedGeneration],
        checkpointSteps: [Int],
        postCompactSnapshot: ContextWindowSnapshot? = nil
    ) -> (models: [ModelContextProgress], hasOrchestrator: Bool, compactions: Int) {
        let valid = generations.filter {
            !$0.modelName.isEmpty
                && (($0.providerInputTokens ?? 0) > 0 || ($0.context?.usedTokens ?? 0) > 0)
        }
        let knownExecEnum = valid.first(where: { $0.executionModelEnum != nil })?.executionModelEnum
        let hasOrchestrator = knownExecEnum != nil || valid.contains {
            $0.role == .execution || $0.role == .planner || $0.modelName.range(of: "orchestrator", options: .caseInsensitive) != nil
        }

        var map: [String: ModelContextProgress] = [:]
        var insertionOrder: [String] = []
        var lastKey = ""

        for gen in valid {
            let used = (gen.providerInputTokens ?? 0) > 0 ? (gen.providerInputTokens ?? 0) : (gen.context?.usedTokens ?? 0)
            let rawMax = (gen.context?.maxTokens ?? 0) > 0 ? gen.context?.maxTokens : nil
            let maxTokens = (rawMax != nil && used <= (rawMax ?? 0)) ? rawMax : nil
            let inferredRole: OrchestratorRole = {
                if gen.role != .none { return gen.role }
                if let knownExecEnum, let modelEnum = gen.modelEnum {
                    return modelEnum == knownExecEnum ? .execution : .planner
                }
                return .none
            }()
            let role: OrchestratorRole = hasOrchestrator ? (inferredRole == .none ? .planner : inferredRole) : .none
            let shortName = PricingCatalog.shortModelDisplayName(gen.modelName)
            let key = "\(role == .none ? "" : role.rawValue):\(shortName.lowercased())"
            let prev = map[key]
            var compactions = prev?.compactions ?? 0
            if let prev, prev.usedTokens > 0, Double(used) < Double(prev.usedTokens) * 0.72, prev.usedTokens - used > 30_000 {
                compactions += 1
            }
            let resolvedMax = maxTokens ?? prev?.maxTokens
            let usedPercent = resolvedMax.map { round1(Double(used) / Double($0) * 100.0) }
            if prev == nil {
                insertionOrder.append(key)
            }
            map[key] = ModelContextProgress(
                key: key,
                role: role,
                shortName: shortName,
                fullName: gen.modelName,
                usedTokens: used,
                maxTokens: resolvedMax,
                usedPercent: usedPercent,
                compactions: compactions,
                isCurrent: false
            )
            lastKey = key
        }

        var models: [ModelContextProgress] = insertionOrder.compactMap { key in
            guard var entry = map[key] else {
                return nil
            }
            entry.isCurrent = (key == lastKey)
            if entry.isCurrent, let postCompactSnapshot, postCompactSnapshot.compactedPending, postCompactSnapshot.usedTokens > 0 {
                let resolvedMax = postCompactSnapshot.maxTokens ?? entry.maxTokens
                entry.usedTokens = postCompactSnapshot.usedTokens
                entry.maxTokens = resolvedMax
                entry.usedPercent = resolvedMax.map { round1(Double(entry.usedTokens) / Double($0) * 100.0) } ?? entry.usedPercent
            }
            return entry
        }

        let detectedCompactions = models.reduce(0) { $0 + $1.compactions }
        let compactions = max(checkpointSteps.count, detectedCompactions)
        if models.count == 1, compactions > models[0].compactions {
            models[0].compactions = compactions
        }
        return (models, hasOrchestrator, compactions)
    }

    static func cacheObservation(requests: [RequestEventRecord], now: Date) -> CacheObservationWindow? {
        let nowMs = now.timeIntervalSince1970 * 1000.0
        let latest = requests
            .filter { ($0.timestampMs ?? 0) > 0 && ($0.inputTokens + $0.cacheReadTokens) > 0 && $0.error.isEmpty }
            .max { ($0.timestampMs ?? 0) < ($1.timestampMs ?? 0) }
        guard let latest, let ts = latest.timestampMs else {
            return nil
        }
        let ageMs = nowMs - ts
        guard ageMs >= 0 else {
            return nil
        }
        let total = latest.inputTokens + latest.cacheReadTokens
        guard total > 0 else {
            return nil
        }
        let lowerModel = latest.model.lowercased()
        let windowMs: Double? = (lowerModel.contains("gemini") || lowerModel.contains("claude")) ? 300_000.0 : nil
        return CacheObservationWindow(
            model: latest.model,
            lastRequestAtMs: ts,
            ageMs: ageMs,
            hitPercent: round1(Double(latest.cacheReadTokens) / Double(total) * 100.0),
            assumedWindowMs: windowMs,
            remainingMs: windowMs.map { max(0, $0 - ageMs) }
        )
    }

    static func parseTranscriptSteps(at url: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var steps: [[String: Any]] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                continue
            }
            steps.append(object)
        }
        return steps
    }

    static func cleanPromptTitle(_ content: String) -> String {
        if let start = content.range(of: "<USER_REQUEST>"),
           let end = content.range(of: "</USER_REQUEST>", range: start.upperBound ..< content.endIndex)
        {
            let extracted = String(content[start.upperBound ..< end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstLine = extracted.split(whereSeparator: \.isNewline).first {
                return String(firstLine.prefix(60))
            }
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = trimmed.split(whereSeparator: \.isNewline).first, !firstLine.isEmpty {
            return String(firstLine.prefix(60))
        }
        return ""
    }

    // MARK: - Private parsing helpers

    private struct ParsedSingleSession {
        var modelName: String
        var firstPromptTitle: String?
        var contextWindow: ContextWindowSnapshot
        var telemetry: SessionStatsMetrics
        var steps: [[String: Any]]
    }

    private struct ResolvedConversation {
        var conversationId: String
        var root: AntigravityDataRoot
    }

    private static func loadAllSummaries(
        roots: [AntigravityDataRoot],
        reader: AntigravityDatabaseReader
    ) -> [TelemetrySource: [String: ConversationSummaryRecord]] {
        var result: [TelemetrySource: [String: ConversationSummaryRecord]] = [:]
        for root in roots {
            result[root.source] = reader.readConversationSummaries(at: root.summariesDatabaseURL)
        }
        return result
    }

    private static func listRecentConversations(
        roots: [AntigravityDataRoot],
        summariesByRoot: [TelemetrySource: [String: ConversationSummaryRecord]],
        reader: AntigravityDatabaseReader
    ) -> [SessionSummaryItem] {
        var bestById: [String: (item: SessionSummaryItem, transcriptURL: URL)] = [:]
        var subagentIDs = Set<String>()
        let manager = FileManager.default

        for root in roots {
            let summaries = summariesByRoot[root.source] ?? [:]
            for record in summaries.values where record.nestingDepth > 0 || !record.parentConversationId.isEmpty {
                subagentIDs.insert(record.conversationId)
            }
            for childID in reader.readConversationChildren(at: root.summariesDatabaseURL).values.joined() {
                subagentIDs.insert(childID)
            }

            var candidateIDs = Set<String>()
            if let brainEntries = try? manager.contentsOfDirectory(
                at: root.brainDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for dir in brainEntries where isValidConversationID(dir.lastPathComponent) {
                    candidateIDs.insert(dir.lastPathComponent)
                }
            }
            if let dbFiles = try? manager.contentsOfDirectory(
                at: root.conversationsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for file in dbFiles where file.pathExtension == "db" {
                    let cid = file.deletingPathExtension().lastPathComponent
                    if isValidConversationID(cid) {
                        candidateIDs.insert(cid)
                    }
                }
            }

            for cid in candidateIDs {
                let transcriptURL = root.brainDirectory.appendingPathComponent("\(cid)/.system_generated/logs/transcript.jsonl")
                let dbURL = root.conversationsDirectory.appendingPathComponent("\(cid).db")
                let transcriptMod = modificationMs(transcriptURL)
                let dbMod = max(modificationMs(dbURL), modificationMs(URL(fileURLWithPath: dbURL.path + "-wal")))
                let updatedAtMs = max(transcriptMod, dbMod)
                guard updatedAtMs > 0 else {
                    continue
                }

                let summary = summaries[cid]
                let isSubagent = (summary?.nestingDepth ?? 0) > 0 || !(summary?.parentConversationId.isEmpty ?? true)
                let title: String = {
                    if let t = summary?.title.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        return t
                    }
                    if let firstPrompt = firstUserPromptTitle(at: transcriptURL), !firstPrompt.isEmpty {
                        return firstPrompt
                    }
                    return cid
                }()
                let item = SessionSummaryItem(
                    conversationId: cid,
                    title: title,
                    source: root.source,
                    updatedAtMs: updatedAtMs,
                    isSubagent: isSubagent
                )
                if let existing = bestById[cid] {
                    if item.updatedAtMs > existing.item.updatedAtMs {
                        bestById[cid] = (item, transcriptURL)
                    }
                } else {
                    bestById[cid] = (item, transcriptURL)
                }
            }
        }

        let sortedCandidates = bestById.values.sorted { $0.item.updatedAtMs > $1.item.updatedAtMs }
        for candidate in sortedCandidates.prefix(40) {
            guard let content = try? String(contentsOf: candidate.transcriptURL, encoding: .utf8),
                  content.contains("\"invoke_subagent\"")
            else {
                continue
            }
            let steps = parseTranscriptSteps(at: candidate.transcriptURL)
            for ref in transcriptSubagentReferences(in: steps) where ref.id != candidate.item.conversationId {
                subagentIDs.insert(ref.id)
            }
        }

        return sortedCandidates
            .map { candidate -> SessionSummaryItem in
                var item = candidate.item
                if subagentIDs.contains(item.conversationId) {
                    item.isSubagent = true
                }
                return item
            }
            .filter { !$0.isSubagent }
            .prefix(20)
            .map { $0 }
    }

    private static func resolveTargetConversation(
        requestedId: String?,
        environment: [String: String],
        roots: [AntigravityDataRoot],
        recent: [SessionSummaryItem]
    ) -> ResolvedConversation? {
        if let requestedId = requestedId?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedId.isEmpty {
            guard isValidConversationID(requestedId) else {
                return nil
            }
            return newestRootContaining(conversationId: requestedId, roots: roots)
        }
        if let envId = environment["ANTIGRAVITY_CONVERSATION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValidConversationID(envId),
           let match = newestRootContaining(conversationId: envId, roots: roots)
        {
            return match
        }
        for item in recent {
            if let root = roots.first(where: { $0.source == item.source }) {
                return ResolvedConversation(conversationId: item.conversationId, root: root)
            }
        }
        // Fall back to subagent/DB-only sessions if no top-level transcript exists.
        let manager = FileManager.default
        var candidate: (id: String, root: AntigravityDataRoot, updatedMs: Double)?
        for root in roots {
            guard let files = try? manager.contentsOfDirectory(at: root.conversationsDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "db" {
                let cid = file.deletingPathExtension().lastPathComponent
                guard isValidConversationID(cid) else { continue }
                let mod = max(modificationMs(file), modificationMs(URL(fileURLWithPath: file.path + "-wal")))
                if candidate == nil || mod > (candidate?.updatedMs ?? 0) {
                    candidate = (cid, root, mod)
                }
            }
        }
        return candidate.map { ResolvedConversation(conversationId: $0.id, root: $0.root) }
    }

    private static func newestRootContaining(
        conversationId: String,
        roots: [AntigravityDataRoot]
    ) -> ResolvedConversation? {
        var best: (root: AntigravityDataRoot, updatedMs: Double)?
        let manager = FileManager.default
        for root in roots {
            let transcriptURL = root.brainDirectory.appendingPathComponent("\(conversationId)/.system_generated/logs/transcript.jsonl")
            let dbURL = root.conversationsDirectory.appendingPathComponent("\(conversationId).db")
            let hasTranscript = manager.fileExists(atPath: transcriptURL.path)
            let hasDB = manager.fileExists(atPath: dbURL.path)
            guard hasTranscript || hasDB else {
                continue
            }
            let updatedMs = max(
                modificationMs(transcriptURL),
                max(modificationMs(dbURL), modificationMs(URL(fileURLWithPath: dbURL.path + "-wal")))
            )
            if best == nil || updatedMs > (best?.updatedMs ?? 0) {
                best = (root, updatedMs)
            }
        }
        return best.map { ResolvedConversation(conversationId: conversationId, root: $0.root) }
    }

    private static func parseSingleSession(
        conversationId: String,
        root: AntigravityDataRoot,
        rates: [ModelRate],
        pricingMode: PricingMode,
        now: Date,
        reader: AntigravityDatabaseReader
    ) -> ParsedSingleSession? {
        let transcriptURL = root.brainDirectory.appendingPathComponent("\(conversationId)/.system_generated/logs/transcript.jsonl")
        let dbURL = root.conversationsDirectory.appendingPathComponent("\(conversationId).db")
        let steps = parseTranscriptSteps(at: transcriptURL)
        let db = reader.readConversationDatabase(at: dbURL)
        guard !steps.isEmpty || db != nil else {
            return nil
        }

        var turnCount = 0
        var firstPromptTitle: String?
        var modelName = ""
        var latestInput = 0
        var latestCache = 0
        var latestOutput = 0
        var totalInput = 0
        var totalCache = 0
        var totalOutput = 0
        var toolCount = 0
        var errorStepCount = 0
        var modelTimeMs = 0.0
        var ttfts: [Double] = []
        var toolIntervals: [(Double, Double)] = []

        for idx in 0 ..< steps.count {
            let step = steps[idx]
            let type = step["type"] as? String ?? ""
            let stepIndex = (step["step_index"] as? NSNumber)?.intValue ?? idx
            let timing = db?.times[stepIndex]
            let createdMs = timing?.createdMs ?? parseISODateMs(step["created_at"] as? String)

            if type == "USER_INPUT" {
                let content = step["content"] as? String ?? ""
                if content.range(of: #"^Error: The stream was interrupted"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    continue
                }
                if let selected = extractSelectedModel(from: content) {
                    modelName = selected
                }
                if firstPromptTitle == nil {
                    let cleaned = cleanPromptTitle(content)
                    if !cleaned.isEmpty {
                        firstPromptTitle = cleaned
                    }
                }
                turnCount += 1
                continue
            }

            if type == "ERROR_MESSAGE" {
                errorStepCount += 1
                continue
            }

            if type == "PLANNER_RESPONSE" {
                if let stepModel = step["model"] as? String, !stepModel.isEmpty {
                    modelName = stepModel
                }
                let input = max(0, (step["input_tokens"] as? NSNumber)?.intValue ?? 0)
                let cached = max(0, (step["cache_read_tokens"] as? NSNumber)?.intValue ?? 0)
                let output = max(0, (step["output_tokens"] as? NSNumber)?.intValue ?? 0)
                totalInput += input
                totalCache += cached
                totalOutput += output
                if input + cached + output > 0 {
                    latestInput = input
                    latestCache = cached
                    latestOutput = output
                }
                if let createdMs,
                   let endMs = timing?.finishedMs ?? timing?.completedMs,
                   endMs >= createdMs,
                   output > 0
                {
                    modelTimeMs += (endMs - createdMs)
                    if let viewableMs = timing?.viewableMs, viewableMs >= createdMs {
                        ttfts.append(viewableMs - createdMs)
                    }
                }
                if let calls = step["tool_calls"] as? [[String: Any]] {
                    toolCount += calls.count
                    for c in 0 ..< calls.count {
                        let resultIdx = idx + 1 + c
                        guard resultIdx < steps.count else { continue }
                        let result = steps[resultIdx]
                        let resultStepIdx = (result["step_index"] as? NSNumber)?.intValue ?? resultIdx
                        let resultTiming = db?.times[resultStepIdx]
                        let resultContent = (result["type"] as? String == "GENERIC") ? (result["content"] as? String ?? "") : ""
                        let start = resultTiming?.startedMs ?? extractLabelTimestampMs("Created At", in: resultContent)
                        let end = resultTiming?.completedMs ?? extractLabelTimestampMs("Completed At", in: resultContent)
                        if let start, let end, end >= start {
                            toolIntervals.append((start, end))
                        }
                    }
                }
            }
        }

        let toolTimeMs = mergeIntervalDurationMs(toolIntervals)
        let generations = db?.generations ?? []
        let latestGen = generations.last { $0.context != nil || ($0.providerInputTokens ?? 0) > 0 }
        if let genModel = latestGen?.modelName, !genModel.isEmpty {
            modelName = genModel
        }

        let timedGenerations = generations.filter {
            $0.outputTokens > 0 && ($0.streamingMs ?? 0) > 0 && $0.ttftMs != nil
        }
        if !timedGenerations.isEmpty {
            modelTimeMs = timedGenerations.reduce(0.0) { $0 + ($1.ttftMs ?? 0) + ($1.streamingMs ?? 0) }
            ttfts = timedGenerations.compactMap(\.ttftMs)
        }

        var context = contextSnapshot(
            generation: latestGen,
            fallbackTokens: latestInput + latestCache,
            latestCheckpoint: db?.latestCheckpoint
        )
        let multi = modelContexts(
            generations: generations,
            checkpointSteps: db?.checkpointSteps ?? [],
            postCompactSnapshot: context
        )
        context.models = multi.models
        context.hasOrchestrator = multi.hasOrchestrator
        context.compactions = multi.compactions
        if let latestGen {
            context.inputTokens = latestGen.inputTokens
            context.cacheReadTokens = latestGen.cacheReadTokens
            context.outputTokens = latestGen.outputTokens
        } else {
            context.inputTokens = latestInput
            context.cacheReadTokens = latestCache
            context.outputTokens = latestOutput
        }

        let requests = UsageAnalyticsEngine.requestEvents(
            database: db,
            conversationId: conversationId,
            source: root.source
        )
        let dbInput = requests.reduce(0) { $0 + $1.inputTokens }
        let dbCache = requests.reduce(0) { $0 + $1.cacheReadTokens }
        let dbOutput = requests.reduce(0) { $0 + $1.outputTokens }
        if dbInput + dbCache + dbOutput > 0 {
            totalInput = dbInput
            totalCache = dbCache
            totalOutput = dbOutput
        }
        let totalInputAndCache = totalInput + totalCache
        let totalTokens = totalInputAndCache + totalOutput
        let cacheHitPercent: Double? = totalInputAndCache > 0
            ? round1(Double(totalCache) / Double(totalInputAndCache) * 100.0)
            : nil

        let speeds = requests.compactMap(\.tps)
        let completeRequests = requests.filter { $0.tps != nil && $0.outputTokens > 0 }
        let requestDuration = completeRequests.reduce(0.0) { sum, req in
            let dur = (req.tpsDurationMs ?? 0) > 0 ? (req.tpsDurationMs ?? 0) : (req.durationMs ?? 0)
            return sum + dur
        }
        let avgTps: Double? = requestDuration > 0
            ? round1(Double(completeRequests.reduce(0) { $0 + $1.outputTokens }) * 1000.0 / requestDuration)
            : nil
        let peakTps = speeds.max()
        let latestTps = speeds.last
        let avgTtftMs: Double? = ttfts.isEmpty
            ? nil
            : (ttfts.reduce(0.0, +) / Double(ttfts.count)).rounded()

        var costSum = 0.0
        var pricedCount = 0
        for req in requests {
            if let cost = PricingCatalog.estimateCost(
                model: req.model,
                role: req.role,
                inputTokens: req.inputTokens,
                cacheReadTokens: req.cacheReadTokens,
                outputTokens: req.outputTokens,
                timestampMs: req.timestampMs,
                rates: rates,
                mode: pricingMode,
                now: now
            ) {
                costSum += cost
                pricedCount += 1
            }
        }
        let costUsd: Double? = pricedCount > 0 ? costSum : (requests.isEmpty ? 0.0 : nil)
        let requestErrorCount = requests.filter { !$0.error.isEmpty }.count

        let telemetry = SessionStatsMetrics(
            turnCount: turnCount,
            stepCount: steps.count,
            modelTimeMs: modelTimeMs > 0 ? modelTimeMs : nil,
            toolTimeMs: toolIntervals.isEmpty ? nil : toolTimeMs,
            avgTtftMs: avgTtftMs,
            tps: avgTps,
            peakTps: peakTps,
            latestTps: latestTps,
            requestCount: requests.count,
            errorCount: errorStepCount + requestErrorCount,
            thinkingTokens: requests.reduce(0) { $0 + $1.thinkingTokens },
            toolCount: toolCount,
            totalTokens: totalTokens,
            inputTokens: totalInput,
            cacheReadTokens: totalCache,
            outputTokens: totalOutput,
            cacheHitPercent: cacheHitPercent,
            costUsd: costUsd,
            cacheObservation: cacheObservation(requests: requests, now: now)
        )

        return ParsedSingleSession(
            modelName: modelName.isEmpty ? "Unknown" : modelName,
            firstPromptTitle: firstPromptTitle,
            contextWindow: context,
            telemetry: telemetry,
            steps: steps
        )
    }

    private static func collectSubagents(
        parentId: String,
        parentRoot: AntigravityDataRoot,
        allRoots: [AntigravityDataRoot],
        summariesByRoot: [TelemetrySource: [String: ConversationSummaryRecord]],
        parentSteps: [[String: Any]],
        rates: [ModelRate],
        pricingMode: PricingMode,
        now: Date,
        reader: AntigravityDatabaseReader
    ) -> [SubagentTelemetryItem] {
        var childMeta: [String: (title: String, status: String)] = [:]
        var orderedChildIDs: [String] = []

        func addChild(id: String, title: String, status: String) {
            guard isValidConversationID(id), id != parentId else {
                return
            }
            if let existing = childMeta[id] {
                let mergedTitle = existing.title.isEmpty ? title : existing.title
                let mergedStatus = existing.status.isEmpty ? status : existing.status
                childMeta[id] = (mergedTitle, mergedStatus)
            } else {
                orderedChildIDs.append(id)
                childMeta[id] = (title, status)
            }
        }

        // Source 1: conversation_summaries.db (`parent_conversation_id` + `conversation_parents`).
        for root in allRoots {
            let summaries = summariesByRoot[root.source] ?? [:]
            for record in summaries.values where record.parentConversationId == parentId {
                let status = record.killed ? "killed" : (record.notFullyIdle ? "running" : "done")
                addChild(id: record.conversationId, title: record.title.isEmpty ? record.agentName : record.title, status: status)
            }
            let parentMap = reader.readConversationChildren(at: root.summariesDatabaseURL)
            for cid in parentMap[parentId] ?? [] {
                let summary = summaries[cid]
                let title = summary?.title.isEmpty == false ? (summary?.title ?? "") : (summary?.agentName ?? "")
                let status = (summary?.killed == true) ? "killed" : ((summary?.notFullyIdle == true) ? "running" : "done")
                addChild(id: cid, title: title, status: status)
            }
        }

        // Source 2: Parent transcript `invoke_subagent` calls & tool output conversation IDs.
        for ref in transcriptSubagentReferences(in: parentSteps) {
            addChild(id: ref.id, title: ref.role, status: "done")
        }

        var items: [SubagentTelemetryItem] = []
        for childId in orderedChildIDs {
            guard let resolved = newestRootContaining(conversationId: childId, roots: [parentRoot] + allRoots),
                  let parsed = parseSingleSession(
                      conversationId: childId,
                      root: resolved.root,
                      rates: rates,
                      pricingMode: pricingMode,
                      now: now,
                      reader: reader
                  )
            else {
                continue
            }
            guard parsed.telemetry.stepCount > 0 || parsed.telemetry.requestCount > 0 || parsed.contextWindow.usedTokens > 0 else {
                continue
            }
            let meta = childMeta[childId]
            let title = (meta?.title.isEmpty == false ? meta?.title : nil)
                ?? parsed.firstPromptTitle
                ?? childId
            let modelName = parsed.modelName == "Unknown"
                ? (parsed.contextWindow.models.last?.fullName ?? "Unknown")
                : parsed.modelName
            items.append(SubagentTelemetryItem(
                conversationId: childId,
                title: title,
                status: meta?.status ?? "done",
                modelName: modelName,
                shortModel: PricingCatalog.shortSubagentModelName(modelName),
                usedTokens: parsed.contextWindow.usedTokens,
                maxTokens: parsed.contextWindow.maxTokens,
                usedPercent: parsed.contextWindow.usedPercent,
                compactions: parsed.contextWindow.compactions,
                totalTokens: parsed.telemetry.totalTokens,
                inputTokens: parsed.telemetry.inputTokens,
                cacheReadTokens: parsed.telemetry.cacheReadTokens,
                outputTokens: parsed.telemetry.outputTokens,
                cacheHitPercent: parsed.telemetry.cacheHitPercent,
                tps: parsed.telemetry.tps,
                requestCount: parsed.telemetry.requestCount,
                errorCount: parsed.telemetry.errorCount,
                toolCount: parsed.telemetry.toolCount,
                costUsd: parsed.telemetry.costUsd
            ))
        }
        return items
    }

    private static func aggregateSubagents(
        _ items: [SubagentTelemetryItem],
        mainTokens: Int,
        mainCostUsd: Double?
    ) -> SubagentTotalsSummary {
        var totalTokens = 0
        var inputTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var requestCount = 0
        var errorCount = 0
        var toolCount = 0
        var costSum = 0.0
        var pricedCount = 0

        for item in items {
            totalTokens += item.totalTokens
            inputTokens += item.inputTokens
            cacheReadTokens += item.cacheReadTokens
            outputTokens += item.outputTokens
            requestCount += item.requestCount
            errorCount += item.errorCount
            toolCount += item.toolCount
            if let cost = item.costUsd, cost.isFinite {
                costSum += cost
                pricedCount += 1
            }
        }
        let totalIn = inputTokens + cacheReadTokens
        let cacheHitPercent: Double? = totalIn > 0 ? round1(Double(cacheReadTokens) / Double(totalIn) * 100.0) : nil
        let subCost: Double? = pricedCount > 0 ? costSum : (requestCount == 0 ? 0.0 : nil)
        let combinedCost: Double? = {
            guard let mainCostUsd else { return subCost }
            guard let subCost else { return mainCostUsd }
            return mainCostUsd + subCost
        }()
        return SubagentTotalsSummary(
            count: items.count,
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            cacheHitPercent: cacheHitPercent,
            requestCount: requestCount,
            errorCount: errorCount,
            toolCount: toolCount,
            costUsd: subCost,
            combinedTotalTokens: mainTokens + totalTokens,
            combinedCostUsd: combinedCost
        )
    }

    private static func firstUserPromptTitle(at url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  line.contains("\"USER_INPUT\""),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "USER_INPUT",
                  let prompt = obj["content"] as? String
            else {
                continue
            }
            let title = cleanPromptTitle(prompt)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private static func extractSelectedModel(from content: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"changed setting `Model Selection` from .*? to ([^\n]+?)\."#
        ) else {
            return nil
        }
        let range = NSRange(content.startIndex ..< content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              let subrange = Range(match.range(at: 1), in: content)
        else {
            return nil
        }
        return String(content[subrange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractLabelTimestampMs(_ label: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "\(label):\\s*([^\\r\\n]+)") else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let subrange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return parseISODateMs(String(text[subrange]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func transcriptSubagentReferences(in steps: [[String: Any]]) -> [(id: String, role: String)] {
        var refs: [(id: String, role: String)] = []
        for idx in 0 ..< steps.count {
            let step = steps[idx]
            guard step["type"] as? String == "PLANNER_RESPONSE",
                  let calls = step["tool_calls"] as? [[String: Any]]
            else {
                continue
            }
            for c in 0 ..< calls.count {
                let call = calls[c]
                guard (call["name"] as? String) == "invoke_subagent" else {
                    continue
                }
                let args = call["args"] as? [String: Any] ?? [:]
                let role = (args["Role"] as? String) ?? (args["TypeName"] as? String) ?? "Subagent"
                let resultIdx = idx + 1 + c
                guard resultIdx < steps.count else { continue }
                let resultContent = steps[resultIdx]["content"] as? String ?? ""
                for cid in extractConversationIDs(in: resultContent) {
                    refs.append((id: cid, role: role))
                }
            }
        }
        return refs
    }

    private static func extractConversationIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:conversationId|conversation_id|cascadeId|cascade_id)["':=\s]+([A-Za-z0-9][A-Za-z0-9_-]{7,127})"#
        ) else {
            return []
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var ids: [String] = []
        for match in regex.matches(in: text, options: [], range: range) {
            if let sub = Range(match.range(at: 1), in: text) {
                let candidate = String(text[sub])
                if !ids.contains(candidate) {
                    ids.append(candidate)
                }
            }
        }
        return ids
    }

    static func mergeIntervalDurationMs(_ intervals: [(Double, Double)]) -> Double {
        guard !intervals.isEmpty else {
            return 0
        }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total = 0.0
        var current = sorted[0]
        for next in sorted.dropFirst() {
            if next.0 > current.1 {
                total += current.1 - current.0
                current = next
            } else {
                current.1 = max(current.1, next.1)
            }
        }
        total += current.1 - current.0
        return total
    }

    private static func parseISODateMs(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date.timeIntervalSince1970 * 1000.0
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text).map { $0.timeIntervalSince1970 * 1000.0 }
    }

    private static func modificationMs(_ url: URL) -> Double {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0 else {
            return 0
        }
        return Double(st.st_mtimespec.tv_sec) * 1000.0 + Double(st.st_mtimespec.tv_nsec) / 1_000_000.0
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }
}

// MARK: - CLI text formatting

func formatSessionTelemetry(_ snapshot: SessionTelemetrySnapshot, text: Localizer) -> [String] {
    var lines: [String] = []
    let sourceTag = snapshot.source.rawValue.uppercased()
    lines.append("\(snapshot.title)  [\(sourceTag)]  \(snapshot.conversationId)")
    lines.append("\(text.line(.telemetryModelLabel)): \(snapshot.modelName)")
    lines.append("")

    let cw = snapshot.contextWindow
    let pctText = cw.usedPercent.map { "\(cw.compactedPending ? "≈" : "")\(formatPercent($0))" } ?? "—"
    let capText = cw.maxTokens.map { "\(cw.compactedPending ? "≈" : "")\(formatCompactTokens(cw.usedTokens)) / \(formatCompactTokens($0))" }
        ?? "\(cw.compactedPending ? "≈" : "")\(formatCompactTokens(cw.usedTokens))"
    var cwHeader = "\(text.line(.telemetryContextHeader))  \(pctText)  (\(capText))"
    if cw.compactedPending {
        cwHeader += "  [\(text.line(.telemetryCompactedEst))]"
    } else if cw.compactions > 0 {
        cwHeader += "  [\(text.line(.telemetryCompactedCount, String(cw.compactions)))]"
    }
    lines.append(cwHeader)

    for category in cw.categories {
        let name = localizedTelemetryCategory(category.label, text: text)
        let pct = category.percent.map { formatPercent($0) } ?? "—"
        lines.append("  \(name): \(formatCompactTokens(category.tokens)) (\(pct))")
    }
    let stepInputTotal = cw.cacheReadTokens + cw.inputTokens
    if stepInputTotal > 0 {
        let cachedPct = formatPercent(Double(cw.cacheReadTokens) / Double(stepInputTotal) * 100.0)
        let freshPct = formatPercent(Double(cw.inputTokens) / Double(stepInputTotal) * 100.0)
        lines.append("  \(text.line(.telemetryCachedContext)): \(formatCompactTokens(cw.cacheReadTokens)) (\(cachedPct))")
        lines.append("  \(text.line(.telemetryNewInput)): \(formatCompactTokens(cw.inputTokens)) (\(freshPct))")
    }
    if cw.hasOrchestrator, cw.models.count > 1 {
        lines.append("  \(text.line(.telemetryOrchestrator)):")
        for model in cw.models {
            let roleTag = model.role == .execution ? text.line(.telemetryRoleExec) : text.line(.telemetryRolePlan)
            let mPct = model.usedPercent.map { formatPercent($0) } ?? "—"
            let mCap = model.maxTokens.map { "\(formatCompactTokens(model.usedTokens)) / \(formatCompactTokens($0))" }
                ?? formatCompactTokens(model.usedTokens)
            lines.append("    [\(roleTag)] \(model.shortName): \(mPct) (\(mCap))")
        }
    }

    lines.append("")
    let stats = snapshot.telemetry
    lines.append(text.line(.telemetryStatsHeader))
    lines.append("  \(text.line(.telemetryTurnsSteps)): \(stats.turnCount) / \(stats.stepCount)")
    lines.append("  \(text.line(.telemetryTotalTokens)): \(formatCompactTokens(stats.totalTokens))")
    if let cost = stats.costUsd {
        lines.append("  \(text.line(.telemetryApiCost)): \(formatUSD(cost))")
    }
    lines.append("  \(text.line(.telemetryAvgSpeed)): \(stats.tps.map { "\(formatOneDecimal($0)) tok/s" } ?? "—")")
    lines.append("  \(text.line(.telemetryPeakSpeed)): \(stats.peakTps.map { "\(formatOneDecimal($0)) tok/s" } ?? "—")")
    lines.append("  \(text.line(.telemetryLatestSpeed)): \(stats.latestTps.map { "\(formatOneDecimal($0)) tok/s" } ?? "—")")
    lines.append("  \(text.line(.telemetryCacheHit)): \(stats.cacheHitPercent.map { formatPercent($0) } ?? "—")")
    if let obs = stats.cacheObservation {
        let obsValue: String
        if let rem = obs.remainingMs, rem > 0 {
            let sec = Int(ceil(rem / 1000.0))
            obsValue = String(format: "≈ %d:%02d", sec / 60, sec % 60)
        } else {
            obsValue = text.line(.telemetryCacheUnconfirmed)
        }
        lines.append("  \(text.line(.telemetryCacheWindow)): \(obsValue)")
    }
    lines.append("  \(text.line(.telemetryModelTime)): \(formatDurationMs(stats.modelTimeMs, text: text))")
    lines.append("  \(text.line(.telemetryToolTime)): \(formatDurationMs(stats.toolTimeMs, text: text))")
    lines.append("  \(text.line(.telemetryTtft)): \(formatDurationMs(stats.avgTtftMs, text: text))")

    if !snapshot.subagents.isEmpty {
        lines.append("")
        lines.append("\(text.line(.telemetrySubagentsHeader)) (\(snapshot.subagents.count))")
        for sub in snapshot.subagents {
            let sPct = sub.usedPercent.map { formatPercent($0) } ?? "—"
            let sCap = sub.maxTokens.map { "\(formatCompactTokens(sub.usedTokens)) / \(formatCompactTokens($0))" }
                ?? formatCompactTokens(sub.usedTokens)
            lines.append("  \(sub.title) [\(sub.shortModel.isEmpty ? sub.modelName : sub.shortModel)]: \(sPct) (\(sCap))")
        }
        let totals = snapshot.subagentTotals
        lines.append("  \(text.line(.telemetrySubagentTokens)): \(formatCompactTokens(totals.totalTokens))")
        lines.append("  \(text.line(.telemetryCombinedTokens)): \(formatCompactTokens(totals.combinedTotalTokens))")
        lines.append("  \(text.line(.telemetryReqTools)): \(totals.requestCount) / \(totals.toolCount)")
        if let subHit = totals.cacheHitPercent {
            lines.append("  \(text.line(.telemetrySubagentCache)): \(formatPercent(subHit))")
        }
        if let subCost = totals.costUsd {
            lines.append("  \(text.line(.telemetrySubagentCost)): \(formatUSD(subCost))")
        }
        if let combCost = totals.combinedCostUsd {
            lines.append("  \(text.line(.telemetryCombinedCost)): \(formatUSD(combCost))")
        }
    }

    return lines
}

public func localizedTelemetryCategory(_ raw: String, text: Localizer) -> String {
    switch raw {
    case "Chat Messages": return text.line(.telemetryCatMessages)
    case "System Prompt": return text.line(.telemetryCatSystem)
    case "Tools": return text.line(.telemetryCatTools)
    case "Skills": return text.line(.telemetryCatSkills)
    case "Subagents": return text.line(.telemetryCatSubagents)
    case "Plugins": return text.line(.telemetryCatPlugins)
    case "MCP Tools", "MCP tools": return "MCP Tools"
    case "Rules": return text.line(.telemetryCatRules)
    case "Memories", "Memory files": return text.line(.telemetryCatMemories)
    case "Unspecified": return text.line(.telemetryCatOther)
    case "Input Context": return text.line(.telemetryCatInput)
    case "Free Space": return text.line(.telemetryCatFree)
    default: return raw
    }
}

public func formatCompactTokens(_ count: Int) -> String {
    let value = Double(max(0, count))
    if value >= 1_000_000_000 {
        return String(format: "%.2fB", value / 1_000_000_000.0)
    }
    if value >= 1_000_000 {
        return String(format: "%.2fM", value / 1_000_000.0)
    }
    if value >= 1000 {
        return String(format: "%.1fk", value / 1000.0)
    }
    return "\(max(0, count))"
}

public func formatPercent(_ pct: Double) -> String {
    String(format: "%.1f%%", pct)
}

public func formatOneDecimal(_ value: Double) -> String {
    String(format: "%.1f", value)
}

public func formatUSD(_ value: Double) -> String {
    if value != 0, abs(value) < 0.01 {
        return String(format: "$%.4f", value)
    }
    return String(format: "$%.2f", value)
}

public func formatDurationMs(_ ms: Double?, text: Localizer) -> String {
    guard let ms, ms.isFinite, ms >= 0 else {
        return "—"
    }
    let totalSec = Int(ms / 1000.0)
    if totalSec >= 60 {
        return text.line(.telemetryDurationMinSec, String(totalSec / 60), String(totalSec % 60))
    }
    let rounded = Int((ms / 1000.0).rounded())
    return text.line(.telemetryDurationSec, String(max(0, rounded)))
}
