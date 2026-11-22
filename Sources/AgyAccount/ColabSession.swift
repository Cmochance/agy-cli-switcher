import Darwin
import Foundation

// Colab CLI 没有单独的登录指令：移除钥匙串后在前台终端跑 `colab whoami`，
// 会自动走完远程授权码登录并写入钥匙串，随后自动退出。
struct InteractiveColab: AgyLaunching {
    var cacheURL: URL = ToolLocations(home: FileManager.default.homeDirectoryForCurrentUser, provider: .colab).clientFile
    var locate: ((URL) -> ColabInstallation?)? = nil
    var launchesAfterSwitch: Bool { false }

    func runUntilLoggedIn(_ poll: () throws -> ObservedLogin?) throws -> LoginWatchResult {
        let binary = try colabExecutable()
        let pid = try spawnWhoami(binary)
        let tty = STDIN_FILENO
        let ownGroup = getpgrp()
        let interactive = isatty(tty) != 0
        if interactive {
            let owned = ownsForeground(foreground: tcgetpgrp(tty), own: ownGroup)
            guard owned, tcsetpgrp(tty, pid) == 0 else {
                let detail = String(owned ? errno : ENOTTY)
                terminate(pid)
                throw AccountFailure(.colabLaunchFailed, detail)
            }
            _ = kill(pid, SIGCONT)
        }
        let savedStops = ignoreTerminalStopSignalsForColab()
        defer { restoreTerminalStopSignalsForColab(savedStops) }
        defer {
            if interactive {
                _ = tcsetpgrp(tty, ownGroup)
            }
        }
        while true {
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

    func startInCurrentTerminal() throws {}

    private func colabExecutable() throws -> String {
        let installed = locate?(cacheURL) ?? resolveColabInstallation(cacheURL: cacheURL)
        guard let installed else {
            throw AccountFailure(.colabLaunchFailed, "colab")
        }
        return installed.colabPath
    }

    private func spawnWhoami(_ binary: String) throws -> pid_t {
        let command = strdup(binary)
        let arg = strdup("whoami")
        defer {
            free(command)
            free(arg)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [command, arg, nil]
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AccountFailure(.colabLaunchFailed, binary)
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, binary, nil, &attributes, buffer.baseAddress, environ)
        }
        guard spawned == 0 else {
            throw AccountFailure(.colabLaunchFailed, String(spawned))
        }
        return pid
    }

    private func terminate(_ pid: pid_t) {
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

private struct ColabTerminalStopDisposition {
    var output: sigaction
    var input: sigaction
}

private func ignoreTerminalStopSignalsForColab() -> ColabTerminalStopDisposition {
    var ignore = sigaction()
    ignore.__sigaction_u.__sa_handler = SIG_IGN
    sigemptyset(&ignore.sa_mask)
    ignore.sa_flags = 0
    var output = sigaction()
    var input = sigaction()
    _ = sigaction(SIGTTOU, &ignore, &output)
    _ = sigaction(SIGTTIN, &ignore, &input)
    return ColabTerminalStopDisposition(output: output, input: input)
}

private func restoreTerminalStopSignalsForColab(_ saved: ColabTerminalStopDisposition) {
    var output = saved.output
    var input = saved.input
    _ = sigaction(SIGTTOU, &output, nil)
    _ = sigaction(SIGTTIN, &input, nil)
}
