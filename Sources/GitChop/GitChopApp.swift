import SwiftUI

@main
struct GitChopApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("GitChop") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Repo…") { workspace.openPicker() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close Tab") { workspace.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(workspace.activeSessionID == nil)
            }
        }
    }
}
