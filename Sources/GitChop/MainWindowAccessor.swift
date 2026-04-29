import SwiftUI
import AppKit

/// Captures a weak reference to the GitChop document window so the
/// ⌘W menu handler can compare against it. NSApp.mainWindow is
/// unreliable for this on macOS 14+ — the Settings window can be
/// both the key AND main window when focused, which would otherwise
/// fool a `keyWindow !== mainWindow` check into closing a background
/// tab.
final class MainWindowReference {
    static let shared = MainWindowReference()
    weak var window: NSWindow?
    private init() {}
}

/// Drop into the ContentView's background to record the hosting
/// NSWindow into `MainWindowReference.shared.window`.
struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view's `.window` is nil until it's added to the hierarchy,
        // so defer the capture until the next runloop pass.
        DispatchQueue.main.async {
            MainWindowReference.shared.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-capture on update — protects against the window pointer
        // changing across SwiftUI scene rebuilds (rare, but harmless).
        if MainWindowReference.shared.window == nil {
            MainWindowReference.shared.window = nsView.window
        }
    }
}
