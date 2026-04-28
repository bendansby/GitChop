import SwiftUI

/// Apply Rebase toolbar button. Lives in its own struct so it can
/// `@ObservedObject` the active session — the parent `ContentView`
/// only observes `Workspace`, which doesn't republish when a
/// session's @Published properties change. Without this dedicated
/// observer the button's enabled/disabled state would lag behind
/// the user's actual edits to the plan.
///
/// Three visible states:
///   • no changes pending → outline seal, secondary color, disabled
///   • changes pending    → filled seal, tint color, ⌘↩ live
///   • applying           → progress spinner, disabled
///
/// Clicking the armed button does NOT run the rebase directly — it
/// opens the confirmation sheet first. Apply rewrites real history,
/// so even with the auto-backup ref a deliberate confirmation step
/// is the right default.
private struct ApplyButton: View {
    @ObservedObject var session: RebaseSession
    @Binding var showConfirm: Bool

    /// Wrapper init so we can pass an Optional<RebaseSession> from the
    /// parent without forcing the parent to unwrap. We synthesize a
    /// throwaway placeholder when there's no active session — the
    /// button just renders its disabled state and never triggers.
    init(session: RebaseSession?, showConfirm: Binding<Bool>) {
        self.session = session ?? RebaseSession()
        self._showConfirm = showConfirm
        self.hasActiveSession = session != nil
    }

    private let hasActiveSession: Bool

    var body: some View {
        let hasChanges = hasActiveSession && session.hasChanges
        let isApplying = hasActiveSession && session.isApplying
        let canApply   = hasChanges && !isApplying

        Button {
            guard hasActiveSession, canApply else { return }
            showConfirm = true
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
              : (!hasActiveSession
                 ? "Open a repo first"
                 : "Reorder a commit or change a verb to enable"))
    }
}

/// Hosts the split-commit sheet for the active session. Lives in its
/// own view so it can `@ObservedObject` the session — `ContentView`
/// only observes `Workspace`, which doesn't republish when a session's
/// `@Published splitSheetCommitID` changes. Without this dedicated
/// observer the sheet binding's getter never re-evaluates and the
/// sheet never appears when the user picks `edit` or "Configure split…".
private struct SplitSheetHost: ViewModifier {
    @ObservedObject var session: RebaseSession

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { session.splitSheetCommitID != nil },
                set: { if !$0 { session.splitSheetCommitID = nil } }
            )
        ) {
            if let id = session.splitSheetCommitID {
                SplitCommitSheet(
                    session: session,
                    planItemID: id,
                    onSave: { plan in
                        session.setEditPlan(of: id, to: plan)
                        session.splitSheetCommitID = nil
                    },
                    onCancel: {
                        session.splitSheetCommitID = nil
                    }
                )
            }
        }
    }
}

/// Top-level layout. Reads the workspace, renders the tab strip, and
/// pipes the active session into the inner views so they don't have
/// to know about multi-tab state.
struct ContentView: View {
    @EnvironmentObject var workspace: Workspace
    @State private var showConfirm = false
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
                ApplyButton(
                    session: workspace.activeSession,
                    showConfirm: $showConfirm
                )
            }
        }
        .sheet(isPresented: $showConfirm) {
            if let session = workspace.activeSession {
                RebaseConfirmSheet(
                    session: session,
                    onApply: {
                        showConfirm = false
                        // Tiny delay so the confirm sheet's dismissal
                        // animation doesn't race the result sheet's
                        // presentation animation — without this the
                        // result sheet sometimes never appears.
                        Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            await session.apply()
                            if session.lastOutcome != nil { showOutcome = true }
                        }
                    },
                    onCancel: { showConfirm = false }
                )
            }
        }
        .sheet(isPresented: $showOutcome) {
            if let outcome = workspace.activeSession?.lastOutcome {
                RebaseResultSheet(outcome: outcome) {
                    showOutcome = false
                }
            }
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
        .modifier(SplitSheetHost(session: session))
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
