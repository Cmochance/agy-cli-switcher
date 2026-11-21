import SwiftUI

public struct SwitcherApp: App {
    @StateObject private var model = PanelModel()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: "person.2.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
