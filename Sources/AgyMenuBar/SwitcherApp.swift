import AgyAccount
import AppKit
import SwiftUI

public enum SwitcherApp {
    // 从 main.swift 的主线程调用，不返回。
    public static func main() {
        // 已经有一个在运行（比如另一个文件夹里的那一份）就直接退出。
        guard AccountBoard().lockApp() != nil else {
            exit(0)
        }
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
        model.onKeepsOpenChanged = { [weak self] keep in
            self?.popover.behavior = keep ? .applicationDefined : .transient
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeStatusIcon()
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
    }

    // 叠放的双账号卡片与双向切换箭头：与 App 图标同源的 18×18 菜单栏模板图标。
    static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let frontRect = NSRect(x: 4.75, y: 2.25, width: 11.5, height: 9.5)
            let backRect = NSRect(x: 1.75, y: 6.25, width: 11.5, height: 9.5)

            // 沿前卡外扩一圈挖空裁剪，让叠放处的后卡边框留出干净间隙。
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: rect)
            clip.append(NSBezierPath(roundedRect: frontRect.insetBy(dx: -1.1, dy: -1.1), xRadius: 3.1, yRadius: 3.1))
            clip.windingRule = .evenOdd
            clip.addClip()
            let back = NSBezierPath(roundedRect: backRect, xRadius: 2.2, yRadius: 2.2)
            back.lineWidth = 1.4
            back.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let front = NSBezierPath(roundedRect: frontRect, xRadius: 2.2, yRadius: 2.2)
            front.lineWidth = 1.4
            front.stroke()

            let arrows = NSBezierPath()
            arrows.lineWidth = 1.2
            arrows.lineCapStyle = .round
            arrows.lineJoinStyle = .round
            arrows.move(to: NSPoint(x: 7.5, y: 8.55))
            arrows.line(to: NSPoint(x: 13.3, y: 8.55))
            arrows.move(to: NSPoint(x: 12.0, y: 9.7))
            arrows.line(to: NSPoint(x: 13.3, y: 8.55))
            arrows.line(to: NSPoint(x: 12.0, y: 7.4))
            arrows.move(to: NSPoint(x: 13.5, y: 5.45))
            arrows.line(to: NSPoint(x: 7.7, y: 5.45))
            arrows.move(to: NSPoint(x: 9.0, y: 6.6))
            arrows.line(to: NSPoint(x: 7.7, y: 5.45))
            arrows.line(to: NSPoint(x: 9.0, y: 4.3))
            arrows.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agy Switcher"
        return image
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
