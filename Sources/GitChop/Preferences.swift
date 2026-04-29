import Foundation
import AppKit
import Combine

/// Defaults keys, hoisted to file scope so the nonisolated static
/// `resolvedGitPath()` can read UserDefaults without crossing the
/// @MainActor boundary on Preferences.
fileprivate enum PreferencesKeys {
    static let defaultDepth        = "GitChop.defaultDepth"
    static let customGitPath       = "GitChop.customGitPath"
    static let editorMode          = "GitChop.editorMode"
    static let editorAppPath       = "GitChop.editorAppPath"
    static let editorShellCommand  = "GitChop.editorShellCommand"
}

/// User-configurable settings, persisted to UserDefaults. Singleton
/// because the values are read from many places (GitRunner, ConflictSheet,
/// RebaseSession.load) and there's no per-window or per-tab variant.
///
/// All keys are namespaced "GitChop.…" so they don't collide with
/// SwiftUI's own scene/window state defaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // ── Default load depth ────────────────────────────────────────
    /// How many commits to load when a session opens a repo for the
    /// first time. The depth-menu (12 / 25 / 50 / 100 / All) overrides
    /// per-session, but this is the cold-start value.
    @Published var defaultDepth: Int {
        didSet { defaults.set(defaultDepth, forKey: PreferencesKeys.defaultDepth) }
    }

    // ── Custom git path ───────────────────────────────────────────
    /// Absolute path to the `git` binary. Empty string means "use the
    /// first `git` on $PATH" (resolved via /usr/bin/env at run time).
    @Published var customGitPath: String {
        didSet { defaults.set(customGitPath, forKey: PreferencesKeys.customGitPath) }
    }

    // ── External editor for conflict resolution ───────────────────
    /// How "Open" in the conflict sheet should launch a file.
    enum EditorMode: String, CaseIterable, Identifiable {
        /// `NSWorkspace.shared.open(url)` — whatever macOS uses for the
        /// file's UTI. Default; works without setup.
        case systemDefault = "system"
        /// Open in a specific .app bundle (path stored in `editorAppPath`).
        case specificApp = "app"
        /// Run a shell command, with `$FILE` (and the bare path as `$1`)
        /// substituted to the absolute file path. Useful for editors with
        /// CLI launchers like `code --wait $FILE` or `cursor $FILE`.
        case shellCommand = "command"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .systemDefault: return "macOS default"
            case .specificApp:   return "Specific app…"
            case .shellCommand:  return "Shell command"
            }
        }
    }

    @Published var editorMode: EditorMode {
        didSet { defaults.set(editorMode.rawValue, forKey: PreferencesKeys.editorMode) }
    }
    @Published var editorAppPath: String {
        didSet { defaults.set(editorAppPath, forKey: PreferencesKeys.editorAppPath) }
    }
    @Published var editorShellCommand: String {
        didSet { defaults.set(editorShellCommand, forKey: PreferencesKeys.editorShellCommand) }
    }

    // MARK: - Init

    private init() {
        defaultDepth      = (defaults.object(forKey: PreferencesKeys.defaultDepth) as? Int) ?? 12
        customGitPath     = defaults.string(forKey: PreferencesKeys.customGitPath) ?? ""
        editorAppPath     = defaults.string(forKey: PreferencesKeys.editorAppPath) ?? ""
        editorShellCommand = defaults.string(forKey: PreferencesKeys.editorShellCommand) ?? ""

        if let raw = defaults.string(forKey: PreferencesKeys.editorMode),
           let parsed = EditorMode(rawValue: raw) {
            editorMode = parsed
        } else {
            editorMode = .systemDefault
        }
    }

    // MARK: - Resolved values (used by callers)

    /// Path to use when launching `git`. Returns the user's custom
    /// path if set and the file exists; otherwise the first `git` on
    /// $PATH; otherwise `/usr/bin/git` as a last resort.
    /// Static + nonisolated so GitRunner can call it from background
    /// tasks without main-actor hopping.
    nonisolated static func resolvedGitPath() -> String {
        let trimmed = (UserDefaults.standard.string(forKey: PreferencesKeys.customGitPath) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        // Find on $PATH via env. Cheap, runs once per git invocation.
        let env = Process()
        env.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        env.arguments = ["which", "git"]
        let pipe = Pipe()
        env.standardOutput = pipe
        env.standardError = Pipe()
        do {
            try env.run()
            env.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // Fall through to default.
        }
        return "/usr/bin/git"
    }

    /// Open a file using the configured editor.
    func openFileForEditing(_ url: URL) {
        switch editorMode {
        case .systemDefault:
            NSWorkspace.shared.open(url)

        case .specificApp:
            let appPath = editorAppPath.trimmingCharacters(in: .whitespaces)
            guard !appPath.isEmpty else {
                NSWorkspace.shared.open(url)
                return
            }
            let appURL = URL(fileURLWithPath: appPath)
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }

        case .shellCommand:
            let cmd = editorShellCommand.trimmingCharacters(in: .whitespaces)
            guard !cmd.isEmpty else {
                NSWorkspace.shared.open(url)
                return
            }
            // $FILE token + positional $1 both point at the absolute
            // path. Quoting the path so spaces survive.
            let quotedPath = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let expanded = cmd.replacingOccurrences(of: "$FILE", with: quotedPath)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "\(expanded) \(quotedPath)"]
            try? process.run()
        }
    }

}
