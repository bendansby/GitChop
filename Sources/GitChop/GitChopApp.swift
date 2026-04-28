import SwiftUI

@main
struct GitChopApp: App {
    @StateObject private var session = RebaseSession()

    var body: some Scene {
        WindowGroup("GitChop") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Rebase tools don't have "documents", so the standard
            // File > New / File > Open scaffold is more confusing than
            // useful. Replace with our own Open Repo command.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Repo…") { session.openPicker() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
