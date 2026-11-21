import AgyAccount
import AgyMenuBar
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = launchMode(arguments: arguments, environment: ProcessInfo.processInfo.environment, parent: getppid())

if mode == .menuBar {
    // 标记只用来决定这一次怎么启动，不传给之后启动的进程。
    unsetenv(menuBarMarker)
    SwitcherApp.main()
} else {
    exit(AgyAccountCLI.run(arguments))
}
