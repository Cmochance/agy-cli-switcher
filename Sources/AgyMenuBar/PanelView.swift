import AgyAccount
import SwiftUI

private struct RowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var frames: [String: CGRect] = [:]
    @State private var drag: RowDrag?

    private let list = "rows"

    // dragging 只给画图的测试用：把面板画成正拖着一行的样子。
    init(model: PanelModel, dragging: RowDrag? = nil) {
        self.model = model
        _drag = State(initialValue: dragging)
    }

    private var activeTab: PanelTab {
        model.provider == .antigravity ? model.tab : .accounts
    }

    private var panelWidth: CGFloat {
        activeTab == .accounts ? 420 : 580
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.provider == .antigravity {
                tabHeader
                Divider()
            }
            switch activeTab {
            case .accounts:
                accounts
            case .session:
                SessionTelemetryView(model: model)
            case .stats:
                UsageOverviewView(model: model)
            }
            if model.busyLabel != nil || !model.lines.isEmpty {
                Divider()
                status
            }
            Divider()
            if let prompt = model.prompt {
                PromptView(prompt: prompt, model: model)
            } else {
                actions
            }
        }
        .frame(width: panelWidth)
    }

    private var tabHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                tabButton(.accounts, title: model.text(.panelTabAccounts))
                tabButton(.session, title: model.text(.panelTabSession))
                tabButton(.stats, title: model.text(.panelTabStats))
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))

            Spacer(minLength: 4)

            if activeTab != .accounts {
                sourceMenu
                pricingMenu
                Button {
                    model.refreshTelemetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.text(.panelRefresh))
                .disabled(model.loadingCurrentTelemetry)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func tabButton(_ target: PanelTab, title: String) -> some View {
        let selected = activeTab == target
        return Button {
            model.selectTab(target)
        } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sourceMenu: some View {
        let currentSource = activeTab == .session ? model.sessionSourceFilter : model.statsSourceFilter
        let options: [TelemetrySourceFilter] = activeTab == .session ? [.auto, .cli, .app] : [.all, .cli, .app]
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    if activeTab == .session {
                        model.setSessionSource(option)
                    } else {
                        model.setStatsSource(option)
                    }
                } label: {
                    menuSelectionLabel(sourceLabel(option), selected: currentSource == option)
                }
            }
        } label: {
            Text(sourceLabel(currentSource))
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private var pricingMenu: some View {
        Menu {
            ForEach([PricingMode.standard, .promo], id: \.self) { mode in
                Button {
                    model.setPricingMode(mode)
                } label: {
                    menuSelectionLabel(pricingLabel(mode), selected: model.pricingMode == mode)
                }
            }
        } label: {
            Text(pricingLabel(model.pricingMode))
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private func sourceLabel(_ filter: TelemetrySourceFilter) -> String {
        switch filter {
        case .auto, .all:
            return model.text(.panelSourceAll)
        case .cli:
            return model.text(.panelSourceCLI)
        case .app:
            return model.text(.panelSourceApp)
        }
    }

    private func pricingLabel(_ mode: PricingMode) -> String {
        switch mode {
        case .standard:
            return model.text(.panelPricingStandard)
        case .promo:
            return model.text(.panelPricingPromo)
        }
    }

    @ViewBuilder private var accounts: some View {
        // 分隔线画在每一行自己的上沿，这样行和行是挨着的，拖动时好算位置。
        let rows = VStack(spacing: 0) {
            ForEach(Array(model.state.rows.enumerated()), id: \.element.id) { index, row in
                let lifted = drag?.index == index
                AccountRowView(
                    row: row,
                    showsName: model.showsName(row),
                    lifted: lifted,
                    model: model,
                    pressed: { pressed(at: index, moved: $0) },
                    released: { released(row, at: index, moved: $0) }
                )
                    .overlay(alignment: .top) {
                        if index > 0, !lifted {
                            Divider()
                        }
                    }
                    .offset(y: drag.map { lifted ? $0.offset : $0.shift(of: index) } ?? 0)
                    // 量位置放在 offset 之后：量到的是这一行排版上的位置，不带拖动时挪开的那一段。
                    // 带着那一段量的话，把一行拖到列表尽头松手时，让开后的位置和重排后的位置一模一样，
                    // 收不到“位置变了”，下一次拖动就按旧位置算（测试里撞到过）。
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowFrames.self, value: [row.id: proxy.frame(in: .named(list))])
                    })
                    .zIndex(lifted ? 1 : 0)
                    // 松手的那一下不带动画：顺序已经换好，让开的行直接落在新位置上。
                    .animation(lifted || drag == nil ? nil : .easeOut(duration: 0.15), value: drag?.target)
            }
        }
        .coordinateSpace(name: list)
        .onPreferenceChange(RowFrames.self) { frames = $0 }
        if model.state.rows.isEmpty {
            Text(model.text(.panelNoAccounts))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        } else if model.state.rows.count > 8 {
            ScrollView { rows }
                .frame(height: 420)
        } else {
            rows
        }
    }

    // 按住一行上下拖：这一行跟着鼠标走，别的行让开，松手后按新的顺序记下来。
    // 点击和拖动是同一个手势，松手时看鼠标走了多远：上下走出 6 个点算拖动，几乎没动算点击。
    private let slack: CGFloat = 6

    private func pressed(at index: Int, moved: CGSize) {
        if drag == nil {
            let ordered = model.state.rows.compactMap { frames[$0.id] }
            guard abs(moved.height) >= slack, model.busy == nil, !model.loggingIn, ordered.count > 1,
                  ordered.count == model.state.rows.count
            else {
                return
            }
            drag = RowDrag(index: index, frames: ordered)
        }
        if drag?.index == index {
            drag?.translation = moved.height
        }
    }

    private func released(_ row: AccountRow, at index: Int, moved: CGSize) {
        if var finished = drag {
            guard finished.index == index else {
                return
            }
            // 松手的位置可能比最后一次拖动又走了一段。
            finished.translation = moved.height
            drag = nil
            model.move(row, to: finished.target)
        } else if abs(moved.height) < slack, abs(moved.width) < slack {
            model.switchTo(row)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let busy = model.busyLabel {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busy)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(model.showsFailure ? Color.red : Color.secondary)
            .textSelection(.enabled)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Group {
                Button {
                    model.refresh()
                } label: {
                    Label(model.text(.panelRefresh), systemImage: "arrow.clockwise")
                }
                .disabled(model.state.rows.isEmpty)
                Button {
                    model.addAccount()
                } label: {
                    Label(model.text(.panelAdd), systemImage: "plus")
                }
                Button {
                    model.toggleProvider()
                } label: {
                    Label(
                        model.provider.displayName,
                        systemImage: model.provider == .antigravity ? "sparkles" : "terminal"
                    )
                }
            }
            .controlSize(.small)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            Menu {
                Button(model.text(.panelSave)) {
                    model.ask(.save)
                }
                if model.provider == .antigravity {
                    Button {
                        model.toggleBlockOldWriteback()
                    } label: {
                        if model.state.blockOldWriteback {
                            Label(model.text(.panelGuardToggle), systemImage: "checkmark")
                        } else {
                            Text(model.text(.panelGuardToggle))
                        }
                    }
                    Button {
                        model.toggleStatusBarTelemetry()
                    } label: {
                        if model.state.statusTelemetry {
                            Label(model.text(.panelStatusBarToggle), systemImage: "checkmark")
                        } else {
                            Text(model.text(.panelStatusBarToggle))
                        }
                    }
                }
                Menu(model.text(.panelLanguage)) {
                    ForEach(AccountBoard.languages, id: \.code) { language in
                        Button {
                            model.setLanguage(language.code)
                        } label: {
                            if language.code == model.state.language {
                                Label(language.name, systemImage: "checkmark")
                            } else {
                                Text(language.name)
                            }
                        }
                    }
                }
                Divider()
                Button(model.text(.panelQuit)) {
                    model.quit()
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .disabled(model.isWorking)
    }
}

private struct AccountRowView: View {
    var row: AccountRow
    var showsName: Bool
    // 正被按住拖着走。
    var lifted: Bool
    @ObservedObject var model: PanelModel
    // 鼠标按着移动时、松开时各调用一次，参数是从按下的地方走了多远。
    var pressed: (CGSize) -> Void
    var released: (CGSize) -> Void
    @State private var hovering = false

    private var selectable: Bool {
        !model.isWorking
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // 点一下切换，按住上下拖是排序。这里不用按钮：按钮会把按下的鼠标吃掉，这一行就拖不动了。
            // 走了多远按屏幕上的位置算，不能按这一行自己的位置算，它正跟着鼠标动。
            Group {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.email)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if showsName {
                                Text(row.name)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let usage = row.usage {
                                if usage.isColab {
                                    if usage.colabActiveCount > 0 {
                                        Text(model.text(.colabActiveBadge, String(usage.colabActiveCount)))
                                            .font(.caption)
                                            .lineLimit(1)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .foregroundStyle(.green)
                                            .background(Capsule().fill(Color.green.opacity(0.15)))
                                    }
                                    Text(usage.colabBalance ?? "—")
                                        .font(.caption.monospacedDigit())
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                                } else {
                                    Text(usage.plan)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                                }
                            }
                        }
                        if let usage = row.usage {
                            if usage.isColab {
                                HStack(spacing: 12) {
                                    Text(model.text(.colabRowBalance, usage.colabBalance ?? "—"))
                                    Text(model.text(.colabRowRate, usage.colabRate ?? "—"))
                                    Text(model.text(.colabRowSessions, String(usage.colabActiveCount)))
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            } else if usage.fiveHour != nil || usage.weekly != nil {
                                HStack(spacing: 12) {
                                    if let fiveHour = usage.fiveHour {
                                        Text("5h \(fiveHour)")
                                    }
                                    if let weekly = usage.weekly {
                                        Text("7d \(weekly)")
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .background {
                // 鼠标走下面的手势。这个看不见的按钮只给键盘用：系统打开“键盘导航”时，Tab 能停在这一行，空格切换。
                Button {
                    model.switchTo(row)
                } label: {
                    Color.clear
                }
                .buttonStyle(.plain)
                .allowsHitTesting(false)
                .disabled(!selectable)
                .accessibilityHidden(true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { pressed($0.translation) }
                    .onEnded { released($0.translation) }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.switchTo(row)
            }
            Menu {
                Button(model.text(.panelRename)) {
                    model.ask(.rename(row))
                }
                Button(model.text(.panelRemove)) {
                    model.ask(.remove(row))
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else if hovering, selectable {
                Color.primary.opacity(0.08)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct PromptView: View {
    var prompt: PanelPrompt
    @ObservedObject var model: PanelModel
    @FocusState private var typing: Bool

    private var title: String {
        switch prompt {
        case .save:
            return model.text(.panelSavePrompt)
        case .replace(let name, let holder):
            return model.text(.panelReplaceConfirm, name, holder)
        case .rename(let row):
            return model.text(.panelRenamePrompt, row.name)
        case .remove(let row):
            return model.text(.panelRemoveConfirm, row.name, row.email)
        case .removeLastCopy(let row):
            return model.text(.panelRemoveLastCopy, row.name, row.email)
        case .colabWaiting:
            return model.text(.panelColabWaiting)
        case .colabCode:
            return model.text(.panelColabCodePrompt)
        }
    }

    private var confirmLabel: TextKey {
        switch prompt {
        case .save, .rename, .colabCode:
            return .panelConfirm
        case .replace:
            return .panelReplaceNow
        case .remove, .removeLastCopy:
            return .panelRemoveNow
        case .colabWaiting:
            return .panelColabUseCode
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if prompt.needsText {
                TextField("", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit { model.confirm() }
                    .onAppear { typing = true }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(model.text(.panelCancel)) {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.text(confirmLabel)) {
                    model.confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
    }
}
