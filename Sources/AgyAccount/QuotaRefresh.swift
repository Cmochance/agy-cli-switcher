import Darwin
import Foundation

protocol QuotaRefreshStarting {
    func startDetached()
    func spawnWorker()
}

// 切换完成后另起一个进程去查额度。切换不等查询结束，也不受它的结果影响。
// startDetached 启动一个只负责转手的进程并等它退出；真正查询的进程由它启动，
// 自成一个会话，标准输入输出都接到 /dev/null，不再有父进程。
// 这样菜单里随后换成 agy 的那个进程下面不会留下僵尸进程。
struct SelfSpawner: QuotaRefreshStarting {
    var executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var prefix: [String] = []

    func startDetached() {
        guard let pid = spawn(prefix + ["refresh", "quota", "--detach"], ownSession: false) else {
            return
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    func spawnWorker() {
        _ = spawn(prefix + ["refresh", "quota"], ownSession: true)
    }

    private func spawn(_ arguments: [String], ownSession: Bool) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
        }
        if ownSession {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        }
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let started = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress, environ)
        }
        return started == 0 ? pid : nil
    }
}
