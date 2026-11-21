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
        let handedOff = isatty(tty) != 0 && tcsetpgrp(tty, pid) == 0
        defer {
            if handedOff {
                _ = tcsetpgrp(tty, ownGroup)
            }
        }
        while true {
            if let observed = try poll() {
                terminate(pid)
                return .loggedIn(observed)
            }
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                if let observed = try poll() {
                    return .loggedIn(observed)
                }
                return .exited
            }
            if waited == -1 && errno != EINTR {
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

func agyExecutable() throws -> String {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":") where !directory.isEmpty {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("agy").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    throw AccountFailure(.agyLaunchFailed, "agy")
}

private func interactiveShell() -> String {
    if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
        return shell
    }
    return "/bin/zsh"
}
