import AgyAccount
import AppKit
import Foundation

enum PanelPrompt: Equatable {
    case save
    // 要存的名字下面已经存着别的邮箱 holder。
    case replace(name: String, holder: String)
    case rename(AccountRow)
    case remove(AccountRow)
    case removeLastCopy(AccountRow)
    case colabWaiting
    case colabCode

    var needsText: Bool {
        switch self {
        case .save, .rename, .colabCode:
            return true
        case .replace, .remove, .removeLastCopy, .colabWaiting:
            return false
        }
    }
}

// 面板的状态。每个动作在后台队列里按顺序执行，同一时间只有一个；结果回到主线程再显示。
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var provider: AccountProvider
    @Published private(set) var state: BoardState
    @Published private(set) var messages: [String] = []
    @Published private(set) var failed = false
    @Published private(set) var busy: String? {
        didSet {
            if busy == nil, leaving {
                exit()
            }
        }
    }
    @Published private(set) var prompt: PanelPrompt?
    @Published private(set) var loggingIn = false
    @Published var draft = ""
    var onKeepsOpenChanged: ((Bool) -> Void)?

    private let board: AccountBoard
    private let executable: String
    private let open: (URL) -> Bool
    private let rereadEvery: TimeInterval
    private let shown: @MainActor () -> Bool
    private let work = DispatchQueue(label: "agy-cs.panel", qos: .userInitiated)
    private var watcher: Timer?
    private let exit: @MainActor () -> Void
    private var leaving = false
    private let loginRunner: any PanelLoginRunning
    private var loginPipe: (any PanelLoginChannel)?
    private var loginGeneration = 0
    private var committingLogin = false
    private var loginSettled = false
    private var savedLogin = false
    private var loginErrors: [String] = []
    private let pasteboard: () -> (changeCount: Int, string: String?)
    private var clipboardTimer: Timer?
    private var clipboardChange = 0

    // shown 说面板现在是不是开着。
    init(
        board: AccountBoard = AccountBoard(),
        executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0],
        rereadEvery: TimeInterval = 2,
        shown: @escaping @MainActor () -> Bool = { false },
        open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        exit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        loginRunner: any PanelLoginRunning = ProcessPanelLogin(),
        pasteboard: @escaping () -> (changeCount: Int, string: String?) = {
            let board = NSPasteboard.general
            return (board.changeCount, board.string(forType: .string))
        }
    ) {
        self.exit = exit
        self.board = board
        self.executable = executable
        self.rereadEvery = rereadEvery
        self.shown = shown
        self.open = open
        self.loginRunner = loginRunner
        self.pasteboard = pasteboard
        let initial = board.selectedProvider()
        self.provider = initial
        state = board.load(provider: initial)
    }

    var lines: [String] {
        messages + state.notices.filter { !messages.contains($0) }
    }

    var showsFailure: Bool {
        failed || state.failed
    }

    // 正在做的事要显示的那句话。拖动排序这样一下就完的动作不显示，也不把按钮变灰。
    var busyLabel: String? {
        busy.flatMap { $0.isEmpty ? nil : $0 }
    }

    var isWorking: Bool {
        busyLabel != nil || loggingIn
    }

    func text(_ key: TextKey, _ arguments: String...) -> String {
        let mapped = providerTextKey(key, provider: state.provider)
        return state.text.line(mapped, argumentList: arguments)
    }

    func toggleProvider() {
        guard busy == nil, !loggingIn else {
            return
        }
        let next = provider.next
        provider = next
        prompt = nil
        draft = ""
        messages = []
        failed = false
        busy = text(.panelWorking)
        let board = board
        work.async {
            try? board.setSelectedProvider(next)
            let fresh = board.load(provider: next)
            DispatchQueue.main.async {
                self.busy = nil
                self.state = fresh
            }
        }
    }

    // 名字是给命令行选账号用的，面板上只显示邮箱。同一个邮箱存了几个名字时才带上名字，不然这几行分不出来。
    func showsName(_ row: AccountRow) -> Bool {
        state.rows.filter { $0.email == row.email }.count > 1
    }

    // 面板打开期间每两秒重读一次记录：切换之后的额度查询在另一个进程里，查完才写进来。
    func panelOpened() {
        reload()
        guard watcher == nil else {
            return
        }
        watcher = Timer.scheduledTimer(withTimeInterval: rereadEvery, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    // 当前账号那几行也能点：同一个登录存了几个名字时，点另一个名字把它记成当前项。
    func switchTo(_ row: AccountRow) {
        guard !loggingIn else {
            return
        }
        run(["switch", "--", row.name], saying: text(.panelWorking)) { $0.output + $0.errors }
    }

    // 拖动一行松手之后调用。先在面板上把这一行放到新位置，再执行 move 把顺序记下来；不显示“正在处理”。
    func move(_ row: AccountRow, to index: Int) {
        guard busy == nil, !loggingIn, let from = state.rows.firstIndex(of: row), from != index, state.rows.indices.contains(index) else {
            return
        }
        state.rows.remove(at: from)
        state.rows.insert(row, at: index)
        run(["move", row.name, String(index + 1)], saying: "") { $0.succeeded ? [] : $0.errors }
    }

    func refresh() {
        let done = text(.panelRefreshed)
        run(["refresh", "quota"], saying: text(.panelRefreshing)) { $0.succeeded ? [done] : $0.errors }
    }

    func setLanguage(_ code: String) {
        run(["language", code], saying: text(.panelWorking)) { $0.succeeded ? Array($0.output.suffix(1)) : $0.errors }
    }

    func addAccount() {
        guard busy == nil, !loggingIn else {
            return
        }
        if provider == .colab {
            beginColabLogin()
            return
        }
        prompt = nil
        draft = ""
        busy = text(.panelWorking)
        let board = board
        let executable = executable
        let currentProvider = provider
        work.async {
            let script = try? board.writeAddAccountCommand(executable: executable, provider: currentProvider)
            DispatchQueue.main.async {
                let opened = script.map(self.open) ?? false
                self.busy = nil
                self.failed = !opened
                self.messages = [
                    opened
                        ? self.text(.panelAddOpened)
                        : self.text(.panelAddFailed, board.addAccountCommandLine(executable: executable, provider: currentProvider)),
                ]
            }
        }
    }

    func ask(_ question: PanelPrompt) {
        guard busy == nil, !loggingIn else {
            return
        }
        if case .rename(let row) = question {
            draft = row.name
        } else {
            draft = ""
        }
        prompt = question
    }

    func cancel() {
        if loggingIn {
            loginPipe?.send("cancel")
            return
        }
        prompt = nil
        draft = ""
    }

    func confirm() {
        guard let question = prompt else {
            return
        }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch question {
        case .save:
            save(["save", name])
        case .replace(let name, let holder):
            // --expect 带着刚才问的那个邮箱：名字下面这时又换成了别的登录的话，指令不替换，这里再问一次。
            save(["save", name, "--force", "--expect", holder])
        case .rename(let row):
            run(["rename", row.name, name], saying: text(.panelWorking)) { $0.output + $0.errors }
        case .remove(let row):
            // 当前记录只剩这一份副本时，指令会拒绝。这时再问一次，确认了才带 --force。
            // --expect 带着这一行显示的邮箱：这个名字后来存成了别的登录时，指令不删。
            run(
                ["rm", row.name, "--expect", row.email],
                saying: text(.panelWorking),
                retry: { $0.failure == .onlyCopy ? .removeLastCopy(row) : nil }
            ) { $0.output + $0.errors }
        case .removeLastCopy(let row):
            run(["rm", row.name, "--force", "--expect", row.email], saying: text(.panelWorking)) { $0.output + $0.errors }
        case .colabWaiting:
            loginPipe?.send("fallback")
        case .colabCode:
            submitColabCode(draft)
        }
    }

    // 名字下面存着另一个登录时指令会拒绝。这时把它存着的邮箱拿来问一次，确认了才替换。
    // 读不出邮箱的副本没法这样确认，直接显示指令说的话。
    private func save(_ arguments: [String]) {
        run(arguments, saying: text(.panelWorking), retry: { outcome in
            guard outcome.failure == .saveWouldReplace, outcome.details.count == 2, !outcome.details[1].isEmpty else {
                return nil
            }
            return .replace(name: outcome.details[0], holder: outcome.details[1])
        }) { $0.output + $0.errors }
    }

    // 有指令正在执行时不马上退出，等它做完：切换是先换钥匙串、再记当前账号，中途退出会只做了一半。
    func quit() {
        if loggingIn {
            leaving = true
            loginPipe?.send("cancel")
            let generation = loginGeneration
            work.asyncAfter(deadline: .now() + 2) {
                DispatchQueue.main.async {
                    guard self.leaving, self.loggingIn, !self.committingLogin, self.loginGeneration == generation else {
                        return
                    }
                    self.loginPipe?.stop()
                    self.exit()
                }
            }
            return
        }
        guard busy == nil else {
            leaving = true
            return
        }
        exit()
    }

    private func run(
        _ arguments: [String],
        saying label: String,
        retry: @escaping (ActionOutcome) -> PanelPrompt? = { _ in nil },
        report: @escaping (ActionOutcome) -> [String]
    ) {
        guard busy == nil, !loggingIn else {
            return
        }
        prompt = nil
        draft = ""
        busy = label
        let board = board
        let currentProvider = provider
        work.async {
            let outcome = board.perform(currentProvider.cliPrefix + arguments)
            let fresh = board.load(provider: currentProvider)
            DispatchQueue.main.async {
                self.busy = nil
                self.state = fresh
                if let again = retry(outcome) {
                    self.messages = []
                    self.failed = false
                    self.prompt = again
                } else {
                    self.messages = report(outcome)
                    self.failed = !outcome.succeeded
                }
            }
        }
    }

    private func reload() {
        guard busy == nil else {
            return
        }
        let board = board
        let currentProvider = provider
        work.async {
            let fresh = board.load(provider: currentProvider)
            DispatchQueue.main.async {
                guard self.busy == nil, self.provider == currentProvider, self.differs(fresh) else {
                    return
                }
                self.state = fresh
            }
        }
    }

    private func differs(_ fresh: BoardState) -> Bool {
        fresh.rows != state.rows || fresh.notices != state.notices || fresh.failed != state.failed
            || fresh.language != state.language || fresh.provider != state.provider
    }

    private func tick() {
        if shown() {
            reload()
        } else {
            panelClosed()
        }
    }

    // 面板关掉之后停止重读，做成了的那句话不留到下次打开；没做成的留着。
    func panelClosed() {
        watcher?.invalidate()
        watcher = nil
        guard busy == nil, !loggingIn else {
            return
        }
        prompt = nil
        draft = ""
        if !failed {
            messages = []
        }
    }

    private func beginColabLogin() {
        prompt = .colabWaiting
        draft = ""
        messages = []
        failed = false
        loginSettled = false
        savedLogin = false
        loginErrors = []
        committingLogin = false
        loginGeneration += 1
        loggingIn = true
        onKeepsOpenChanged?(true)
        stopClipboard()
        loginPipe = loginRunner.launch(
            executable: executable,
            arguments: ["colab", "switch", "add", "--handoff"],
            onLine: { [weak self] line in
                self?.consumeLogin(line)
            },
            onError: { [weak self] line in
                self?.noteLoginError(line)
            },
            onExit: { [weak self] in
                self?.finishLoginPipe()
            }
        )
    }

    private func consumeLogin(_ line: String) {
        switch parseColabLoginLine(line) {
        case .opened:
            prompt = .colabWaiting
        case .needCode:
            prompt = .colabCode
            draft = ""
            startClipboard()
        case .committing:
            committingLogin = true
        case .retry(let key):
            failed = true
            messages = [text(key)]
            if prompt != .colabCode {
                prompt = .colabWaiting
                stopClipboard()
            } else {
                startClipboard()
            }
        case .saved(let name, let email):
            showSaved(name: name, email: email)
        case .error(let key):
            loginSettled = true
            failed = true
            messages = [text(key)]
            prompt = nil
            draft = ""
            stopClipboard()
        case .ignored:
            break
        }
    }

    private func noteLoginError(_ line: String) {
        guard !line.isEmpty else {
            return
        }
        loginErrors.append(line)
        if savedLogin {
            messages = savedMessages()
        }
    }

    private func showSaved(name: String, email: String) {
        loginSettled = true
        savedLogin = true
        failed = false
        prompt = nil
        draft = ""
        stopClipboard()
        messages = [text(.saved, name, email)] + loginErrors
        let board = board
        let currentProvider = provider
        work.async {
            let fresh = board.load(provider: currentProvider)
            DispatchQueue.main.async {
                guard self.provider == currentProvider else {
                    return
                }
                self.state = fresh
            }
        }
    }

    private func savedMessages() -> [String] {
        messages.filter { loginErrors.contains($0) == false } + loginErrors
    }

    private func finishLoginPipe() {
        if !loginSettled {
            loginSettled = true
            failed = true
            messages = loginErrors.isEmpty ? [text(.colabLoginCancelled)] : loginErrors
            prompt = nil
            draft = ""
        } else if savedLogin {
            messages = savedMessages()
        }
        loggingIn = false
        committingLogin = false
        stopClipboard()
        loginPipe = nil
        onKeepsOpenChanged?(false)
        if leaving {
            exit()
        }
    }

    private func submitColabCode(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isColabManualCode(code) else {
            failed = true
            messages = [text(.colabLoginCodeRejected)]
            return
        }
        draft = ""
        failed = false
        messages = []
        loginPipe?.send(code)
    }

    func pollClipboard() {
        guard loggingIn, prompt == .colabCode else {
            return
        }
        let sample = pasteboard()
        guard sample.changeCount != clipboardChange else {
            return
        }
        clipboardChange = sample.changeCount
        let code = sample.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isColabClipboardCode(code) else {
            return
        }
        submitColabCode(code)
    }

    private func startClipboard() {
        clipboardChange = pasteboard().changeCount
        guard clipboardTimer == nil else {
            return
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClipboard()
            }
        }
    }

    private func stopClipboard() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }
}
