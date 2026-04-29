import SwiftUI
import Sparkle

@main
struct GitChopApp: App {
    @StateObject private var workspace = Workspace()

    /// Standard Sparkle controller. Wires up automatic background checks
    /// (interval + enable flag come from Info.plist's
    /// SUEnableAutomaticChecks / SUScheduledCheckInterval), surfaces the
    /// "Check for Updates…" menu item via the `CheckForUpdatesView` below,
    /// and downloads + applies stapled DMGs from the appcast.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
            // Add "Check for Updates…" under the GitChop app menu, just
            // above the standard Services / Hide / Quit cluster.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

/// Tiny SwiftUI view that drives a "Check for Updates…" menu item.
/// Disables itself when Sparkle says a check isn't currently allowed
/// (e.g. one is already in flight). Pattern lifted straight from
/// Sparkle's documentation example for SwiftUI apps.
private struct CheckForUpdatesView: View {
    @ObservedObject private var checker: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checker.canCheckForUpdates)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
