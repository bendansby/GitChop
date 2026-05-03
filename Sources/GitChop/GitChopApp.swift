import SwiftUI
import AppKit
import Sparkle

@main
struct GitChopApp: App {
    @StateObject private var workspace = Workspace()

    init() {
        // System tab bar (the NSWindow auto-tabbing that adds Show/Hide
        // Tab Bar, Merge All Windows, etc. to the Window menu) doesn't
        // make sense for a single-window app whose multi-repo story is
        // its own in-window tab strip. Turn it off so users don't get
        // both — the system menu items disappear and ⌘⇧T no longer
        // tries to merge.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

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
        WindowGroup("GitChop", id: "main") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 900, minHeight: 600)
                .background(MainWindowAccessor())
        }
        .windowResizability(.contentMinSize)

        // Settings scene gets the standard ⌘, shortcut and "GitChop ›
        // Settings…" menu placement automatically.
        Settings {
            PreferencesView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                // Use a tiny subview so we can pick up @Environment's
                // openWindow — Command builders don't otherwise have it.
                // Without this, ⌘O / Open Repo… on an app with no
                // window open runs the file picker but has nowhere to
                // surface the resulting tab.
                OpenRepoMenuItem(workspace: workspace)
                Button("Close Repo") {
                    // ⌘W is bound globally for this command, so it
                    // fires regardless of which window has focus.
                    // When a secondary window (Preferences, etc.) is
                    // focused, route the close to it ourselves and
                    // bail; otherwise close the active tab. We compare
                    // against `MainWindowReference.shared.window`
                    // rather than `NSApp.mainWindow` because Settings
                    // windows on macOS 14+ become both the key AND
                    // main window when focused, defeating that check.
                    if let key = NSApp.keyWindow,
                       key !== MainWindowReference.shared.window {
                        key.performClose(nil)
                        return
                    }
                    workspace.requestCloseActive()
                }
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

/// "Open Repo…" menu item with ⌘O. Lives in its own subview so the
/// `@Environment(\.openWindow)` value is accessible — the App scene's
/// command builders can't read environment values directly. If no
/// document window currently exists (the user closed it but left the
/// app running), open one before showing the picker, otherwise the
/// picker would run with no window to surface the resulting tab in.
private struct OpenRepoMenuItem: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Repo…") {
            // If a window is already up, reuse the workspace's existing
            // openPicker — picker, then add the new tab to that window.
            if MainWindowReference.shared.window?.isVisible == true {
                workspace.openPicker()
                return
            }
            // Otherwise run the picker first, ourselves, so the user
            // can cancel without leaving an empty window behind. Only
            // on success do we open the window + add the session.
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            panel.message = "Pick a git repository."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            openWindow(id: "main")
            workspace.openRepo(url)
        }
        .keyboardShortcut("o", modifiers: .command)
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
