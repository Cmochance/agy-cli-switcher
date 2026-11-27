import AgyAccount
import SwiftUI

struct SessionTelemetryView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionPickerBar
            if let snapshot = model.sessionSnapshot {
                HStack(alignment: .top, spacing: 10) {
                    contextCard(snapshot)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    statsCard(snapshot)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if model.loadingSession {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.text(.panelWorking))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                Text(model.text(.telemetryNoSessions))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            }
        }
        .padding(12)
    }

    private var sessionPickerBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    model.selectSession(nil)
                } label: {
                    menuSelectionLabel(model.text(.panelSessionAutoFollow), selected: model.selectedSessionId == nil)
                }
                if let sessions = model.sessionSnapshot?.sessions, !sessions.isEmpty {
                    Divider()
                    ForEach(sessions) { item in
                        Button {
                            model.selectSession(item.conversationId)
                        } label: {
                            let title = "[\(item.source.rawValue.uppercased())] \(item.title)"
                            menuSelectionLabel(title, selected: model.selectedSessionId == item.conversationId)
                        }
                    }
                }
            } label: {
                Label(selectedSessionTitle, systemImage: "bubble.left.and.bubble.right")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            if let snapshot = model.sessionSnapshot {
                Text(snapshot.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }

    private var selectedSessionTitle: String {
        guard let snapshot = model.sessionSnapshot else {
            return model.selectedSessionId ?? model.text(.panelSessionAutoFollow)
        }
        if model.selectedSessionId == nil {
            return snapshot.title
        }
        return snapshot.sessions.first(where: { $0.conversationId == model.selectedSessionId })?.title ?? snapshot.title
    }

    private func contextCard(_ snapshot: SessionTelemetrySnapshot) -> some View {
        let cw = snapshot.contextWindow
        let usedPctText = cw.usedPercent.map { "\(cw.compactedPending ? "≈" : "")\(formatPercent($0))" } ?? "—"
        let capText: String = {
            let prefix = cw.compactedPending ? "≈" : ""
            if let maxTok = cw.maxTokens {
                return "\(prefix)\(formatCompactTokens(cw.usedTokens)) / \(formatCompactTokens(maxTok))"
            }
            return "\(prefix)\(formatCompactTokens(cw.usedTokens))"
        }()

        return TelemetryCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(model.text(.telemetryContextHeader))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if cw.compactedPending {
                        statusPill(model.text(.telemetryCompactedEst), color: .orange)
                    } else if cw.compactions > 0 {
                        statusPill(model.text(.telemetryCompactedCount, String(cw.compactions)), color: .secondary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.text(.panelContextUsed, usedPctText))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 4)
                    Text(capText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                segmentedContextBar(cw.categories)

                if !cw.categories.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(cw.categories.enumerated()), id: \.offset) { _, slice in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(categoryColor(slice))
                                    .frame(width: 7, height: 7)
                                Text(localizedTelemetryCategory(slice.label, text: model.state.text))
                                    .font(.caption)
                                    .foregroundStyle(slice.isFreeSpace ? .secondary : .primary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(formatCompactTokens(slice.tokens))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(slice.percent.map { formatPercent($0) } ?? "—")
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                let stepInputTotal = cw.cacheReadTokens + cw.inputTokens
                if stepInputTotal > 0 {
                    Divider()
                    let cachedPct = Double(cw.cacheReadTokens) / Double(stepInputTotal) * 100.0
                    let freshPct = Double(cw.inputTokens) / Double(stepInputTotal) * 100.0
                    VStack(alignment: .leading, spacing: 4) {
                        metricRow(
                            dot: Color.blue,
                            label: model.text(.telemetryCachedContext),
                            value: formatCompactTokens(cw.cacheReadTokens),
                            percent: formatPercent(cachedPct)
                        )
                        metricRow(
                            dot: Color.cyan,
                            label: model.text(.telemetryNewInput),
                            value: formatCompactTokens(cw.inputTokens),
                            percent: formatPercent(freshPct)
                        )
                    }
                }

                if cw.hasOrchestrator, cw.models.count > 1 {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.text(.telemetryOrchestrator))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(cw.models) { item in
                            orchestratorRow(item)
                        }
                    }
                }

                if !snapshot.subagents.isEmpty {
                    Divider()
                    subagentListSection(snapshot.subagents)
                }
            }
        }
    }

    private func segmentedContextBar(_ categories: [ContextCategorySlice]) -> some View {
        let total = max(1, categories.reduce(0) { $0 + max(0, $1.tokens) })
        return GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(Array(categories.enumerated()), id: \.offset) { _, slice in
                    let fraction = CGFloat(max(0, slice.tokens)) / CGFloat(total)
                    if fraction > 0 {
                        Rectangle()
                            .fill(categoryColor(slice))
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func orchestratorRow(_ item: ModelContextProgress) -> some View {
        let roleLabel = item.role == .execution ? model.text(.telemetryRoleExec) : model.text(.telemetryRolePlan)
        let pctValue = min(1.0, max(0.0, (item.usedPercent ?? 0) / 100.0))
        let pctText = item.usedPercent.map { formatPercent($0) } ?? "—"
        let capText = item.maxTokens.map { "\(formatCompactTokens(item.usedTokens)) / \(formatCompactTokens($0))" }
            ?? formatCompactTokens(item.usedTokens)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(roleLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((item.role == .execution ? Color.teal : Color.indigo).opacity(0.16)))
                    .foregroundStyle(item.role == .execution ? Color.teal : Color.indigo)
                Text(item.shortName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(capText) (\(pctText))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(item.role == .execution ? Color.teal : Color.indigo)
                        .frame(width: proxy.size.width * CGFloat(pctValue))
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private func subagentListSection(_ subagents: [SubagentTelemetryItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.text(.telemetrySubagentsHeader))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(subagents.count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
            }

            let rows = VStack(alignment: .leading, spacing: 6) {
                ForEach(subagents) { sub in
                    subagentRow(sub)
                }
            }
            if subagents.count > 3 {
                ScrollView { rows }
                    .frame(height: 120)
            } else {
                rows
            }
        }
    }

    private func subagentRow(_ sub: SubagentTelemetryItem) -> some View {
        let pctValue = min(1.0, max(0.0, (sub.usedPercent ?? 0) / 100.0))
        let pctText = sub.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        let capText = sub.maxTokens.map { "\(formatCompactTokens(sub.usedTokens)) / \(formatCompactTokens($0))" }
            ?? formatCompactTokens(sub.usedTokens)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(sub.status == "running" ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(sub.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !sub.shortModel.isEmpty {
                    Text(sub.shortModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer(minLength: 4)
                Text(pctText)
                    .font(.caption.weight(.medium).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.blue.opacity(0.85))
                        .frame(width: proxy.size.width * CGFloat(pctValue))
                }
            }
            .frame(height: 4)
            HStack(spacing: 5) {
                Text(capText)
                if let hit = sub.cacheHitPercent {
                    Text("\(model.text(.telemetryCacheHit)) \(formatPercent(hit))")
                }
                if let tps = sub.tps {
                    Text("\(formatOneDecimal(tps)) tok/s")
                }
                if let cost = sub.costUsd {
                    Text(formatUSD(cost))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func statsCard(_ snapshot: SessionTelemetrySnapshot) -> some View {
        let stats = snapshot.telemetry
        return TelemetryCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.text(.telemetryStatsHeader))
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 2)

                statRow(model.text(.telemetryTurnsSteps), "\(stats.turnCount) / \(stats.stepCount)")
                statRow(model.text(.telemetryTotalTokens), formatCompactTokens(stats.totalTokens))
                statRow(model.text(.telemetryApiCost), stats.costUsd.map(formatUSD) ?? "—")
                statRow(model.text(.telemetryAvgSpeed), stats.tps.map { "\(formatOneDecimal($0)) tok/s" } ?? "—")
                statRow(model.text(.telemetryPeakSpeed), stats.peakTps.map { "\(formatOneDecimal($0)) tok/s" } ?? "—")
                statRow(model.text(.telemetryLatestSpeed), stats.latestTps.map { "\(formatOneDecimal($0)) tok/s" } ?? "—")
                statRow(model.text(.telemetryCacheHit), stats.cacheHitPercent.map { formatPercent($0) } ?? "—")
                statRow(model.text(.telemetryCacheWindow), liveCacheObservationText(stats.cacheObservation))

                Button {
                    model.expandedMoreStats.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(model.text(.panelMoreStats))
                            .font(.caption.weight(.medium))
                        Image(systemName: model.expandedMoreStats ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)

                if model.expandedMoreStats {
                    VStack(alignment: .leading, spacing: 4) {
                        statRow(model.text(.telemetryInput), formatCompactTokens(stats.inputTokens + stats.cacheReadTokens))
                        statRow(model.text(.telemetryOutput), formatCompactTokens(stats.outputTokens))
                        statRow(model.text(.panelThinkingTokens), formatCompactTokens(stats.thinkingTokens))
                        statRow(model.text(.panelRequestErrors), "\(stats.requestCount) / \(stats.errorCount)")
                    }
                    .padding(.leading, 6)
                }

                Divider()
                statRow(model.text(.telemetryModelTime), formatDurationMs(stats.modelTimeMs, text: model.state.text))
                statRow(model.text(.telemetryToolTime), formatDurationMs(stats.toolTimeMs, text: model.state.text))
                statRow(model.text(.telemetryTtft), formatDurationMs(stats.avgTtftMs, text: model.state.text))

                if snapshot.subagentTotals.count > 0 {
                    let totals = snapshot.subagentTotals
                    Divider()
                    HStack(spacing: 5) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(model.text(.panelSubagentSummaryHeader))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("\(totals.count)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.09)))
                    }
                    statRow(model.text(.telemetrySubagentTokens), formatCompactTokens(totals.totalTokens))
                    statRow(model.text(.telemetryCombinedTokens), formatCompactTokens(totals.combinedTotalTokens))
                    statRow(model.text(.telemetryReqTools), "\(totals.requestCount) / \(totals.toolCount)")
                    statRow(model.text(.telemetrySubagentCache), totals.cacheHitPercent.map { formatPercent($0) } ?? "—")
                    statRow(model.text(.telemetrySubagentCost), totals.costUsd.map(formatUSD) ?? "—")
                    statRow(model.text(.telemetryCombinedCost), totals.combinedCostUsd.map(formatUSD) ?? "—")
                }
            }
        }
    }

    private func liveCacheObservationText(_ obs: CacheObservationWindow?) -> String {
        guard let obs else {
            return "—"
        }
        guard let windowMs = obs.assumedWindowMs, windowMs > 0 else {
            return model.text(.telemetryCacheUnconfirmed)
        }
        let elapsed = max(0, model.cacheNowMs - obs.lastRequestAtMs)
        let remaining = max(0, windowMs - elapsed)
        let sec = Int(ceil(remaining / 1000.0))
        return String(format: "≈ %d:%02d", sec / 60, sec % 60)
    }

    private func metricRow(dot: Color, label: String, value: String, percent: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(percent)
                .font(.caption.weight(.medium).monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
        }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func categoryColor(_ slice: ContextCategorySlice) -> Color {
        if slice.isFreeSpace {
            return Color.primary.opacity(0.14)
        }
        switch slice.label {
        case "Chat Messages": return .blue
        case "System Prompt": return .orange
        case "Tools": return .teal
        case "Skills": return Color(red: 0.48, green: 0.45, blue: 0.36)
        case "Subagents": return .indigo
        case "Plugins": return .purple
        case "MCP Tools", "MCP tools": return .gray
        case "Rules": return Color.gray.opacity(0.7)
        case "Memories", "Memory files": return .mint
        default: return Color.secondary.opacity(0.6)
        }
    }
}

struct TelemetryCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

func menuSelectionLabel(_ title: String, selected: Bool) -> some View {
    Group {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
