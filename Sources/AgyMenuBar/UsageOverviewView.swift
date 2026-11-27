import AgyAccount
import SwiftUI

struct UsageOverviewView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterBar
            if let snapshot = model.usageSnapshot {
                kpiRow(snapshot)
                heatmapCard(snapshot)
                healthTimelineCard(snapshot)
            } else if model.loadingTelemetry {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.text(.panelWorking))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Text(model.text(.telemetryNoRequests))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            }
        }
        .padding(12)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(UsageRangePreset.allCases, id: \.self) { preset in
                    Button {
                        model.setStatsRange(preset)
                    } label: {
                        menuSelectionLabel(
                            telemetryRangeDisplayName(preset, text: model.state.text),
                            selected: model.statsRange == preset
                        )
                    }
                }
            } label: {
                Text(telemetryRangeDisplayName(model.statsRange, text: model.state.text))
            }
            .menuStyle(.borderlessButton)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .fixedSize()

            Menu {
                ForEach(accountOptions) { option in
                    Button {
                        model.setStatsAccount(option.key)
                    } label: {
                        menuSelectionLabel(
                            localizedAccountOption(option),
                            selected: currentAccountKey == option.key
                        )
                    }
                }
            } label: {
                Text(selectedAccountLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if let snapshot = model.usageSnapshot {
                Text(telemetryRangeWindowSubtitle(snapshot, text: model.state.text))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var accountOptions: [AccountFilterOption] {
        model.usageSnapshot?.accountOptions ?? [AccountFilterOption(key: "all", label: model.text(.telemetryAllAccounts))]
    }

    private var currentAccountKey: String {
        model.usageSnapshot?.accountFilter ?? model.statsAccountFilter ?? "all"
    }

    private var selectedAccountLabel: String {
        if let match = accountOptions.first(where: { $0.key == currentAccountKey }) {
            return localizedAccountOption(match)
        }
        return model.text(.telemetryAllAccounts)
    }

    private func localizedAccountOption(_ option: AccountFilterOption) -> String {
        switch option.key {
        case "all":
            return model.text(.telemetryAllAccounts)
        case "__unattributed__":
            return model.text(.telemetryUnattributed)
        default:
            return option.label
        }
    }

    private func kpiRow(_ snapshot: UsageOverviewSnapshot) -> some View {
        let totalInput = snapshot.inputTokens + snapshot.cacheReadTokens
        let cachePctText = snapshot.cacheHitPercent.map { formatPercent($0) } ?? "—"
        let avgCostText = snapshot.avgCostUsd.map { model.text(.telemetryAvgPerReq, formatUSD($0)) } ?? "—"

        return HStack(alignment: .top, spacing: 8) {
            kpiCard(
                title: model.text(.telemetryReqCount),
                icon: "arrow.left.arrow.right",
                primary: "\(snapshot.totalRequests)",
                values: snapshot.sparkline.map { Double($0.requests) }
            ) {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(snapshot.successCount) \(model.text(.telemetrySuccess))")
                            .foregroundStyle(.green)
                    }
                    HStack(spacing: 3) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("\(snapshot.errorCount) \(model.text(.telemetryError))")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
            }

            kpiCard(
                title: model.text(.telemetryTotalTokens),
                icon: "square.stack.3d.up",
                primary: formatCompactTokens(snapshot.totalTokens),
                values: snapshot.sparkline.map { Double($0.tokens) }
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(formatCompactTokens(totalInput)) \(model.text(.telemetryInput)) / \(formatCompactTokens(snapshot.outputTokens)) \(model.text(.telemetryOutput))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(model.text(.telemetryCacheHit))
                            .foregroundStyle(.secondary)
                        Text(cachePctText)
                            .foregroundStyle(.green)
                            .fontWeight(.medium)
                        Text("(\(formatCompactTokens(snapshot.cacheReadTokens)))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                }
            }

            kpiCard(
                title: model.text(.telemetryCostLabel),
                icon: "dollarsign.circle",
                primary: snapshot.totalCostUsd.map(formatUSD) ?? "—",
                values: snapshot.sparkline.map(\.cost)
            ) {
                Text(avgCostText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func kpiCard<Detail: View>(
        title: String,
        icon: String,
        primary: String,
        values: [Double],
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        let detailView = detail()
        return TelemetryCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(primary)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                detailView
                    .frame(minHeight: 24, alignment: .topLeading)
                SparklineCanvas(values: values)
                    .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func heatmapCard(_ snapshot: UsageOverviewSnapshot) -> some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(model.text(.telemetryHeatmapHeader))
                        .font(.subheadline.weight(.semibold))
                    if let hovered = model.hoveredHeatmapCell {
                        Text("\(hovered.label) · \(formattedHeatmapValue(hovered, metric: model.heatmapMetric))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        heatmapMetricButton(.tokens, title: model.text(.panelHeatmapTokens))
                        heatmapMetricButton(.requests, title: model.text(.panelHeatmapRequests))
                        heatmapMetricButton(.cost, title: model.text(.panelHeatmapCost))
                    }
                    .padding(2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                GeometryReader { proxy in
                    Canvas { context, size in
                        let cols = 53
                        let rows = 7
                        let gap: CGFloat = 2.0
                        let cellW = max(1, (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
                        let cellH = max(1, (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
                        let side = min(cellW, cellH)
                        let stepX = (size.width - side) / CGFloat(max(1, cols - 1))
                        let stepY = (size.height - side) / CGFloat(max(1, rows - 1))

                        for col in 0 ..< cols {
                            for row in 0 ..< rows {
                                let idx = col * rows + row
                                let level = idx < snapshot.heatmapCells.count
                                    ? snapshot.heatmapCells[idx].level(for: model.heatmapMetric)
                                    : 0
                                let rect = CGRect(
                                    x: CGFloat(col) * stepX,
                                    y: CGFloat(row) * stepY,
                                    width: side,
                                    height: side
                                )
                                let path = Path(roundedRect: rect, cornerRadius: max(1.5, side * 0.22))
                                context.fill(path, with: .color(heatmapColor(level: level)))
                            }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let cols = 53
                            let rows = 7
                            let col = min(cols - 1, max(0, Int(location.x / max(1, proxy.size.width) * CGFloat(cols))))
                            let row = min(rows - 1, max(0, Int(location.y / max(1, proxy.size.height) * CGFloat(rows))))
                            let idx = col * rows + row
                            if idx < snapshot.heatmapCells.count {
                                model.hoveredHeatmapCell = snapshot.heatmapCells[idx]
                            }
                        case .ended:
                            model.hoveredHeatmapCell = nil
                        }
                    }
                }
                .frame(height: 68)

                if !snapshot.heatmapTicks.isEmpty {
                    HStack {
                        ForEach(Array(snapshot.heatmapTicks.enumerated()), id: \.offset) { idx, tick in
                            if idx > 0 {
                                Spacer()
                            }
                            Text(tick)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func heatmapMetricButton(_ metric: HeatmapMetric, title: String) -> some View {
        let selected = model.heatmapMetric == metric
        return Button {
            model.heatmapMetric = metric
        } label: {
            Text(title)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func formattedHeatmapValue(_ cell: HeatmapCell, metric: HeatmapMetric) -> String {
        switch metric {
        case .tokens:
            return formatCompactTokens(cell.tokens)
        case .requests:
            return "\(cell.requests)"
        case .cost:
            return formatUSD(cell.cost)
        }
    }

    private func heatmapColor(level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.07)
        case 1: return Color.blue.opacity(0.24)
        case 2: return Color.blue.opacity(0.45)
        case 3: return Color.blue.opacity(0.70)
        default: return Color.blue.opacity(0.95)
        }
    }

    private func healthTimelineCard(_ snapshot: UsageOverviewSnapshot) -> some View {
        let overallText = snapshot.overallSuccessPercent.map { "\($0)% \(model.text(.telemetrySuccess))" } ?? "—"
        let topModels = Array(snapshot.models.prefix(8))

        return TelemetryCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.text(.telemetryHealthHeader))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(overallText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if topModels.isEmpty {
                    Text(model.text(.telemetryNoRequests))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                } else {
                    ForEach(topModels) { row in
                        HStack(spacing: 8) {
                            Text(row.modelId)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 152, alignment: .leading)

                            ModelHealthRailCanvas(buckets: row.buckets)
                                .frame(height: 11)

                            Text(row.successPercent.map { "\($0)%" } ?? "—")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct SparklineCanvas: View {
    var values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else {
                return
            }
            let maxVal = values.max() ?? 0
            let height = max(2, size.height - 2)
            let width = max(1, size.width)
            let stepX = width / CGFloat(values.count - 1)

            var line = Path()
            var area = Path()
            for idx in values.indices {
                let x = CGFloat(idx) * stepX
                let normalized = maxVal > 0 ? CGFloat(values[idx] / maxVal) : 0
                let y = size.height - 1 - normalized * (height - 2)
                if idx == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                    area.move(to: CGPoint(x: x, y: size.height))
                    area.addLine(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                    area.addLine(to: CGPoint(x: x, y: y))
                }
            }
            area.addLine(to: CGPoint(x: width, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .color(Color.blue.opacity(0.14)))
            context.stroke(line, with: .color(Color.blue.opacity(0.9)), lineWidth: 1.4)
        }
    }
}

private struct ModelHealthRailCanvas: View {
    var buckets: [ModelHealthBucket]

    var body: some View {
        Canvas { context, size in
            let count = max(1, buckets.count)
            let gap: CGFloat = 2
            let slotW = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let stepX = (size.width - slotW) / CGFloat(max(1, count - 1))
            for idx in buckets.indices {
                let bucket = buckets[idx]
                let color: Color = {
                    if bucket.total == 0 {
                        return Color.primary.opacity(0.08)
                    }
                    if bucket.errors > 0 {
                        return Color.red.opacity(0.85)
                    }
                    return Color.green.opacity(0.78)
                }()
                let rect = CGRect(x: CGFloat(idx) * stepX, y: 0, width: slotW, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
    }
}
