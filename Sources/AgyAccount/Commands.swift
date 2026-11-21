import Foundation

enum AccountCommandKind {
    case current
    case list
    case save(String, force: Bool, expecting: String?)
    case choose
    case add
    case change(String)
    case next
    case refreshQuota
    case refreshQuotaDetached
    case rename(from: String?, to: String)
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
    var text: Localizer
    var stdout: (String) -> Void
    var stderr: (String) -> Void

    func initializeIfNeeded() throws {
        if profile.isInitialized() {
            return
        }
        if !profile.names().isEmpty {
            try profile.markInitialized()
            return
        }
        let blob: String
        do {
            blob = try readKeychain()
        } catch let error as AccountFailure where error.key == .keychainMissing {
            try profile.markInitialized()
            stderr(text.line(.initializedNoLogin))
            return
        }
        let meta = try decodeLogin(blob, source: .keychain)
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
            try save(name, force: force, expecting: expecting)
        case .choose:
            try choose()
        case .add:
            try addFromCommand()
        case .change(let name):
            try switchTo(name)
        case .next:
            try next()
        case .refreshQuota:
            try refreshQuota()
        case .refreshQuotaDetached:
            refresher.spawnWorker()
        case .rename(let from, let to):
            try rename(from: from, to: to)
        case .remove(let name, let force, let expecting):
            try remove(name, force: force, expecting: expecting)
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
            let activeName = profile.activeName()
            let activeEmail = profileEmail(activeName)
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
                try addAccount()
                return
            }
            let index = number - 3
            guard others.indices.contains(index) else {
                stderr(text.line(.menuBadChoice))
                continue
            }
            try switchTo(others[index])
            try launchAgy()
            return
        }
    }

    private func addFromCommand() throws {
        guard terminal.isInteractive else {
            throw UsageFailure(.switchAddNeedsTerminal)
        }
        try addAccount()
    }

    private func addAccount() throws {
        let snapshot = try captureLogin()
        if let snapshot {
            try keychain.checkWritable(snapshot.blob)
            try keepSnapshot(snapshot)
        }
        try keychain.deleteBlob()
        let name: String
        let observed: ObservedLogin
        do {
            stdout(text.line(.loginOpening))
            let outcome = try launcher.runUntilLoggedIn {
                try self.observeLogin()
            }
            guard case .loggedIn(let login) = outcome else {
                throw AccountFailure(snapshot == nil ? .loginNotFinished : .loginCancelled)
            }
            name = try availableDefaultName(login.meta.email)
            try storeLogin(name: name, blob: login.blob, meta: login.meta)
            observed = login
        } catch {
            if let snapshot {
                try keychain.writeBlob(snapshot.blob)
                if (error as? AccountFailure)?.key != .loginCancelled {
                    stderr(text.line(.loginRestored))
                }
            }
            throw error
        }
        if let snapshot, snapshot.meta.email != observed.meta.email {
            if let quota = files.clearQuotaCache() {
                stderr(text.line(.quotaFailed, quota.path, quota.detail))
            }
        }
        stdout(text.line(.saved, name, observed.meta.email))
        reportOtherAgy()
        refresher.startDetached()
        try launchAgy()
    }

    // 联网查询所有已保存账号的套餐和额度。只用保存的副本，不读钥匙串。
    // 切换之后由另一个进程执行这条指令，所以这里出什么问题都不影响切换。
    private func refreshQuota() throws {
        let started = DispatchTime.now()
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
            try storeLogin(name: try availableDefaultName(snapshot.meta.email), blob: snapshot.blob, meta: snapshot.meta)
        }
    }

    private func rename(from sourceName: String?, to targetName: String) throws {
        let target = try checkNewName(targetName)
        let source: String
        if let sourceName {
            source = try checkName(sourceName)
        } else {
            let active = profile.activeName()
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
        try profile.write(name: target, meta: meta, savedAt: savedAt)
        do {
            try files.renameSaved(from: source, to: target, meta: meta, savedAt: savedAt)
        } catch {
            try? profile.deleteRecord(target)
            throw error
        }
        try profile.deleteRecord(source)
        profile.moveUsage(from: source, to: target)
        if profileWasActive {
            try profile.setActive(target)
        }
        if filesWereActive {
            try files.setActive(target)
        }
        stdout(text.line(.renamed, source, target, meta.email))
    }

    private func current() throws {
        let name = profile.activeName()
        guard !name.isEmpty else {
            throw AccountFailure(.noCurrentAccount)
        }
        stdout(try profile.read(name).email)
    }

    // 只读 ~/.agy-cs/ 里的记录，不联网，不读钥匙串。list 和菜单栏面板都从这里取。
    func listing() throws -> [AccountRow] {
        let activeEmail = profileEmail(profile.activeName())
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
            stdout(text.line(.noSavedAccounts))
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
        let blob = try readKeychain()
        let meta = try decodeLogin(blob, source: .keychain)
        if !force || expecting != nil {
            let replaceable = force ? [expecting].compactMap { $0 } : []
            do {
                try checkHolder(of: checked, allowed: [meta.email] + replaceable)
            } catch let error as AccountFailure where error.key == .nameTaken {
                throw AccountFailure(.saveWouldReplace, checked, error.arguments.last ?? "")
            }
        }
        try files.writeSaved(name: checked, blob: blob, meta: meta)
        try profile.write(name: checked, meta: meta)
        try files.setActive(checked)
        try profile.setActive(checked)
        stdout(text.line(.saved, checked, meta.email))
    }

    private func switchTo(_ name: String) throws {
        let checked = try checkName(name)
        let target = try files.readSaved(checked)
        let currentBlob = try readKeychain()
        let current = try decodeLogin(currentBlob, source: .keychain)
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
        if profile.slots(forEmail: current.email).isEmpty {
            throw AccountFailure(.currentNotSaved, current.email)
        }
        let updated = try persistCurrentRefresh(blob: currentBlob, meta: current)
        try keychain.writeBlob(target.blob)
        if let quota = files.clearQuotaCache() {
            stderr(text.line(.quotaFailed, quota.path, quota.detail))
        }
        try files.setActive(checked)
        try profile.setActive(checked)
        stdout(text.line(.switched, checked, target.meta.email))
        if !updated.isEmpty {
            stdout(text.line(.refreshedBeforeSwitch, updated.joined(separator: ", ")))
        }
        reportOtherAgy()
        stdout(text.line(.reopenAgy))
        refresher.startDetached()
    }

    private func next() throws {
        let names = profile.names()
        guard names.count >= 2 else {
            throw AccountFailure(.needTwoAccounts)
        }
        let current = try decodeLogin(try readKeychain(), source: .keychain)
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
        let currentEmail = profileEmail(profile.activeName())
        if meta.email == currentEmail, !force {
            let others = profile.slots(forEmail: meta.email).filter { $0 != checked }
            if others.isEmpty {
                throw AccountFailure(.onlyCopy, checked, meta.email)
            }
        }
        if tokenExists {
            try files.removeSaved(checked)
        }
        try profile.remove(checked)
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

    private func launchAgy() throws {
        stdout(text.line(.startingAgy))
        try launcher.startInCurrentTerminal()
    }

    private func reportOtherAgy() {
        let pids = processes.runningAgyPIDs()
        if !pids.isEmpty {
            stdout(text.line(.agyStillRunning, pids.map(String.init).joined(separator: ", ")))
        }
    }

    private func captureLogin() throws -> ObservedLogin? {
        do {
            let blob = try readKeychain()
            return ObservedLogin(blob: blob, meta: try decodeLogin(blob, source: .keychain))
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
        guard let meta = try? decodeLogin(blob, source: .keychain) else {
            return nil
        }
        return ObservedLogin(blob: blob, meta: meta)
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
    }

    private func missingAccount(_ name: String) -> AccountFailure {
        let existing = profile.names()
        if existing.isEmpty {
            return AccountFailure(.accountMissingNone, name)
        }
        return AccountFailure(.accountMissing, name, existing.joined(separator: ", "))
    }

    private func readKeychain() throws -> String {
        let blob = try keychain.readBlob()
        _ = try decodeLogin(blob, source: .keychain)
        return blob
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
