import SwiftUI
import AppKit

/// Preferences window. Wired into the app via `Settings { ... }`
/// on the main scene, which gives us the standard ⌘, shortcut and
/// menu placement automatically.
struct PreferencesView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var resolvedGitPath: String = ""

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            git
                .tabItem { Label("Git", systemImage: "terminal") }
            editor
                .tabItem { Label("Editor", systemImage: "pencil") }
        }
        .frame(width: 460, height: 320)
        .onAppear { resolvedGitPath = Preferences.resolvedGitPath() }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Picker("Default depth", selection: $prefs.defaultDepth) {
                    Text("12 commits").tag(12)
                    Text("25 commits").tag(25)
                    Text("50 commits").tag(50)
                    Text("100 commits").tag(100)
                    Text("All").tag(Int.max)
                }
                .pickerStyle(.menu)
                Text("How many commits to load when a repo opens for the first time. Use the count menu in the list header to override per-repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    // MARK: - Git

    private var git: some View {
        Form {
            Section {
                LabeledContent("Path to git") {
                    HStack(spacing: 8) {
                        TextField("", text: $prefs.customGitPath, prompt: Text("Use $PATH (default)"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button("Browse…") { browseForGit() }
                            .controlSize(.regular)
                    }
                }
                Text(currentlyResolvedHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Leave blank to use the first `git` on your shell's $PATH (typically Apple's command-line tools or Homebrew). Set an absolute path to force a specific binary — useful for asdf, MacPorts, or custom builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onChange(of: prefs.customGitPath) {
            resolvedGitPath = Preferences.resolvedGitPath()
        }
    }

    private var currentlyResolvedHint: String {
        "Currently resolves to: \(resolvedGitPath)"
    }

    private func browseForGit() {
        let panel = NSOpenPanel()
        panel.message = "Choose a git binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            prefs.customGitPath = url.path
        }
    }

    // MARK: - Editor

    private var editor: some View {
        Form {
            Section {
                Picker("Open conflicted files in", selection: $prefs.editorMode) {
                    ForEach(Preferences.EditorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                switch prefs.editorMode {
                case .systemDefault:
                    Text("Uses the macOS default app for each file's type — same behavior as `open path/to/file` from the command line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .specificApp:
                    LabeledContent("Path to .app") {
                        HStack(spacing: 8) {
                            TextField("", text: $prefs.editorAppPath, prompt: Text("/Applications/Visual Studio Code.app"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button("Browse…") { browseForApp() }
                                .controlSize(.regular)
                        }
                    }
                    Text("Every conflicted file opens in the chosen app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .shellCommand:
                    LabeledContent("Command") {
                        TextField(
                            "",
                            text: $prefs.editorShellCommand,
                            prompt: Text("code --wait $FILE")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    }
                    Text("Run as a shell command per file. Use `$FILE` (or just rely on `$1`) to substitute the absolute path. Examples: `code --wait $FILE`, `cursor $FILE`, `subl --wait $FILE`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.message = "Choose an editor app"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url {
            prefs.editorAppPath = url.path
        }
    }
}
