import Darwin
import Foundation

struct ObservedLogin {
    var blob: String
    var meta: LoginMeta
}

enum LoginWatchResult {
    case loggedIn(ObservedLogin)
    case exited
}

protocol LineReading {
    var isInteractive: Bool { get }
    func readLine() -> String?
}

protocol AgyLaunching {
    func runUntilLoggedIn(_ poll: () throws -> ObservedLogin?) throws -> LoginWatchResult
    func startInCurrentTerminal() throws
}

struct StandardTerminal: LineReading {
    var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
            && ownsForeground(foreground: tcgetpgrp(STDIN_FILENO), own: getpgrp())
    }

    func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }
}

struct InteractiveAgy: AgyLaunching {
    func runUntilLoggedIn(_ poll: () throws -> ObservedLogin?) throws -> LoginWatchResult {
        let binary = try agyExecutable()
        let pid = try spawn(binary)
        let tty = STDIN_FILENO
        let ownGroup = getpgrp()
        let interactive = isatty(tty) != 0
        if interactive {
            // 交出前台时不忽略 SIGTTOU：本进程在后台的话，这里会被停住，而不是把终端从 shell 手里拿走。
            let owned = ownsForeground(foreground: tcgetpgrp(tty), own: ownGroup)
            guard owned, tcsetpgrp(tty, pid) == 0 else {
                let detail = String(owned ? errno : ENOTTY)
                terminate(pid)
                throw AccountFailure(.agyLaunchFailed, detail)
            }
            _ = kill(pid, SIGCONT)
        }
        // 前台交给 agy 后，本进程再 tcsetpgrp 会收到 SIGTTOU，shell 显示 suspended (tty output)。
        // 忽略期间才能把终端收回来。defer 反序执行：先交还前台，再恢复原来的信号处理。
        let savedStops = ignoreTerminalStopSignals()
        defer { restoreTerminalStopSignals(savedStops) }
        defer {
            if interactive {
                _ = tcsetpgrp(tty, ownGroup)
            }
        }
        while true {
            let observed: ObservedLogin?
            do {
                observed = try poll()
            } catch {
                terminate(pid)
                throw error
            }
            if let observed {
                terminate(pid)
                return .loggedIn(observed)
            }
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG | WUNTRACED)
            let waitError = errno
            switch nextStep(after: classifyWait(waited: waited, pid: pid, status: status, callErrno: waitError)) {
            case .keepWaiting:
                break
            case .cancel:
                terminate(pid)
                return .exited
            case .resume:
                _ = kill(-pid, SIGCONT)
            case .finished:
                if let observed = try poll() {
                    return .loggedIn(observed)
                }
                return .exited
            }
            usleep(200_000)
        }
    }

    func startInCurrentTerminal() throws {
        let shell = interactiveShell()
        let arguments = [shell, "-ic", "agy"]
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = pointers.map { $0 }
        argv.append(nil)
        _ = argv.withUnsafeMutableBufferPointer { buffer in
            execv(shell, buffer.baseAddress)
        }
        throw AccountFailure(.agyLaunchFailed, String(errno))
    }

    private func spawn(_ binary: String) throws -> pid_t {
        let command = strdup(binary)
        defer { free(command) }
        var argv: [UnsafeMutablePointer<CChar>?] = [command, nil]
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AccountFailure(.agyLaunchFailed, binary)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGTTOU)
        sigaddset(&defaults, SIGTTIN)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&attributes, flags)
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, binary, nil, &attributes, buffer.baseAddress, environ)
        }
        guard spawned == 0 else {
            throw AccountFailure(.agyLaunchFailed, String(spawned))
        }
        return pid
    }

    private func terminate(_ pid: pid_t) {
        // 停住的子进程要先继续，SIGTERM 才会被处理。
        _ = kill(-pid, SIGCONT)
        _ = kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited == -1 && errno != EINTR) {
                return
            }
            usleep(50_000)
        }
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}

enum ChildWait: Equatable {
    case running
    case stopped(Int32)
    case finished
}

func classifyWait(waited: pid_t, pid: pid_t, status: Int32, callErrno: Int32) -> ChildWait {
    if waited == 0 || (waited == -1 && callErrno == EINTR) {
        return .running
    }
    guard waited == pid else {
        return .finished
    }
    let signal = (status >> 8) & 0xff
    if (status & 0x7f) == 0x7f {
        return signal == SIGCONT ? .running : .stopped(signal)
    }
    return .finished
}

enum WaitStep: Equatable {
    case keepWaiting
    case resume
    case cancel
    case finished
}

func nextStep(after wait: ChildWait) -> WaitStep {
    switch wait {
    case .running:
        return .keepWaiting
    case .stopped(let signal):
        return signal == SIGTSTP ? .cancel : .resume
    case .finished:
        return .finished
    }
}

func ownsForeground(foreground: pid_t, own: pid_t) -> Bool {
    foreground != -1 && foreground == own
}

private struct TerminalStopDisposition {
    var output: sigaction
    var input: sigaction
}

private func ignoreTerminalStopSignals() -> TerminalStopDisposition {
    var ignore = sigaction()
    ignore.__sigaction_u.__sa_handler = SIG_IGN
    sigemptyset(&ignore.sa_mask)
    ignore.sa_flags = 0
    var output = sigaction()
    var input = sigaction()
    _ = sigaction(SIGTTOU, &ignore, &output)
    _ = sigaction(SIGTTIN, &ignore, &input)
    return TerminalStopDisposition(output: output, input: input)
}

private func restoreTerminalStopSignals(_ saved: TerminalStopDisposition) {
    var output = saved.output
    var input = saved.input
    _ = sigaction(SIGTTOU, &output, nil)
    _ = sigaction(SIGTTIN, &input, nil)
}

func agyExecutable() throws -> String {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    guard let found = agyCandidates(in: path).first(where: FileManager.default.isExecutableFile(atPath:)) else {
        throw AccountFailure(.agyLaunchFailed, "agy")
    }
    return found
}

// 只用来读 client secret 和版本号的 agy。被系统打开的菜单栏进程，PATH 只有
// /usr/bin:/bin:/usr/sbin:/sbin（实测），所以 PATH 里没有时，再看上次记下的位置和几个常见的安装目录。
// 启动 agy 让用户登录的那一步不走这里，仍然只认 PATH。
func agyBinary(
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
    recorded: String?,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> String? {
    let usual = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
    let remembered = [recorded].compactMap { $0 }.filter { $0.hasPrefix("/") }
    let candidates = agyCandidates(in: path) + remembered + usual.map { $0 + "/agy" }
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
}

private func agyCandidates(in path: String) -> [String] {
    path.split(separator: ":").filter { !$0.isEmpty }.map { directory in
        URL(fileURLWithPath: String(directory)).appendingPathComponent("agy").path
    }
}

private func interactiveShell() -> String {
    if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
        return shell
    }
    return "/bin/zsh"
}
