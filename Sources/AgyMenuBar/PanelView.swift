import AgyAccount
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accounts
            if model.busy != nil || !model.lines.isEmpty {
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
        .frame(width: 420)
        .background(WindowReader { window in
            model.window = window
            if window != nil {
                model.panelOpened()
            }
        })
        .onAppear { model.panelOpened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === model.window {
                model.panelOpened()
            }
        }
    }

    @ViewBuilder private var accounts: some View {
        let rows = VStack(spacing: 2) {
            ForEach(model.state.rows) { row in
                AccountRowView(row: row, model: model)
            }
        }
        .padding(6)
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

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let busy = model.busy {
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
        HStack(spacing: 8) {
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
            Spacer()
            Menu {
                Button(model.text(.panelSave)) {
                    model.ask(.save)
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
        .disabled(model.busy != nil)
    }
}

private struct AccountRowView: View {
    var row: AccountRow
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    private var selectable: Bool {
        model.busy == nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                model.switchTo(row)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text(row.email)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let usage = row.usage {
                                Text(usage.plan)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                            }
                        }
                        if let usage = row.usage {
                            HStack(spacing: 12) {
                                Text("5h \(usage.fiveHour)")
                                Text("7d \(usage.weekly)")
                                Text("Argon \(usage.argon)")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(selectable)
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
            .disabled(model.busy != nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering && selectable ? Color.primary.opacity(0.08) : Color.clear)
        )
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
        }
    }

    private var confirmLabel: TextKey {
        switch prompt {
        case .save, .rename:
            return .panelConfirm
        case .replace:
            return .panelReplaceNow
        case .remove, .removeLastCopy:
            return .panelRemoveNow
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

// 面板所在的窗口。用它判断面板是不是还开着。
private struct WindowReader: NSViewRepresentable {
    var found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.found = found
        return probe
    }

    func updateNSView(_ probe: WindowProbe, context: Context) {
        probe.found = found
    }
}

private final class WindowProbe: NSView {
    var found: (NSWindow?) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        found(window)
    }
}
