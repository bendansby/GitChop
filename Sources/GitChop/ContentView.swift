import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: RebaseSession
    @State private var showOutcome = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                CommitListView()
                    .frame(minWidth: 380, idealWidth: 480)
                DiffPaneView()
                    .frame(minWidth: 360, idealWidth: 600)
            }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    session.openPicker()
                } label: {
                    Label("Open Repo…", systemImage: "folder")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await session.apply()
                        if session.lastOutcome != nil { showOutcome = true }
                    }
                } label: {
                    Label("Apply Rebase", systemImage: "checkmark.seal.fill")
                }
                .disabled(!session.hasChanges || session.isApplying)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .alert("Rebase result", isPresented: $showOutcome, presenting: session.lastOutcome) { _ in
            Button("OK") { }
        } message: { outcome in
            Text(outcome.kind == .success
                 ? "Applied. Backup ref: \(outcome.backupRef)\n\n\(outcome.log)"
                 : "Failed and rolled back from backup ref \(outcome.backupRef).\n\n\(outcome.log)")
        }
    }

    private var statusBar: some View {
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
