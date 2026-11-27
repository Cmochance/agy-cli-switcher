import Foundation

public enum UsageRangePreset: String, CaseIterable, Codable, Sendable {
    case weekly
    case today
    case last24h = "24h"
    case yesterday
    case week
    case month
    case last30d = "30d"
    case all

    public static func parse(_ token: String) -> UsageRangePreset? {
        let lower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "weekly", "weeklyquota":
            return .weekly
        case "today":
            return .today
        case "24h":
            return .last24h
        case "yesterday":
            return .yesterday
        case "week":
            return .week
        case "month":
            return .month
        case "30d":
            return .last30d
        case "all":
            return .all
        default:
            return nil
        }
    }
}

public enum HeatmapMetric: String, CaseIterable, Codable, Sendable {
    case tokens
    case requests
    case cost
}

public struct RequestEventRecord: Equatable, Codable, Sendable {
    public var id: String
    public var conversationId: String
    public var stepIndex: Int?
    public var timestampMs: Double?
    public var model: String
    public var role: OrchestratorRole
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var thinkingTokens: Int
    public var responseTokens: Int
    public var ttftMs: Double?
    public var streamingMs: Double?
    public var durationMs: Double?
    public var tpsDurationMs: Double?
    public var tps: Double?
    public var error: String
    public var retryErrors: [String]
    public var status: String
    public var source: TelemetrySource
    public var accountEmail: String
    public var costUsd: Double?
}

public struct SparklinePoint: Equatable, Codable, Sendable {
    public var tokens: Int
    public var requests: Int
    public var cost: Double
}

public struct HeatmapCell: Equatable, Codable, Identifiable, Sendable {
    public var index: Int
    public var label: String
    public var tokens: Int
    public var requests: Int
    public var cost: Double
    public var tokenLevel: Int
    public var requestLevel: Int
    public var costLevel: Int

    public var id: Int { index }

    public func level(for metric: HeatmapMetric) -> Int {
        switch metric {
        case .tokens: return tokenLevel
        case .requests: return requestLevel
        case .cost: return costLevel
        }
    }

    public func value(for metric: HeatmapMetric) -> Double {
        switch metric {
        case .tokens: return Double(tokens)
        case .requests: return Double(requests)
        case .cost: return cost
        }
    }
}

public struct ModelHealthBucket: Equatable, Codable, Identifiable, Sendable {
    public var index: Int
    public var good: Int
    public var errors: Int
    public var total: Int

    public var id: Int { index }
}

public struct ModelHealthRow: Equatable, Codable, Identifiable, Sendable {
    public var modelId: String
    public var requests: Int
    public var success: Int
    public var errors: Int
    public var tokens: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var cacheHitPercent: Double?
    public var costUsd: Double?
    public var avgTps: Double?
    public var peakTps: Double?
    public var successPercent: Int?
    public var buckets: [ModelHealthBucket]

    public var id: String { modelId }
}

public struct AccountFilterOption: Equatable, Codable, Identifiable, Sendable {
    public var key: String
    public var label: String

    public var id: String { key }

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

public struct UsageOverviewSnapshot: Equatable, Codable, Sendable {
    public var range: UsageRangePreset
    public var accountFilter: String
    public var sourceFilter: TelemetrySourceFilter
    public var pricingMode: PricingMode
    public var rangeStartMs: Double
    public var rangeEndMs: Double
    public var rangeSubtitle: String
    public var accountOptions: [AccountFilterOption]
    public var totalRequests: Int
    public var successCount: Int
    public var errorCount: Int
    public var totalTokens: Int
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var cacheHitPercent: Double?
    public var totalCostUsd: Double?
    public var avgCostUsd: Double?
    public var pricedCount: Int
    public var overallSuccessPercent: Int?
    public var sparkline: [SparklinePoint]
    public var heatmapCells: [HeatmapCell]
    public var heatmapTicks: [String]
    public var models: [ModelHealthRow]
}

enum UsageAnalyticsEngine {
    private static let archiveRetentionMs: Double = 90.0 * 86_400_000.0
    private static let archiveMaxRequests = 20_000
    private static let dayMs: Double = 86_400_000.0
    private static let weekMs: Double = 7.0 * 86_400_000.0

    private struct DBCacheEntry: Codable {
        var stamp: String
        var conversationId: String
        var source: TelemetrySource
        var events: [RequestEventRecord]
    }

    private struct WeeklyPoolWindow {
        enum State {
            case active(startMs: Double, resetMs: Double)
            case unstarted(startMs: Double)
            case expired(resetMs: Double)
        }
        var poolKey: String
        var label: String
        var state: State
    }

    static func loadOverview(
        home: URL,
        profile: ToolProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        range: UsageRangePreset = .weekly,
        accountFilter: String? = nil,
        sourceFilter: TelemetrySourceFilter = .all,
        pricingMode: PricingMode = .standard,
        now: Date = Date(),
        calendar: Calendar = .current,
        reader: AntigravityDatabaseReader = .shared
    ) -> UsageOverviewSnapshot {
        let locations = ToolLocations(home: home, provider: .antigravity)
        let roots = AntigravityDataRoots.resolve(home: home, environment: environment, filter: sourceFilter)
        let rates = PricingCatalog.loadRates(from: locations.pricingFile)
        let timeline = AccountTimelineStore(fileURL: locations.accountTimelineFile).load()

        let rawEvents = collectEvents(
            roots: roots,
            locations: locations,
            nowMs: now.timeIntervalSince1970 * 1000.0,
            reader: reader
        )

        let annotated: [RequestEventRecord] = rawEvents.map { event in
            var copy = event
            if copy.accountEmail.isEmpty {
                copy.accountEmail = event.timestampMs.map {
                    AccountTimelineStore.email(atMs: Int64($0), in: timeline)
                } ?? ""
            }
            copy.costUsd = PricingCatalog.estimateCost(
                model: copy.model,
                role: copy.role,
                inputTokens: copy.inputTokens,
                cacheReadTokens: copy.cacheReadTokens,
                outputTokens: copy.outputTokens,
                timestampMs: copy.timestampMs,
                rates: rates,
                mode: pricingMode,
                now: now
            )
            return copy
        }

        let activeEmail = resolveActiveEmail(profile: profile, timeline: timeline)
        let knownAccounts = buildAccountOptions(profile: profile, events: annotated, timeline: timeline)
        let hasUnattributed = annotated.contains { $0.accountEmail.isEmpty }

        let resolvedFilter = resolveAccountFilter(
            requested: accountFilter,
            activeEmail: activeEmail,
            events: annotated,
            profile: profile,
            knownEmails: knownAccounts.map(\.key)
        )

        let scopedEvents: [RequestEventRecord] = {
            switch resolvedFilter {
            case "all":
                return annotated
            case "__unattributed__":
                return annotated.filter { $0.accountEmail.isEmpty }
            default:
                return annotated.filter { $0.accountEmail.caseInsensitiveCompare(resolvedFilter) == .orderedSame }
            }
        }()

        let nowMs = now.timeIntervalSince1970 * 1000.0
        let oldestTimestampMs = scopedEvents.compactMap(\.timestampMs).min() ?? nowMs
        let rangeEmail: String = {
            if resolvedFilter == "all" {
                return range == .weekly ? activeEmail : ""
            }
            return resolvedFilter == "__unattributed__" ? "" : resolvedFilter
        }()

        let resolvedWindow = resolveWindow(
            preset: range,
            now: now,
            nowMs: nowMs,
            calendar: calendar,
            oldestTimestampMs: oldestTimestampMs,
            targetEmail: rangeEmail,
            profile: profile
        )

        let matchedEvents = scopedEvents.filter { event in
            guard let ts = event.timestampMs, ts.isFinite else {
                return false
            }
            return resolvedWindow.matches(event, ts)
        }

        return aggregateSnapshot(
            events: matchedEvents,
            range: range,
            accountFilter: resolvedFilter,
            sourceFilter: sourceFilter,
            pricingMode: pricingMode,
            startMs: resolvedWindow.startMs,
            endMs: resolvedWindow.endMs,
            subtitle: resolvedWindow.subtitle,
            accountOptions: makeFilterOptions(accounts: knownAccounts, hasUnattributed: hasUnattributed),
            now: now,
            calendar: calendar
        )
    }

    static func requestEvents(
        database: ConversationDatabaseSnapshot?,
        conversationId: String,
        source: TelemetrySource
    ) -> [RequestEventRecord] {
        guard let database else {
            return []
        }
        let generations = database.generations.filter {
            !$0.modelName.isEmpty || !$0.error.isEmpty || $0.outputTokens > 0
        }
        let knownExecEnum = generations.first(where: { $0.executionModelEnum != nil })?.executionModelEnum

        return generations.map { gen in
            let createdTimes = gen.stepIndices.compactMap { database.times[$0]?.createdMs }.filter(\.isFinite)
            let timestampMs = createdTimes.min()
            let role: OrchestratorRole = {
                if gen.role != .none { return gen.role }
                if let knownExecEnum, let modelEnum = gen.modelEnum {
                    return modelEnum == knownExecEnum ? .execution : .planner
                }
                return .none
            }()
            let durationMs: Double? = {
                guard let ttft = gen.ttftMs, let streaming = gen.streamingMs else {
                    return nil
                }
                return ttft + streaming
            }()
            let isStreamed = (gen.streamingMs ?? 0) >= 500.0 && gen.outputTokens >= 20
            let tpsDurationMs = isStreamed ? gen.streamingMs : durationMs
            let tps: Double? = {
                guard let dur = tpsDurationMs, dur > 0, gen.outputTokens > 0 else {
                    return nil
                }
                return round1(Double(gen.outputTokens) * 1000.0 / dur)
            }()
            let stepIndex = gen.stepIndices.min()
            let id = !gen.requestId.isEmpty
                ? gen.requestId
                : "\(gen.executionId):\(gen.index):\(timestampMs.map { String(Int64($0)) } ?? "0"):\(gen.modelName)"
            let cleanError = sanitizeText(gen.error, maxLength: 240)
            let cleanRetries = gen.retryErrors.map { sanitizeText($0, maxLength: 240) }.filter { !$0.isEmpty }
            let status = !cleanError.isEmpty ? "error" : (gen.outputTokens > 0 ? "success" : "recorded")

            return RequestEventRecord(
                id: id,
                conversationId: conversationId,
                stepIndex: stepIndex,
                timestampMs: timestampMs,
                model: sanitizeText(gen.modelName, maxLength: 120),
                role: role,
                inputTokens: gen.inputTokens,
                cacheReadTokens: gen.cacheReadTokens,
                outputTokens: gen.outputTokens,
                thinkingTokens: gen.thinkingTokens,
                responseTokens: gen.responseTokens,
                ttftMs: gen.ttftMs,
                streamingMs: gen.streamingMs,
                durationMs: durationMs,
                tpsDurationMs: tpsDurationMs,
                tps: tps,
                error: cleanError,
                retryErrors: cleanRetries,
                status: status,
                source: source,
                accountEmail: "",
                costUsd: nil
            )
        }
    }

    // MARK: - Collection, incremental DB cache & 90-day archive

    private static func collectEvents(
        roots: [AntigravityDataRoot],
        locations: ToolLocations,
        nowMs: Double,
        reader: AntigravityDatabaseReader
    ) -> [RequestEventRecord] {
        var dbCache = loadDBCache(from: locations.telemetryCacheFile)
        var dbCacheDirty = false
        var activeCacheKeys = Set<String>()

        var uniqueById: [String: RequestEventRecord] = [:]
        var parsedConversationIDs = Set<String>()
        var liveEvents: [RequestEventRecord] = []

        let manager = FileManager.default
        for root in roots {
            let convDir = root.conversationsDirectory
            guard let files = try? manager.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "db" {
                let cid = file.deletingPathExtension().lastPathComponent
                guard isValidConversationID(cid) else {
                    continue
                }
                let stamp = AntigravityDatabaseReader.databaseStamp(at: file)
                let cacheKey = file.path
                activeCacheKeys.insert(cacheKey)

                let events: [RequestEventRecord]
                if let cached = dbCache[cacheKey], !stamp.isEmpty, cached.stamp == stamp {
                    events = cached.events
                } else if let db = reader.readConversationDatabase(at: file) {
                    events = requestEvents(database: db, conversationId: cid, source: root.source)
                    if !stamp.isEmpty {
                        dbCache[cacheKey] = DBCacheEntry(
                            stamp: stamp,
                            conversationId: cid,
                            source: root.source,
                            events: events
                        )
                        dbCacheDirty = true
                    }
                } else {
                    continue
                }

                parsedConversationIDs.insert(cid)
                liveEvents.append(contentsOf: events)
                for event in events {
                    if let existing = uniqueById[event.id] {
                        if richnessScore(event) > richnessScore(existing) {
                            uniqueById[event.id] = event
                        }
                    } else {
                        uniqueById[event.id] = event
                    }
                }
            }
        }

        let trimmedCache = dbCache.filter { activeCacheKeys.contains($0.key) }
        if dbCacheDirty || trimmedCache.count != dbCache.count {
            saveDBCache(trimmedCache, to: locations.telemetryCacheFile)
        }

        let archived = mergeHistoryArchive(
            archiveURL: locations.usageHistoryArchiveFile,
            parsedConversationIDs: parsedConversationIDs,
            liveEvents: Array(uniqueById.values),
            nowMs: nowMs
        )
        for event in archived where !parsedConversationIDs.contains(event.conversationId) {
            if uniqueById[event.id] == nil {
                uniqueById[event.id] = event
            }
        }

        return uniqueById.values.sorted { ($0.timestampMs ?? 0) > ($1.timestampMs ?? 0) }
    }

    private static func richnessScore(_ event: RequestEventRecord) -> Int {
        var score = 0
        if event.timestampMs != nil { score += 4 }
        if event.tps != nil { score += 2 }
        if !event.model.isEmpty { score += 1 }
        if event.source == .cli { score += 1 }
        return score
    }

    private static func loadDBCache(from url: URL) -> [String: DBCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: DBCacheEntry].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func saveDBCache(_ cache: [String: DBCacheEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cache) else {
            return
        }
        try? AtomicFile.write(url, String(decoding: data, as: UTF8.self) + "\n")
    }

    private static func mergeHistoryArchive(
        archiveURL: URL,
        parsedConversationIDs: Set<String>,
        liveEvents: [RequestEventRecord],
        nowMs: Double
    ) -> [RequestEventRecord] {
        var previous: [RequestEventRecord] = []
        if let data = try? Data(contentsOf: archiveURL),
           let decoded = try? JSONDecoder().decode([RequestEventRecord].self, from: data)
        {
            previous = decoded
        }

        let cutoff = nowMs - archiveRetentionMs
        let retained = previous.filter { event in
            guard let ts = event.timestampMs, ts >= cutoff else {
                return false
            }
            return !parsedConversationIDs.contains(event.conversationId)
        }
        let fresh = liveEvents.filter { ($0.timestampMs ?? 0) >= cutoff }
        let combined = (fresh + retained)
            .sorted { ($0.timestampMs ?? 0) > ($1.timestampMs ?? 0) }
        let capped = combined.count > archiveMaxRequests
            ? Array(combined.prefix(archiveMaxRequests))
            : combined

        if capped != previous {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(capped) {
                try? AtomicFile.write(archiveURL, String(decoding: data, as: UTF8.self) + "\n")
            }
        }
        return capped
    }

    // MARK: - Window & account resolution

    private struct ResolvedWindow {
        var startMs: Double
        var endMs: Double
        var subtitle: String
        var matches: (RequestEventRecord, Double) -> Bool
    }

    private static func resolveWindow(
        preset: UsageRangePreset,
        now: Date,
        nowMs: Double,
        calendar: Calendar,
        oldestTimestampMs: Double,
        targetEmail: String,
        profile: ToolProfile
    ) -> ResolvedWindow {
        if preset == .weekly {
            return resolveWeeklyWindow(nowMs: nowMs, targetEmail: targetEmail, profile: profile)
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfTodayMs = startOfToday.timeIntervalSince1970 * 1000.0
        switch preset {
        case .today:
            return ResolvedWindow(startMs: startOfTodayMs, endMs: nowMs, subtitle: "today") { _, ts in
                ts >= startOfTodayMs && ts < nowMs
            }
        case .last24h:
            let startMs = nowMs - dayMs
            return ResolvedWindow(startMs: startMs, endMs: nowMs, subtitle: "24h") { _, ts in
                ts >= startMs && ts < nowMs
            }
        case .yesterday:
            let startDate = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? Date(timeIntervalSince1970: (startOfTodayMs - dayMs) / 1000.0)
            let startMs = startDate.timeIntervalSince1970 * 1000.0
            return ResolvedWindow(startMs: startMs, endMs: startOfTodayMs, subtitle: "yesterday") { _, ts in
                ts >= startMs && ts < startOfTodayMs
            }
        case .week:
            let weekday = calendar.component(.weekday, from: startOfToday)
            let daysSinceMonday = (weekday + 5) % 7
            let startDate = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday) ?? startOfToday
            let startMs = startDate.timeIntervalSince1970 * 1000.0
            return ResolvedWindow(startMs: startMs, endMs: nowMs, subtitle: "week") { _, ts in
                ts >= startMs && ts < nowMs
            }
        case .month:
            var components = calendar.dateComponents([.year, .month], from: startOfToday)
            components.day = 1
            let startDate = calendar.date(from: components) ?? startOfToday
            let startMs = startDate.timeIntervalSince1970 * 1000.0
            return ResolvedWindow(startMs: startMs, endMs: nowMs, subtitle: "month") { _, ts in
                ts >= startMs && ts < nowMs
            }
        case .last30d:
            let startDate = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            let startMs = startDate.timeIntervalSince1970 * 1000.0
            return ResolvedWindow(startMs: startMs, endMs: nowMs, subtitle: "30d") { _, ts in
                ts >= startMs && ts < nowMs
            }
        case .all:
            let startMs = min(oldestTimestampMs, nowMs)
            return ResolvedWindow(startMs: startMs, endMs: nowMs, subtitle: "all") { _, ts in
                ts >= startMs && ts <= nowMs
            }
        case .weekly:
            return resolveWeeklyWindow(nowMs: nowMs, targetEmail: targetEmail, profile: profile)
        }
    }

    private static func resolveWeeklyWindow(
        nowMs: Double,
        targetEmail: String,
        profile: ToolProfile
    ) -> ResolvedWindow {
        let usageMatch = loadWeeklyUsageSnapshot(targetEmail: targetEmail, profile: profile)
        var pools: [String: WeeklyPoolWindow] = [:]

        if let snapshot = usageMatch.snapshot {
            for bucket in snapshot.buckets where bucket.id == "gemini-weekly" || bucket.id == "3p-weekly" {
                let poolKey = bucket.id == "3p-weekly" ? "claude" : "gemini"
                let label = bucket.id == "3p-weekly" ? "Claude / GPT" : "Gemini"
                let resetDate = parseTimestamp(bucket.resetTime)
                let resetMs = resetDate.map { $0.timeIntervalSince1970 * 1000.0 }
                let state: WeeklyPoolWindow.State
                if let resetMs, resetMs.isFinite {
                    if resetMs > nowMs {
                        state = .active(startMs: resetMs - weekMs, resetMs: resetMs)
                    } else {
                        state = .expired(resetMs: resetMs)
                    }
                } else if bucket.remaining >= 1.0 {
                    let startMs = (usageMatch.fetchedAtMs ?? nowMs)
                    state = .unstarted(startMs: min(startMs, nowMs))
                } else {
                    state = .expired(resetMs: nowMs - weekMs)
                }
                pools[poolKey] = WeeklyPoolWindow(poolKey: poolKey, label: label, state: state)
            }
        }

        let activeStarts = pools.values.compactMap { pool -> (Double, Double)? in
            if case .active(let startMs, let resetMs) = pool.state {
                return (startMs, resetMs)
            }
            return nil
        }

        let fallbackStart = nowMs - weekMs
        let overallStart: Double
        let subtitle: String
        if let minStart = activeStarts.map(\.0).min(), let minReset = activeStarts.map(\.1).min() {
            overallStart = minStart
            subtitle = "weekly-active:\(Int64(minReset))"
        } else if !pools.isEmpty, pools.values.allSatisfy({
            switch $0.state {
            case .unstarted, .expired: return true
            case .active: return false
            }
        }) {
            let candidateStarts = pools.values.compactMap { pool -> Double? in
                switch pool.state {
                case .unstarted(let s): return s
                case .expired(let r): return r
                case .active: return nil
                }
            }
            overallStart = candidateStarts.min() ?? fallbackStart
            subtitle = "weekly-unstarted"
        } else {
            overallStart = fallbackStart
            subtitle = "weekly-fallback"
        }

        return ResolvedWindow(startMs: overallStart, endMs: nowMs, subtitle: subtitle) { event, ts in
            let billedAt = ts + ((event.durationMs ?? 0) > 0 ? (event.durationMs ?? 0) : 0)
            guard billedAt <= nowMs else {
                return false
            }
            guard !pools.isEmpty else {
                return billedAt >= overallStart
            }
            let poolKey = requestQuotaPoolKey(event.model)
            if let pool = pools[poolKey] {
                switch pool.state {
                case .active(let startMs, _):
                    return billedAt >= startMs
                case .expired(let resetMs):
                    return billedAt >= resetMs
                case .unstarted(let startMs):
                    return billedAt >= startMs
                }
            }
            return billedAt >= overallStart
        }
    }

    private static func requestQuotaPoolKey(_ modelLabel: String) -> String {
        let lower = modelLabel.lowercased()
        if lower.contains("claude") || lower.contains("gpt") {
            return "claude"
        }
        if lower.contains("gemini") || lower.contains("orchestrator") {
            return "gemini"
        }
        return ""
    }

    private static func loadWeeklyUsageSnapshot(
        targetEmail: String,
        profile: ToolProfile
    ) -> (snapshot: UsageSnapshot?, fetchedAtMs: Double?) {
        let locations = ToolLocations(home: profile.home, provider: .antigravity)
        let candidateNames: [String]
        if !targetEmail.isEmpty {
            candidateNames = profile.slots(forEmail: targetEmail)
        } else {
            let active = profile.activeName()
            candidateNames = active.isEmpty ? [] : [active]
        }

        for name in candidateNames {
            let email = targetEmail.isEmpty ? ((try? profile.read(name).email) ?? "") : targetEmail
            guard !email.isEmpty,
                  let data = try? Data(contentsOf: locations.usageURL(name)),
                  let snapshot = decodeUsage(data, email: email)
            else {
                continue
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let fetchedAt = (object?["fetched_at"] as? String).flatMap(parseTimestamp)
            return (snapshot, fetchedAt.map { $0.timeIntervalSince1970 * 1000.0 })
        }
        return (nil, nil)
    }

    private static func resolveActiveEmail(profile: ToolProfile, timeline: [AccountTimelineEntry]) -> String {
        let activeName = profile.activeName()
        if !activeName.isEmpty, let email = try? profile.read(activeName).email {
            let normalized = AccountTimelineStore.normalizeEmail(email)
            if !normalized.isEmpty {
                return normalized
            }
        }
        if let latest = timeline.last?.email, !latest.isEmpty {
            return latest
        }
        if let first = profile.names().first, let email = try? profile.read(first).email {
            return AccountTimelineStore.normalizeEmail(email)
        }
        return ""
    }

    private static func buildAccountOptions(
        profile: ToolProfile,
        events: [RequestEventRecord],
        timeline: [AccountTimelineEntry]
    ) -> [(key: String, label: String)] {
        var seen = Set<String>()
        var result: [(key: String, label: String)] = []

        func appendEmail(_ raw: String, preferredName: String? = nil) {
            let email = AccountTimelineStore.normalizeEmail(raw)
            guard !email.isEmpty, seen.insert(email).inserted else {
                return
            }
            let label = preferredName.map { "\($0) (\(email))" } ?? email
            result.append((email, label))
        }

        for name in profile.names() {
            if let email = try? profile.read(name).email {
                appendEmail(email, preferredName: name)
            }
        }
        for entry in timeline.reversed() {
            appendEmail(entry.email)
        }
        for event in events where !event.accountEmail.isEmpty {
            appendEmail(event.accountEmail)
        }
        return result
    }

    private static func resolveAccountFilter(
        requested: String?,
        activeEmail: String,
        events: [RequestEventRecord],
        profile: ToolProfile,
        knownEmails: [String]
    ) -> String {
        if let raw = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let lower = raw.lowercased()
            if lower == "all" {
                return "all"
            }
            if lower == "unattributed" || lower == "__unattributed__" {
                return "__unattributed__"
            }
            if lower.contains("@") {
                return lower
            }
            if let meta = try? profile.read(raw) {
                return AccountTimelineStore.normalizeEmail(meta.email)
            }
            return lower
        }

        let hasActiveRows = !activeEmail.isEmpty && events.contains { $0.accountEmail == activeEmail }
        if knownEmails.count > 1, hasActiveRows {
            return activeEmail
        }
        return "all"
    }

    private static func makeFilterOptions(
        accounts: [(key: String, label: String)],
        hasUnattributed: Bool
    ) -> [AccountFilterOption] {
        var options = [AccountFilterOption(key: "all", label: "All")]
        options.append(contentsOf: accounts.map { AccountFilterOption(key: $0.key, label: $0.label) })
        if hasUnattributed {
            options.append(AccountFilterOption(key: "__unattributed__", label: "Unattributed"))
        }
        return options
    }

    // MARK: - Aggregation (Sparklines, 371-cell Heatmap, 32-bucket Model Health)

    private static func aggregateSnapshot(
        events: [RequestEventRecord],
        range: UsageRangePreset,
        accountFilter: String,
        sourceFilter: TelemetrySourceFilter,
        pricingMode: PricingMode,
        startMs: Double,
        endMs: Double,
        subtitle: String,
        accountOptions: [AccountFilterOption],
        now: Date,
        calendar: Calendar
    ) -> UsageOverviewSnapshot {
        let widthMs = max(1.0, endMs - startMs)
        var sparkline = Array(repeating: SparklinePoint(tokens: 0, requests: 0, cost: 0), count: 32)

        struct ModelAccumulator {
            var modelId: String
            var requests = 0
            var success = 0
            var errors = 0
            var tokens = 0
            var inputTokens = 0
            var cacheReadTokens = 0
            var outputTokens = 0
            var cost = 0.0
            var priced = 0
            var speedOutput = 0
            var speedDuration = 0.0
            var peakTps: Double?
            var buckets = Array(repeating: (good: 0, errors: 0, total: 0), count: 32)
        }

        var modelMap: [String: ModelAccumulator] = [:]
        var totalTokens = 0
        var inputTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var costSum = 0.0
        var pricedCount = 0
        var successCount = 0
        var errorCount = 0

        for event in events {
            let modelId = PricingCatalog.normalizedModelID(event.model)
            let key = modelId.isEmpty ? "unknown" : modelId
            var acc = modelMap[key] ?? ModelAccumulator(modelId: key)

            let inTok = event.inputTokens
            let cacheTok = event.cacheReadTokens
            let outTok = event.outputTokens
            let count = inTok + cacheTok + outTok

            acc.requests += 1
            acc.tokens += count
            acc.inputTokens += inTok
            acc.cacheReadTokens += cacheTok
            acc.outputTokens += outTok

            totalTokens += count
            inputTokens += inTok
            cacheReadTokens += cacheTok
            outputTokens += outTok

            if event.status == "success" {
                successCount += 1
                acc.success += 1
            } else if event.status == "error" {
                errorCount += 1
                acc.errors += 1
            }

            if let cost = event.costUsd {
                costSum += cost
                pricedCount += 1
                acc.cost += cost
                acc.priced += 1
            }

            let speedDur = (event.tpsDurationMs ?? 0) > 0 ? (event.tpsDurationMs ?? 0) : (event.durationMs ?? 0)
            if speedDur > 0, outTok > 0 {
                acc.speedOutput += outTok
                acc.speedDuration += speedDur
                let singleTps = event.tps ?? (Double(outTok) * 1000.0 / speedDur)
                acc.peakTps = max(acc.peakTps ?? 0, singleTps)
            }

            if let ts = event.timestampMs {
                let bucketIndex = min(31, max(0, Int(floor((ts - startMs) / widthMs * 32.0))))
                sparkline[bucketIndex].tokens += count
                sparkline[bucketIndex].requests += 1
                sparkline[bucketIndex].cost += event.costUsd ?? 0
                acc.buckets[bucketIndex].total += 1
                if event.status == "success" {
                    acc.buckets[bucketIndex].good += 1
                } else if event.status == "error" {
                    acc.buckets[bucketIndex].errors += 1
                }
            }

            modelMap[key] = acc
        }

        let totalIn = inputTokens + cacheReadTokens
        let cacheHitPercent: Double? = totalIn > 0
            ? round1(Double(cacheReadTokens) / Double(totalIn) * 100.0)
            : nil
        let totalCostUsd: Double? = pricedCount > 0 ? costSum : (events.isEmpty ? 0.0 : nil)
        let avgCostUsd: Double? = (pricedCount > 0 && totalCostUsd != nil) ? (costSum / Double(pricedCount)) : nil
        let totalStatus = successCount + errorCount
        let overallSuccessPercent: Int? = totalStatus > 0
            ? Int((Double(successCount) / Double(totalStatus) * 100.0).rounded())
            : nil

        let modelRows: [ModelHealthRow] = modelMap.values
            .filter { $0.requests > 0 }
            .sorted { lhs, rhs in
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.modelId < rhs.modelId
            }
            .map { acc in
                let mIn = acc.inputTokens + acc.cacheReadTokens
                let mHit = mIn > 0 ? round1(Double(acc.cacheReadTokens) / Double(mIn) * 100.0) : nil
                let mTotal = acc.success + acc.errors
                let successPct = mTotal > 0 ? Int((Double(acc.success) / Double(mTotal) * 100.0).rounded()) : nil
                let avgTps = acc.speedDuration > 0 ? round1(Double(acc.speedOutput) * 1000.0 / acc.speedDuration) : nil
                return ModelHealthRow(
                    modelId: acc.modelId,
                    requests: acc.requests,
                    success: acc.success,
                    errors: acc.errors,
                    tokens: acc.tokens,
                    inputTokens: acc.inputTokens,
                    cacheReadTokens: acc.cacheReadTokens,
                    outputTokens: acc.outputTokens,
                    cacheHitPercent: mHit,
                    costUsd: acc.priced > 0 ? acc.cost : nil,
                    avgTps: avgTps,
                    peakTps: acc.peakTps.map(round1),
                    successPercent: successPct,
                    buckets: acc.buckets.enumerated().map { idx, b in
                        ModelHealthBucket(index: idx, good: b.good, errors: b.errors, total: b.total)
                    }
                )
            }

        let (heatmapCells, heatmapTicks) = buildHeatmap(
            events: events,
            range: range,
            startMs: startMs,
            endMs: endMs,
            now: now,
            calendar: calendar
        )

        return UsageOverviewSnapshot(
            range: range,
            accountFilter: accountFilter,
            sourceFilter: sourceFilter,
            pricingMode: pricingMode,
            rangeStartMs: startMs,
            rangeEndMs: endMs,
            rangeSubtitle: subtitle,
            accountOptions: accountOptions,
            totalRequests: events.count,
            successCount: successCount,
            errorCount: errorCount,
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            cacheHitPercent: cacheHitPercent,
            totalCostUsd: totalCostUsd,
            avgCostUsd: avgCostUsd,
            pricedCount: pricedCount,
            overallSuccessPercent: overallSuccessPercent,
            sparkline: sparkline,
            heatmapCells: heatmapCells,
            heatmapTicks: heatmapTicks,
            models: modelRows
        )
    }

    private static func buildHeatmap(
        events: [RequestEventRecord],
        range: UsageRangePreset,
        startMs: Double,
        endMs: Double,
        now: Date,
        calendar: Calendar
    ) -> ([HeatmapCell], [String]) {
        let totalCells = 371
        let spanMs = max(60_000.0, endMs - startMs)
        let spanDays = spanMs / dayMs

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.timeZone = calendar.timeZone
        dateFmt.dateFormat = "MM/dd"

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = calendar.timeZone
        timeFmt.dateFormat = "HH:mm"

        let dayKeyFmt = DateFormatter()
        dayKeyFmt.locale = Locale(identifier: "en_US_POSIX")
        dayKeyFmt.timeZone = calendar.timeZone
        dayKeyFmt.dateFormat = "yyyy-MM-dd"

        var rawBuckets = Array(repeating: (label: "", tokens: 0, requests: 0, cost: 0.0), count: totalCells)
        var ticks: [String] = []

        if range == .all || spanDays >= 365.0 {
            var daily: [String: (tokens: Int, requests: Int, cost: Double)] = [:]
            for event in events {
                guard let ts = event.timestampMs else { continue }
                let key = dayKeyFmt.string(from: Date(timeIntervalSince1970: ts / 1000.0))
                var cur = daily[key] ?? (0, 0, 0)
                cur.tokens += event.inputTokens + event.cacheReadTokens + event.outputTokens
                cur.requests += 1
                cur.cost += event.costUsd ?? 0
                daily[key] = cur
            }
            let endDate = Date(timeIntervalSince1970: endMs / 1000.0)
            var anchor = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: endDate) ?? now
            let weekday = calendar.component(.weekday, from: anchor) // 1=Sun
            anchor = calendar.date(byAdding: .day, value: -(364 + (weekday - 1)), to: anchor) ?? anchor
            for idx in 0 ..< totalCells {
                let d = calendar.date(byAdding: .day, value: idx, to: anchor) ?? anchor
                let key = dayKeyFmt.string(from: d)
                let val = daily[key] ?? (0, 0, 0)
                rawBuckets[idx] = (key, val.tokens, val.requests, val.cost)
            }
            ticks = [0, 91, 182, 273, 370].map { idx in
                let d = calendar.date(byAdding: .day, value: idx, to: anchor) ?? anchor
                return dateFmt.string(from: d)
            }
        } else {
            let stepMs = spanMs / Double(totalCells)
            for event in events {
                guard let ts = event.timestampMs else { continue }
                let idx = min(totalCells - 1, max(0, Int(floor((ts - startMs) / stepMs))))
                rawBuckets[idx].tokens += event.inputTokens + event.cacheReadTokens + event.outputTokens
                rawBuckets[idx].requests += 1
                rawBuckets[idx].cost += event.costUsd ?? 0
            }
            let showTime = spanDays <= 2.0
            for idx in 0 ..< totalCells {
                let s = Date(timeIntervalSince1970: (startMs + Double(idx) * stepMs) / 1000.0)
                let e = Date(timeIntervalSince1970: (startMs + Double(idx + 1) * stepMs) / 1000.0)
                let label: String
                if stepMs >= dayMs {
                    label = dayKeyFmt.string(from: s)
                } else if showTime {
                    label = "\(dateFmt.string(from: s)) \(timeFmt.string(from: s)) - \(timeFmt.string(from: e))"
                } else {
                    label = "\(dateFmt.string(from: s)) \(timeFmt.string(from: s)) - \(dateFmt.string(from: e)) \(timeFmt.string(from: e))"
                }
                rawBuckets[idx].label = label
            }
            ticks = [0, 92, 185, 278, 370].map { idx in
                let d = Date(timeIntervalSince1970: (startMs + Double(idx) * stepMs) / 1000.0)
                return showTime ? timeFmt.string(from: d) : dateFmt.string(from: d)
            }
        }

        let maxTokens = max(1e-9, Double(rawBuckets.map(\.tokens).max() ?? 0))
        let maxReqs = max(1e-9, Double(rawBuckets.map(\.requests).max() ?? 0))
        let maxCost = max(1e-9, rawBuckets.map(\.cost).max() ?? 0)

        func intensity(_ value: Double, maxValue: Double) -> Int {
            guard value > 0 else {
                return 0
            }
            return min(4, max(1, Int(ceil(value / maxValue * 4.0))))
        }

        let cells = rawBuckets.enumerated().map { idx, bucket in
            HeatmapCell(
                index: idx,
                label: bucket.label,
                tokens: bucket.tokens,
                requests: bucket.requests,
                cost: bucket.cost,
                tokenLevel: intensity(Double(bucket.tokens), maxValue: maxTokens),
                requestLevel: intensity(Double(bucket.requests), maxValue: maxReqs),
                costLevel: intensity(bucket.cost, maxValue: maxCost)
            )
        }
        return (cells, ticks)
    }

    private static func sanitizeText(_ value: String, maxLength: Int) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            scalar == " " || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(filtered).prefix(maxLength))
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }
}

// MARK: - CLI text formatting

func formatUsageOverview(
    _ snapshot: UsageOverviewSnapshot,
    text: Localizer,
    timeZone: TimeZone = .current
) -> [String] {
    var lines: [String] = []
    let scopeLabel = snapshot.accountFilter == "all"
        ? text.line(.telemetryAllAccounts)
        : (snapshot.accountFilter == "__unattributed__" ? text.line(.telemetryUnattributed) : snapshot.accountFilter)
    lines.append("\(text.line(.telemetryOverviewHeader))  [\(telemetryRangeDisplayName(snapshot.range, text: text))]  [\(scopeLabel)]")
    lines.append(telemetryRangeWindowSubtitle(snapshot, text: text, timeZone: timeZone))
    lines.append("")

    lines.append(
        "\(text.line(.telemetryReqCount)): \(snapshot.totalRequests)"
            + "  (\(snapshot.successCount) \(text.line(.telemetrySuccess)), \(snapshot.errorCount) \(text.line(.telemetryError)))"
    )
    let totalIn = snapshot.inputTokens + snapshot.cacheReadTokens
    var tokenLine = "\(text.line(.telemetryTotalTokens)): \(formatCompactTokens(snapshot.totalTokens))"
        + "  (\(formatCompactTokens(totalIn)) \(text.line(.telemetryInput)) / \(formatCompactTokens(snapshot.outputTokens)) \(text.line(.telemetryOutput)))"
    if let hit = snapshot.cacheHitPercent {
        tokenLine += "  \(text.line(.telemetryCacheHit)) \(formatPercent(hit)) (\(formatCompactTokens(snapshot.cacheReadTokens)))"
    }
    lines.append(tokenLine)
    var costLine = "\(text.line(.telemetryCostLabel)): \(snapshot.totalCostUsd.map(formatUSD) ?? "—")"
    if let avg = snapshot.avgCostUsd {
        costLine += "  (\(text.line(.telemetryAvgPerReq, formatUSD(avg))))"
    }
    lines.append(costLine)
    lines.append("")

    lines.append(text.line(.telemetryHeatmapHeader))
    let glyphs = ["·", "░", "▒", "▓", "█"]
    for row in 0 ..< 7 {
        var rowChars = ""
        for col in 0 ..< 53 {
            let cellIndex = col * 7 + row
            let level = cellIndex < snapshot.heatmapCells.count ? snapshot.heatmapCells[cellIndex].tokenLevel : 0
            rowChars.append(glyphs[min(4, max(0, level))])
        }
        lines.append("  \(rowChars)")
    }
    if !snapshot.heatmapTicks.isEmpty {
        lines.append("  " + snapshot.heatmapTicks.joined(separator: "      "))
    }
    lines.append("")

    let overall = snapshot.overallSuccessPercent.map { "\($0)% \(text.line(.telemetrySuccess))" } ?? "—"
    lines.append("\(text.line(.telemetryHealthHeader))  (\(overall))")
    let topModels = Array(snapshot.models.prefix(8))
    if topModels.isEmpty {
        lines.append("  \(text.line(.telemetryNoRequests))")
    } else {
        for model in topModels {
            let rail = model.buckets.map { bucket -> Character in
                if bucket.total == 0 { return "·" }
                if bucket.errors > 0 { return "!" }
                return "▪"
            }
            let pct = model.successPercent.map { "\($0)%" } ?? "—"
            let paddedID = model.modelId.padding(toLength: 24, withPad: " ", startingAt: 0)
            lines.append("  \(paddedID)  \(String(rail))  \(pct)")
        }
    }

    return lines
}

public func telemetryRangeDisplayName(_ range: UsageRangePreset, text: Localizer) -> String {
    switch range {
    case .weekly: return text.line(.telemetryRangeWeekly)
    case .today: return text.line(.telemetryRangeToday)
    case .last24h: return text.line(.telemetryRange24h)
    case .yesterday: return text.line(.telemetryRangeYesterday)
    case .week: return text.line(.telemetryRangeWeek)
    case .month: return text.line(.telemetryRangeMonth)
    case .last30d: return text.line(.telemetryRange30d)
    case .all: return text.line(.telemetryRangeAll)
    }
}

public func telemetryRangeWindowSubtitle(
    _ snapshot: UsageOverviewSnapshot,
    text: Localizer,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"

    let startDate = Date(timeIntervalSince1970: snapshot.rangeStartMs / 1000.0)
    let endDate = Date(timeIntervalSince1970: snapshot.rangeEndMs / 1000.0)
    if snapshot.range == .weekly {
        if snapshot.rangeSubtitle.hasPrefix("weekly-active:") {
            let resetStr = snapshot.rangeSubtitle.replacingOccurrences(of: "weekly-active:", with: "")
            if let resetMs = Double(resetStr) {
                let resetFmt = DateFormatter()
                resetFmt.locale = Locale(identifier: "en_US_POSIX")
                resetFmt.timeZone = timeZone
                resetFmt.dateFormat = "MM-dd HH:mm"
                let resetDate = Date(timeIntervalSince1970: resetMs / 1000.0)
                return text.line(.telemetryWeeklyActive, formatter.string(from: startDate), resetFmt.string(from: resetDate))
            }
        } else if snapshot.rangeSubtitle == "weekly-unstarted" {
            return text.line(.telemetryWeeklyUnstarted)
        }
        return text.line(.telemetryWeeklyFallback)
    }
    return "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
}
