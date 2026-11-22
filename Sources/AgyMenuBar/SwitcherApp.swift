import AppKit
import SwiftUI

public enum SwitcherApp {
    // 从 main.swift 的主线程调用，不返回。
    public static func main() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let controller = MenuBarController()
            application.delegate = controller
            application.setActivationPolicy(.accessory)
            withExtendedLifetime(controller) {
                application.run()
            }
        }
    }
}

// 菜单栏上的图标和点开的面板。面板用 NSPopover，大小由 NSHostingController 按内容报给它：
// 内容变高、变矮，或者关着的时候变，面板都跟着变（实测）。原来用 SwiftUI 的 MenuBarExtra 窗口样式，
// 显示过几行提示之后窗口不再变矮，内容上下各空出一条（实测窗口 358 高，内容约 281 高，多出来的正好是三行提示）。
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let popover: NSPopover
    let model: PanelModel
    private(set) var item: NSStatusItem?

    // make 拿到“面板现在是不是开着”，交给 PanelModel。
    init(model make: @MainActor (@escaping @MainActor () -> Bool) -> PanelModel = { PanelModel(shown: $0) }) {
        let popover = NSPopover()
        self.popover = popover
        model = make { popover.isShown }
        super.init()
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Agy Switcher")
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
    }

    @objc private func clicked(_ sender: Any?) {
        if let event = NSApp.currentEvent, Self.opensMenu(event.type, modifiers: event.modifierFlags) {
            showMenu()
        } else {
            toggle(sender)
        }
    }

    // 右键和按住 control 的左键打开菜单，其余的点击开关面板。
    static func opensMenu(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || (type == .leftMouseUp && modifiers.contains(.control))
    }

    // 图标的右键菜单，只有退出。面板点不开的时候也能从这里退出。
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: model.text(.panelQuit), action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func quit(_ sender: Any?) {
        model.quit()
    }

    // 菜单只在这一次点击里挂在图标上，弹完就摘掉，不然左键也会变成打开菜单。
    private func showMenu() {
        guard let item else {
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        }
        item.menu = makeMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func toggle(_ sender: Any?) {
        guard let button = item?.button else {
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // 先把本程序切到前面，面板里的输入框才能打字。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverWillShow(_ notification: Notification) {
        model.panelOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelClosed()
    }
}
