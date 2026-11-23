import AgyAccount
import Foundation

protocol PanelLoginChannel: AnyObject {
    func send(_ line: String)
    func stop()
}

protocol PanelLoginRunning {
    func launch(
        executable: String,
        arguments: [String],
        onLine: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor () -> Void
    ) -> any PanelLoginChannel
}

// 面板没有终端。Colab 登录交给同一个可执行文件在后台做，授权码只从管道写进去。
final class ProcessPanelLogin: PanelLoginRunning {
    func launch(
        executable: String,
        arguments: [String],
        onLine: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor () -> Void
    ) -> any PanelLoginChannel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: menuBarMarker)
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let channel = ProcessLoginChannel(process: process, input: input)
        let outputBuffer = LineBuffer()
        let errorBuffer = LineBuffer()
        let finished = FinishedGate()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finished.leave {
                    DispatchQueue.main.async(execute: onExit)
                }
                return
            }
            let lines = outputBuffer.append(data)
            DispatchQueue.main.async {
                lines.forEach(onLine)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finished.leave {
                    DispatchQueue.main.async(execute: onExit)
                }
                return
            }
            let lines = errorBuffer.append(data)
            DispatchQueue.main.async {
                lines.forEach(onError)
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                onLine("\(colabLoginLinePrefix) error \(TextKey.colabBrowserFailed.rawValue)")
                onExit()
            }
        }
        return channel
    }
}

private final class FinishedGate {
    private let lock = NSLock()
    private var remaining = 2
    private var fired = false

    func leave(_ body: () -> Void) {
        lock.lock()
        remaining -= 1
        let done = remaining == 0 && !fired
        if done {
            fired = true
        }
        lock.unlock()
        if done {
            body()
        }
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(of: 10) {
            var chunk = Data(pending.prefix(upTo: index))
            pending.removeSubrange(..<pending.index(after: index))
            if chunk.last == 13 {
                chunk.removeLast()
            }
            lines.append(String(data: chunk, encoding: .utf8) ?? "")
        }
        return lines
    }
}

private final class ProcessLoginChannel: PanelLoginChannel {
    let process: Process
    let input: Pipe

    init(process: Process, input: Pipe) {
        self.process = process
        self.input = input
    }

    func send(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else {
            return
        }
        input.fileHandleForWriting.write(data)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }
}
