import SwiftUI

/// Top-level layout. Reads the workspace, renders the tab strip, and
/// pipes the active session into the inner views so they don't have
/// to know about multi-tab state.
struct ContentView: View {
    @EnvironmentObject var workspace: Workspace
    @State private var showOutcome = false

    var body: some View {
        VStack(spacing: 0) {
            TabStripView()
            if let session = workspace.activeSession {
                tabContent(for: session)
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    workspace.openPicker()
                } label: {
                    Label("Open Repo…", systemImage: "folder")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                applyButton
            }
        }
        .alert(
            "Rebase result",
            isPresented: $showOutcome,
            presenting: workspace.activeSession?.lastOutcome
        ) { _ in
            Button("OK") { }
        } message: { outcome in
            Text(outcome.kind == .success
                 ? "Applied. Backup ref: \(outcome.backupRef)\n\n\(outcome.log)"
                 : "Failed and rolled back from backup ref \(outcome.backupRef).\n\n\(outcome.log)")
        }
    }

    /// The main split + status bar, parameterized on the active session.
    /// We re-inject the session as an EnvironmentObject so the inner
    /// views (CommitListView, DiffPaneView) can keep reading it directly
    /// without taking an explicit parameter.
    @ViewBuilder
    private func tabContent(for session: RebaseSession) -> some View {
        VStack(spacing: 0) {
            HSplitView {
                CommitListView()
                    .frame(minWidth: 380, idealWidth: 480)
                DiffPaneView()
                    .frame(minWidth: 360, idealWidth: 600)
            }
            Divider()
            statusBar(session: session)
        }
        .environmentObject(session)
        // Tag with session.id so SwiftUI rebuilds the subtree when the
        // active tab changes, instead of re-using the same view tree
        // and confusing onAppear/state.
        .id(session.id)
    }

    /// Shown when zero tabs are open — friendly call to action rather
    /// than an empty void.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "scissors")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No repos open")
                .font(.title3)
            Text("Open a git repo to start chopping commits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Repo…") { workspace.openPicker() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    /// Apply Rebase button. Three visible states:
    ///
    ///   • no changes pending → outline seal, secondary color, disabled,
    ///     tooltip explains the gate. Looks visibly off.
    ///   • changes pending    → filled seal, accent color, enabled,
    ///     enter (⌘↩) shortcut. Looks visibly armed.
    ///   • applying           → progress spinner, disabled.
    ///
    /// The icon swap (`seal` ↔ `seal.fill`) plus the color shift makes
    /// "ready / not ready" readable at a glance — the bare `.disabled`
    /// dim was too subtle, especially in the toolbar's bordered chrome.
    private var applyButton: some View {
        let session = workspace.activeSession
        let hasChanges = session?.hasChanges ?? false
        let isApplying = session?.isApplying ?? false
        let canApply = hasChanges && !isApplying

        return Button {
            guard let session = session else { return }
            Task {
                await session.apply()
                if session.lastOutcome != nil { showOutcome = true }
            }
        } label: {
            if isApplying {
                Label {
                    Text("Applying…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
            } else {
                Label(
                    "Apply Rebase",
                    systemImage: hasChanges ? "checkmark.seal.fill" : "checkmark.seal"
                )
                .foregroundStyle(hasChanges ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .disabled(!canApply)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(canApply
              ? "Apply rebase (⌘↩)"
              : (session == nil
                 ? "Open a repo first"
                 : "Reorder a commit or change a verb to enable"))
    }

    private func statusBar(session: RebaseSession) -> some View {
        HStack {
            if session.isApplying {
                ProgressView().controlSize(.small)
                Text("Applying rebase…")
            } else {
                Text(session.status)
            }
            Spacer()
            if !session.baseHash.isEmpty {
                Text("Base: \(String(session.baseHash.prefix(7)))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }
}
