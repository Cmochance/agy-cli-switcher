import Foundation

enum AccountCommandKind {
    case current
    case list
    case save(String, force: Bool, expecting: String?)
    case choose
    case add(handoff: Bool)
    case change(String)
    case next
    case refreshQuota
    case refreshQuotaDetached
    case rename(from: String?, to: String)
    case move(String, to: String)
    case remove(String, force: Bool, expecting: String?)
    case help
    case languageShow
    case languageSet(String)
}

struct AccountCommands {
    var files: AccountFiles
    var profile: ToolProfile
    var keychain: any KeychainStoring
    var processes: any ProcessListing
    var terminal: any LineReading
    var launcher: any AgyLaunching
    var usage: any UsageFetching
    var refresher: any QuotaRefreshStarting
    var stateWait: TimeInterval = 5
    var provider: AccountProvider = .antigravity
    var codec: any LoginDecoding = AntigravityLoginCodec()
    var stateSync: any ProviderStateSyncing
    var signer: (any ColabSigning)? = nil
    var text: Localizer
    var stdout: (String) -> Void
    var stderr: (String) -> Void

    private func spoken(_ key: TextKey, _ arguments: String...) -> String {
        spoken(key, argumentList: arguments)
    }

    private func spoken(_ key: TextKey, argumentList: [String]) -> String {
        text.line(providerTextKey(key, provider: provider), argumentList: argumentList)
    }

    func initializeIfNeeded() throws {
        if profile.isInitialized() {
            return
        }
        if !profile.names().isEmpty {
            try profile.markInitialized()
            return
        }
        let blob: String
        let meta: LoginMeta
        do {
            (blob, meta) = try readKeychainLogin()
        } catch let error as AccountFailure where error.key == .keychainMissing {
            try profile.markInitialized()
            stderr(spoken(.initializedNoLogin))
            return
        }
        let name: String
        do {
            name = try defaultAccountName(email: meta.email)
        } catch {
            try profile.markInitialized()
            stderr(text.line(.initializedNameRejected, meta.email))
            return
        }
        try files.writeSaved(name: name, blob: blob, meta: meta)
        try profile.write(name: name, meta: meta)
        try files.setActive(name)
        try profile.setActive(name)
        try profile.markInitialized()
        stdout(text.line(.initializedSaved, name, meta.email))
    }

    func run(_ command: AccountCommandKind) throws {
        switch command {
        case .current:
            try current()
        case .list:
            try list()
            reportFailedRefresh()
        case .save(let name, let force, let expecting):
            try locked { try save(name, force: force, expecting: expecting) }
        case .choose:
            try choose()
        case .add(let handoff):
            try addFromCommand(handoff: handoff)
        case .change(let name):
            try locked { try switchTo(name) }
        case .next:
            try locked { try next() }
        case .refreshQuota:
            try refreshQuota()
        case .refreshQuotaDetached:
            refresher.spawnWorker()
        case .rename(let from, let to):
            try locked { try rename(from: from, to: to) }
        case .move(let name, let position):
            try locked { try move(name, to: position) }
        case .remove(let name, let force, let expecting):
            try locked { try remove(name, force: force, expecting: expecting) }
        case .help:
            stdout(text.line(.help))
        case .languageShow:
            showLanguage(text)
        case .languageSet(let code):
            try setLanguage(code)
        }
    }

    private func choose() throws {
        guard terminal.isInteractive else {
            throw UsageFailure(.switchNeedsTerminal)
        }
        while true {
            let live = currentLogin()
            let activeName = live.name
            let activeEmail = live.email
            let others = profile.names().filter { $0 != activeName }
            if activeName.isEmpty || activeEmail.isEmpty {
                stdout("  1. " + text.line(.menuNoCurrent))
            } else {
                stdout("  1. \(activeName)  \(activeEmail)" + text.line(.menuCurrentSuffix))
            }
            stdout("  2. " + text.line(.menuAddAccount))
            for (offset, name) in others.enumerated() {
                let email = try profile.read(name).email
                stdout("  \(offset + 3). \(name)  \(email)")
            }
            stdout(text.line(.menuPrompt))
            guard let answer = terminal.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            if answer == "q" || answer == "Q" {
                return
            }
            guard let number = Int(answer) else {
                stderr(text.line(.menuBadChoice))
                continue
            }
            if number == 1 {
                stderr(text.line(.menuCurrentLocked))
                continue
            }
            if number == 2 {
                if provider == .colab {
                    try addColabAccount(handoff: false)
                } else {
                    try addAccount()
                }
                return
            }
            let index = number - 3
            guard others.indices.contains(index) else {
                stderr(text.line(.menuBadChoice))
                continue
            }
            try locked { try switchTo(others[index]) }
            try launchToolIfNeeded()
            return
        }
    }

    private func addFromCommand(handoff: Bool) throws {
        if provider == .colab {
            try addColabAccount(handoff: handoff)
            return
        }
        if handoff {
            throw UsageFailure(.commandNoExtra, "switch")
        }
        guard terminal.isInteractive else {
            throw UsageFailure(.switchAddNeedsTerminal)
        }
        try addAccount()
    }

    // 浏览器登录期间不拿锁，也不删钥匙串。拿到 token 之后才写。取消或进程没了，原来的登录还在。
    private func addColabAccount(handoff: Bool) throws {
        if !handoff, !terminal.isInteractive {
            throw UsageFailure(.switchAddNeedsTerminal)
        }
        let blob: String
        let committed: (name: String, email: String, notices: [ProviderNotice])
        do {
            blob = try colabSigner().signIn(handoff: handoff)
            if handoff {
                stdout("\(colabLoginLinePrefix) committing")
            }
            committed = try commitColabLogin(blob)
        } catch let error as AccountFailure {
            if handoff {
                stdout("\(colabLoginLinePrefix) error \(error.key.rawValue)")
            }
            throw error
        }
        if handoff {
            for notice in committed.notices {
                stderr(text.line(providerTextKey(notice.key, provider: provider), argumentList: notice.arguments))
            }
            stdout("\(colabLoginLinePrefix) saved \(committed.name) \(committed.email)")
        } else {
            emitProviderNotices(committed.notices)
            stdout(text.line(.saved, committed.name, committed.email))
        }
        refresher.startDetached()
        try launchToolIfNeeded()
    }

    private func colabSigner() -> any ColabSigning {
        if let signer {
            return signer
        }
        return ColabBrowserSigner(
            stdout: stdout,
            speak: { self.text.line($0) }
        )
    }

    private func commitColabLogin(_ blob: String) throws -> (name: String, email: String, notices: [ProviderNotice]) {
        try locked {
            let meta = try decodeKeychainBlob(blob)
            try keychain.checkWritable(blob)
            // 名字被占时还没动钥匙串，也还没写回滚副本。
            let name = try availableDefaultName(meta.email)
            let snapshot = try captureLogin()
            var previousNames: [String] = []
            let emailChanged = snapshot.map { $0.meta.email != meta.email } ?? false
            if let snapshot {
                if snapshot.meta.email == meta.email {
                    try keepSnapshot(ObservedLogin(blob: blob, meta: meta))
                } else if profile.dismissedEmail() == snapshot.meta.email,
                          profile.slots(forEmail: snapshot.meta.email).isEmpty
                {
                    try files.writeRollback(snapshot.blob)
                } else {
                    try keepSnapshot(snapshot)
                    previousNames = profile.slots(forEmail: snapshot.meta.email)
                    try stateSync.prepareSwitch(from: previousNames, to: "", sameEmail: false)
                }
            }
            do {
                try keychain.writeBlob(blob)
                try storeLogin(name: name, blob: blob, meta: meta)
                files.removeRollback()
                let notices = emailChanged
                    ? stateSync.afterSwitch(from: previousNames, to: name, sameEmail: false)
                    : []
                return (name, meta.email, notices)
            } catch {
                if let snapshot {
                    do {
                        try keychain.writeBlob(snapshot.blob)
                        files.removeRollback()
                        stderr(text.line(.loginRestored))
                    } catch {
                        try? keychain.deleteBlob()
                    }
                } else {
                    try? keychain.deleteBlob()
                }
                throw error
            }
        }
    }

    // 从移开钥匙串那一项到新登录存好（或者原来的登录写回去）一直拿着锁：这段时间钥匙串是空的或者是还没存的新登录，
    // 别的进程不能切换，面板的自动保存也不能抢在前面把新登录存掉。重新启动 agy 之前放开。
    private func addAccount() throws {
        let (name, observed, notices): (String, ObservedLogin, [ProviderNotice]) = try locked {
            let snapshot = try captureLogin()
            var previousNames: [String] = []
            if let snapshot {
                try keychain.checkWritable(snapshot.blob)
                // 用户带着 --force 删掉过的登录不存回账号名单，但登录期间要留一份在 rollbackURL：
                // 进程中途被杀掉时，下一条指令从那里把它写回钥匙串。新登录存好或者原登录写回去之后删掉。
                if profile.dismissedEmail() == snapshot.meta.email, profile.slots(forEmail: snapshot.meta.email).isEmpty {
                    try files.writeRollback(snapshot.blob)
                } else {
                    try keepSnapshot(snapshot)
                    previousNames = profile.slots(forEmail: snapshot.meta.email)
                    try stateSync.prepareSwitch(from: previousNames, to: "", sameEmail: false)
                }
            }
            try keychain.deleteBlob()
            do {
                stdout(spoken(.loginOpening))
                let outcome = try launcher.runUntilLoggedIn {
                    try self.observeLogin()
                }
                guard case .loggedIn(let login) = outcome else {
                    throw AccountFailure(snapshot == nil ? .loginNotFinished : .loginCancelled)
                }
                let name = try availableDefaultName(login.meta.email)
                try storeLogin(name: name, blob: login.blob, meta: login.meta)
                files.removeRollback()
                let notices: [ProviderNotice]
                if let snapshot {
                    notices = stateSync.afterSwitch(
                        from: previousNames,
                        to: name,
                        sameEmail: snapshot.meta.email == login.meta.email
                    )
                } else {
                    notices = []
                }
                return (name, login, notices)
            } catch {
                if let snapshot {
                    try keychain.writeBlob(snapshot.blob)
                    files.removeRollback()
                    if (error as? AccountFailure)?.key != .loginCancelled {
                        stderr(text.line(.loginRestored))
                    }
                }
                throw error
            }
        }
        emitProviderNotices(notices)
        stdout(text.line(.saved, name, observed.meta.email))
        reportOtherAgyIfNeeded()
        refresher.startDetached()
        try launchToolIfNeeded()
    }

    // 联网查询所有已保存账号的套餐和额度。只用保存的副本，不读钥匙串。
    // 切换之后由另一个进程执行这条指令，所以这里出什么问题都不影响切换。
    private func refreshQuota() throws {
        let started = DispatchTime.now()
        // 当前登录还没保存过的话先存下来，这一次就把它一起查了，不用再另起一个进程。
        _ = currentLogin(refreshing: false)
        guard let lock = profile.lockUsage(wait: usage.budget) else {
            throw AccountFailure(.usageBusy)
        }
        defer { close(lock.descriptor) }
        // 等过锁，说明另一个进程刚查完。它查过的账号直接用它记下的结果，只补查它没见过的。
        let earlier = lock.waited ? failedRefresh() : []
        var failed: [String] = []
        var saved: [(name: String, blob: String, email: String)] = []
        for name in profile.names() {
            guard let login = try? files.readSaved(name) else {
                failed.append(name)
                continue
            }
            if earlier.contains(name) {
                failed.append(name)
            } else if !lock.waited || profile.readUsage(name, email: login.meta.email) == nil {
                saved.append((name, login.blob, login.meta.email))
            }
        }
        let spent = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        let fetched = saved.isEmpty
            ? [:]
            : usage.fetch(
                saved.map { login in
                    let known = profile.readUsage(login.name, email: login.email)?.project ?? ""
                    return (name: login.name, blob: login.blob, project: known)
                },
                within: usage.budget - spent
            )
        failed += saved.filter { login in
            // 查询期间这个名字可能已经被删掉或改存成别的登录。
            guard var snapshot = fetched[login.name], (try? profile.read(login.name).email) == login.email else {
                return true
            }
            // 模型列表这次没取到时，沿用上次记下的结果。
            snapshot.argonLocked = snapshot.argonLocked ?? profile.readUsage(login.name, email: login.email)?.argonLocked
            return (try? profile.writeUsage(login.name, snapshot, email: login.email)) == nil
        }.map(\.name)
        failed.sort()
        try profile.writeUsageStatus(failed: failed)
        try list()
        if !failed.isEmpty {
            throw AccountFailure(.usageFailed, failed.joined(separator: ", "))
        }
    }

    // 后台那次查询没有终端可以报错，所以把结果记下来，在 list 里提示。
    private func reportFailedRefresh() {
        if let notice = failedRefreshNotice() {
            stderr(notice)
        }
    }

    func failedRefreshNotice() -> String? {
        let failed = failedRefresh()
        return failed.isEmpty ? nil : text.line(.usageFailed, failed.joined(separator: ", "))
    }

    private func failedRefresh() -> [String] {
        let names = profile.names()
        return profile.failedUsage().filter(names.contains)
    }

    private func keepSnapshot(_ snapshot: ObservedLogin) throws {
        let recorded = profile.slots(forEmail: snapshot.meta.email)
        var backedUp = false
        for name in recorded {
            let tokenPath = files.locations.tokenURL(name).path
            if !FileManager.default.fileExists(atPath: tokenPath) {
                try files.writeSaved(name: name, blob: snapshot.blob, meta: snapshot.meta)
                try profile.write(name: name, meta: snapshot.meta)
                backedUp = true
                continue
            }
            guard let saved = try? files.readSaved(name), saved.meta.email == snapshot.meta.email else {
                continue
            }
            if saved.blob != snapshot.blob {
                try files.writeSaved(name: name, blob: snapshot.blob, meta: snapshot.meta)
                try profile.write(name: name, meta: snapshot.meta)
            }
            backedUp = true
        }
        if !backedUp {
            try saveUnsaved(snapshot)
        }
    }

    private func rename(from sourceName: String?, to targetName: String) throws {
        let target = try checkNewName(targetName)
        let source: String
        if let sourceName {
            source = try checkName(sourceName)
        } else {
            let active = currentLogin(holdingLock: true).name
            guard !active.isEmpty else {
                throw AccountFailure(.noCurrentAccount)
            }
            source = try checkName(active)
        }
        guard profile.names().contains(source) else {
            throw missingAccount(source)
        }
        let meta = try profile.read(source)
        if source == target {
            stdout(text.line(.renameUnchanged, source, meta.email))
            return
        }
        if profile.names().contains(target) {
            throw AccountFailure(.nameTaken, target, try profile.read(target).email)
        }
        if files.secretExists(target) {
            throw AccountFailure(.nameTaken, target, meta.email)
        }
        let savedAt = profile.savedAt(source)
        let profileWasActive = profile.activeName() == source
        let filesWereActive = files.activeName() == source
        // 改名之后这个账号留在原来的位置。没记过顺序时它原来按字母排，新名字会排到别处，所以这里把顺序记下来。
        let sequence = profile.names().map { $0 == source ? target : $0 }
        try profile.write(name: target, meta: meta, savedAt: savedAt, placing: false)
        do {
            try files.renameSaved(from: source, to: target, meta: meta, savedAt: savedAt)
        } catch {
            try? profile.deleteRecord(target)
            throw error
        }
        try profile.deleteRecord(source)
        profile.moveUsage(from: source, to: target)
        stateSync.renameAuxiliary(from: source, to: target)
        try? profile.setOrder(sequence)
        if profileWasActive {
            try profile.setActive(target)
        }
        if filesWereActive {
            try files.setActive(target)
        }
        stdout(text.line(.renamed, source, target, meta.email))
    }

    // 把一个账号移到列表的第几位。list、不带名字的 switch 和 next 都按这个顺序。只改 ~/.agy-cs/order。
    private func move(_ name: String, to position: String) throws {
        let checked = try checkName(name)
        var names = profile.names()
        guard let from = names.firstIndex(of: checked) else {
            throw missingAccount(checked)
        }
        guard let place = Int(position), (1 ... names.count).contains(place) else {
            throw AccountFailure(.moveBadPosition, String(names.count))
        }
        names.remove(at: from)
        names.insert(checked, at: place - 1)
        try profile.setOrder(names)
        stdout(text.line(.moved, checked, String(place)))
    }

    private func current() throws {
        let live = currentLogin(announcing: false)
        guard !live.email.isEmpty else {
            throw AccountFailure(live.missing ? .currentNoLogin : .noCurrentAccount)
        }
        live.notices.forEach(stderr)
        stdout(live.email)
    }

    struct CurrentLogin {
        var email = ""
        var name = ""
        var missing = false
        var notices: [String] = []
    }

    // 当前账号是谁，只看钥匙串里那一项的邮箱，不看 ~/.agy-cs/active：别的进程（比如还开着的 agy）会改钥匙串。
    // active 只在同一个邮箱存了几个名字时决定指的是哪个名字，和钥匙串对不上就改正它。
    // 钥匙串里的邮箱还没保存过时直接保存，不提示。钥匙串读不出来时退回 active 的记录并说一声。
    // holdingLock：调用的指令已经拿着改账号的锁。没拿着时，保存和改正 active 只在拿得到锁的时候做，拿不到就留给下一次。
    func currentLogin(
        holdingLock: Bool = false, saving: Bool = true, announcing: Bool = true, refreshing: Bool = true
    ) -> CurrentLogin {
        var result = CurrentLogin()
        let login: ObservedLogin
        do {
            if files.readRollback() != nil {
                if holdingLock {
                    recoverInterruptedAdd()
                } else if let descriptor = profile.lockState(wait: 0) {
                    recoverInterruptedAdd()
                    close(descriptor)
                }
            }
            let read = try readKeychainLogin()
            login = ObservedLogin(blob: read.blob, meta: read.meta)
        } catch let error as AccountFailure where error.key == .keychainMissing {
            result.missing = true
            if announcing {
                result.notices.append(spoken(.currentNoLogin))
            }
            return result
        } catch let error as AccountFailure where error.key == .colabMissingEmail || error.key == .colabEmailFailed {
            result.name = profile.activeName()
            result.email = profileEmail(result.name)
            result.notices.append(spoken(error.key, argumentList: error.arguments))
            return result
        } catch {
            result.name = profile.activeName()
            result.email = profileEmail(result.name)
            result.notices.append(text.line(.currentUnreadable))
            return result
        }
        result.email = login.meta.email
        if profile.dismissedEmail() != "", profile.dismissedEmail() != login.meta.email {
            profile.clearDismissed()
        }
        let active = profile.activeName()
        var slots = profile.slots(forEmail: login.meta.email)
        if slots.contains(active) {
            result.name = active
            return result
        }
        guard saving else {
            result.name = slots.first ?? ""
            return result
        }
        let descriptor = holdingLock ? nil : profile.lockState(wait: 0)
        guard holdingLock || descriptor != nil else {
            result.name = slots.first ?? ""
            return result
        }
        defer {
            if let descriptor {
                close(descriptor)
            }
        }
        slots = profile.slots(forEmail: login.meta.email)
        if slots.isEmpty, profile.dismissedEmail() != login.meta.email {
            if (try? saveUnsaved(login)) != nil {
                if refreshing {
                    refresher.startDetached()
                }
            } else {
                result.notices.append(text.line(.autoSaveFailed, login.meta.email))
            }
            slots = profile.slots(forEmail: login.meta.email)
        }
        result.name = slots.first ?? ""
        if !result.name.isEmpty, profile.activeName() != result.name {
            try? files.setActive(result.name)
            try? profile.setActive(result.name)
        }
        return result
    }

    // 名字用邮箱 @ 前面的字符；被另一个邮箱占着时试 -2、-3…，不动别人的副本。
    private func saveUnsaved(_ login: ObservedLogin) throws {
        let base = try defaultAccountName(email: login.meta.email)
        for number in 1 ... 99 {
            // 名字最长 64 个字符，加后缀时把前面截短，留出后缀的位置。
            let suffix = number == 1 ? "" : "-\(number)"
            let head = String(String.UnicodeScalarView(base.unicodeScalars.prefix(64 - suffix.unicodeScalars.count)))
            guard let name = try? checkNewName(head + suffix),
                  (try? checkHolder(of: name, allowed: [login.meta.email])) != nil
            else {
                continue
            }
            try storeLogin(name: name, blob: login.blob, meta: login.meta)
            return
        }
        throw AccountFailure(.invalidName)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        guard let descriptor = profile.lockState(wait: stateWait) else {
            throw AccountFailure(.stateBusy)
        }
        defer { close(descriptor) }
        recoverInterruptedAdd()
        return try body()
    }

    // 上一次新增账号做到一半进程就没了：钥匙串那一项已经移开，原来的登录还留在 rollbackURL。
    // 拿着锁的时候调用（没有别的新增账号正在进行）。钥匙串还空着就把它写回去；已经有登录了就只把这份没用的东西删掉。
    private func recoverInterruptedAdd() {
        guard let blob = files.readRollback() else {
            return
        }
        do {
            let current = try keychain.readBlob()
            // Antigravity 的钥匙串里已经有登录时，这份回滚是用过的。Colab 可能刚写进新登录、旧的只在这里，对不上已保存的副本时写回去。
            if current == blob || provider != .colab || savedLogin(current) {
                files.removeRollback()
                return
            }
            guard codec.canRecover(blob), (try? keychain.writeBlob(blob)) != nil else {
                return
            }
            files.removeRollback()
        } catch let error as AccountFailure where error.key == .keychainMissing {
            guard codec.canRecover(blob), (try? keychain.writeBlob(blob)) != nil else {
                return
            }
            files.removeRollback()
        } catch {
            return
        }
    }

    private func savedLogin(_ blob: String) -> Bool {
        files.savedNames().contains { name in
            (try? files.readSaved(name))?.blob == blob
        }
    }

    // 读 ~/.agy-cs/ 里的记录和钥匙串里的邮箱，不联网。list 和菜单栏面板都从这里取。
    func listing() throws -> [AccountRow] {
        let live = currentLogin()
        live.notices.forEach(stderr)
        let activeEmail = live.email
        let moment = parseTimestamp(profile.now()) ?? Date()
        return try profile.names().compactMap { name in
            // 面板每两秒读一次，别的进程可能正在改名或删除：列出名字之后、读它之前，这条记录没了就跳过。
            let meta: LoginMeta
            do {
                meta = try profile.read(name)
            } catch let error as AccountFailure
                where error.key == .accountMissing || error.key == .accountMissingNone || !profile.names().contains(name)
            {
                return nil
            }
            return AccountRow(
                name: name,
                email: meta.email,
                isCurrent: !activeEmail.isEmpty && meta.email == activeEmail,
                usage: profile.readUsage(name, email: meta.email).map { snapshot in
                    usageText(snapshot, now: moment, timeZone: .current) { text.line(.planUnpaid, $0) }
                }
            )
        }
    }

    private func list() throws {
        let accounts = try listing()
        if accounts.isEmpty {
            stdout(spoken(.noSavedAccounts))
            return
        }
        let rows = accounts.map { account in
            ["\(account.isCurrent ? "*" : " ") \(account.name)", account.email] + (account.usage?.cells ?? [])
        }
        alignedRows(rows).forEach(stdout)
    }

    // 名字下面已经存着另一个登录时不替换，那一份保存的登录换掉就找不回来。带 --force 才替换。
    // expecting 是面板上这个名字下面显示的邮箱：带着它时，--force 只替换这个邮箱存的那一份。
    private func save(_ name: String, force: Bool, expecting: String?) throws {
        let checked = try checkNewName(name)
        let (blob, meta) = try readKeychainLogin()
        if !force || expecting != nil {
            let replaceable = force ? [expecting].compactMap { $0 } : []
            do {
                try checkHolder(of: checked, allowed: [meta.email] + replaceable)
            } catch let error as AccountFailure where error.key == .nameTaken {
                throw AccountFailure(.saveWouldReplace, checked, error.arguments.last ?? "")
            }
        }
        let previousEmail = (try? profile.read(checked).email) ?? (try? files.readSaved(checked).meta.email)
        try files.writeSaved(name: checked, blob: blob, meta: meta)
        try profile.write(name: checked, meta: meta)
        if let previousEmail, previousEmail != meta.email {
            stateSync.removeAuxiliary(checked)
        }
        try files.setActive(checked)
        try profile.setActive(checked)
        profile.clearDismissed()
        stdout(text.line(.saved, checked, meta.email))
    }

    private func switchTo(_ name: String) throws {
        let checked = try checkName(name)
        let target = try files.readSaved(checked)
        let (currentBlob, current) = try readKeychainLogin()
        if current.email == target.meta.email {
            let updated = try persistCurrentRefresh(blob: currentBlob, meta: current)
            try files.setActive(checked)
            try profile.setActive(checked)
            stdout(text.line(.alreadyActive, checked, current.email))
            if !updated.isEmpty {
                stdout(text.line(.refreshedTokens, updated.joined(separator: ", ")))
            }
            return
        }
        // 当前登录还没保存过就先存下来再切走。用户带着 --force 删掉的那一个不再存。
        if profile.slots(forEmail: current.email).isEmpty, profile.dismissedEmail() != current.email {
            do {
                try saveUnsaved(ObservedLogin(blob: currentBlob, meta: current))
            } catch {
                throw AccountFailure(.currentNotSaved, current.email)
            }
        }
        let previousNames = profile.slots(forEmail: current.email)
        try stateSync.prepareSwitch(from: previousNames, to: checked, sameEmail: false)
        let updated = try persistCurrentRefresh(blob: currentBlob, meta: current)
        try keychain.writeBlob(target.blob)
        try files.setActive(checked)
        try profile.setActive(checked)
        let notices = stateSync.afterSwitch(from: previousNames, to: checked, sameEmail: false)
        emitProviderNotices(notices)
        stdout(text.line(.switched, checked, target.meta.email))
        if !updated.isEmpty {
            stdout(text.line(.refreshedBeforeSwitch, updated.joined(separator: ", ")))
        }
        if provider == .antigravity {
            reportOtherAgy()
            stdout(text.line(.reopenAgy))
        }
        refresher.startDetached()
    }

    private func next() throws {
        let names = profile.names()
        guard names.count >= 2 else {
            throw AccountFailure(.needTwoAccounts)
        }
        let (_, current) = try readKeychainLogin()
        let matched = profile.slots(forEmail: current.email)
        guard !matched.isEmpty else {
            throw AccountFailure(.currentNotInSaved, current.email)
        }
        let active = profile.activeName()
        var start = matched.contains(active) ? active : matched[0]
        if !names.contains(start) {
            start = matched[0]
        }
        guard let startIndex = names.firstIndex(of: start) else {
            throw AccountFailure(.needTwoAccounts)
        }
        var upcoming = names[(startIndex + 1) % names.count]
        if try profile.read(upcoming).email == current.email {
            var found = false
            for offset in 1 ... names.count {
                let candidate = names[(startIndex + offset) % names.count]
                if try profile.read(candidate).email != current.email {
                    upcoming = candidate
                    found = true
                    break
                }
            }
            if !found {
                throw AccountFailure(.sameEmailOnly)
            }
        }
        try switchTo(upcoming)
    }

    private func remove(_ name: String, force: Bool, expecting: String?) throws {
        let checked = try checkName(name)
        let tokenExists = FileManager.default.fileExists(atPath: files.locations.tokenURL(checked).path)
        let recorded = profile.names().contains(checked)
        guard tokenExists || recorded else {
            throw AccountFailure(.accountMissingNone, checked)
        }
        guard recorded else {
            let existing = profile.names()
            if existing.isEmpty {
                throw AccountFailure(.accountMissingNone, checked)
            }
            throw AccountFailure(.accountMissing, checked, existing.joined(separator: ", "))
        }
        let meta = try profile.read(checked)
        // 面板上的确认可能是对着旧的一行点的。这个名字后来存成了别的登录时不删，带着 --force 也一样。
        if let expecting, meta.email != expecting {
            throw AccountFailure(.accountChanged, checked, meta.email)
        }
        let currentEmail = currentLogin(holdingLock: true, saving: false, announcing: false).email
        let others = profile.slots(forEmail: meta.email).filter { $0 != checked }
        if meta.email == currentEmail, others.isEmpty {
            if !force {
                throw AccountFailure(.onlyCopy, checked, meta.email)
            }
            // 不然下一次 list 又会把它自动存回来。
            profile.setDismissed(meta.email)
        }
        if tokenExists {
            try files.removeSaved(checked)
        }
        try profile.remove(checked)
        stateSync.removeAuxiliary(checked)
        stdout(text.line(.removed, checked, meta.email))
        stdout(text.line(.keychainUnchanged))
    }

    private func showLanguage(_ spoken: Localizer) {
        let code = spoken.language.rawValue
        let name = spoken.language.nativeName
        if profile.languageIsExplicit() {
            stdout(spoken.line(.languageChosen, code, name))
        } else {
            stdout(spoken.line(.languageFollowing, code, name))
        }
        stdout(spoken.line(.languageAvailableHeader))
        for language in AppLanguage.allCases {
            let label = language.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            stdout("  \(label)\(language.nativeName)")
        }
        stdout(spoken.line(.languageHint))
    }

    private func setLanguage(_ code: String) throws {
        guard let selected = AppLanguage.parse(code) else {
            throw UsageFailure(.languageUnknown, code)
        }
        try profile.setLanguage(selected)
        showLanguage(Localizer(language: selected))
        stdout(Localizer(language: selected).line(.languageSet, selected.rawValue, selected.nativeName))
    }

    private func profileEmail(_ name: String) -> String {
        guard !name.isEmpty else {
            return ""
        }
        return (try? profile.read(name).email) ?? ""
    }

    private func launchToolIfNeeded() throws {
        guard launcher.launchesAfterSwitch else {
            return
        }
        stdout(text.line(.startingAgy))
        try launcher.startInCurrentTerminal()
    }

    private func reportOtherAgyIfNeeded() {
        guard provider == .antigravity else {
            return
        }
        reportOtherAgy()
    }

    private func reportOtherAgy() {
        let pids = processes.runningAgyPIDs()
        if !pids.isEmpty {
            stdout(text.line(.agyStillRunning, pids.map(String.init).joined(separator: ", ")))
        }
    }

    private func emitProviderNotices(_ notices: [ProviderNotice]) {
        for notice in notices {
            let mapped = providerTextKey(notice.key, provider: provider)
            let line = text.line(mapped, argumentList: notice.arguments)
            if mapped == .quotaFailed {
                stderr(line)
            } else {
                stdout(line)
            }
        }
    }

    private func captureLogin() throws -> ObservedLogin? {
        do {
            let (blob, meta) = try readKeychainLogin()
            return ObservedLogin(blob: blob, meta: meta)
        } catch let error as AccountFailure where error.key == .keychainMissing {
            return nil
        }
    }

    private func observeLogin() throws -> ObservedLogin? {
        let blob: String
        do {
            blob = try keychain.readBlob()
        } catch let error as AccountFailure where error.key == .keychainMissing {
            return nil
        }
        do {
            return ObservedLogin(blob: blob, meta: try decodeKeychainBlob(blob))
        } catch let error as AccountFailure where error.key == .colabMissingEmail || error.key == .colabEmailFailed {
            throw error
        } catch {
            return nil
        }
    }

    private func availableDefaultName(_ email: String) throws -> String {
        let name = try defaultAccountName(email: email)
        try checkHolder(of: name, allowed: [email])
        return name
    }

    // 名字下面已经有记录或副本时，它的邮箱要在 allowed 里。副本读不出邮箱也算被别人占着。
    private func checkHolder(of name: String, allowed: [String]) throws {
        if profile.names().contains(name) {
            let existing = try profile.read(name).email
            if !allowed.contains(existing) {
                throw AccountFailure(.nameTaken, name, existing)
            }
        }
        if files.secretExists(name) {
            let saved = try? files.readSaved(name).meta.email
            if saved.map(allowed.contains) != true {
                throw AccountFailure(.nameTaken, name, saved ?? "")
            }
        }
    }

    private func storeLogin(name: String, blob: String, meta: LoginMeta) throws {
        let checked = try checkName(name)
        try files.writeSaved(name: checked, blob: blob, meta: meta)
        try profile.write(name: checked, meta: meta)
        try files.setActive(checked)
        try profile.setActive(checked)
        profile.clearDismissed()
    }

    private func missingAccount(_ name: String) -> AccountFailure {
        let existing = profile.names()
        if existing.isEmpty {
            return AccountFailure(.accountMissingNone, name)
        }
        return AccountFailure(.accountMissing, name, existing.joined(separator: ", "))
    }

    private func readKeychainLogin() throws -> (blob: String, meta: LoginMeta) {
        let blob = try keychain.readBlob()
        let meta = try decodeKeychainBlob(blob)
        return (blob, meta)
    }

    private func decodeKeychainBlob(_ blob: String) throws -> LoginMeta {
        try codec.decodeKeychain(blob) { [files, codec] candidateBlob in
            guard let refreshToken = codec.refreshToken(in: candidateBlob) else {
                return nil
            }
            return files.emailMatchingRefreshToken(refreshToken)
        }
    }

    private func persistCurrentRefresh(blob: String, meta: LoginMeta) throws -> [String] {
        var updated: [String] = []
        for name in files.slots(forEmail: meta.email) {
            let saved = try files.readSaved(name)
            if saved.blob != blob {
                try files.writeSaved(name: name, blob: blob, meta: meta)
                try profile.write(name: name, meta: meta)
                updated.append(name)
            }
        }
        return updated
    }
}
