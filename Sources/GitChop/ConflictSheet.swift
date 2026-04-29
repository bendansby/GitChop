import SwiftUI
import AppKit

/// Conflict-resolution sheet. Shown when the engine returns
/// `.conflicted` — the rebase is mid-flight and the working tree has
/// unmerged paths. The user resolves in their editor of choice (we
/// offer Open / Reveal as conveniences) and then chooses Continue,
/// Skip the conflicting commit, or Abort the whole rebase.
struct ConflictSheet: View {
    @ObservedObject var session: RebaseSession
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onAbort: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            fileList
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 580)
        .frame(minHeight: 360, idealHeight: 440, maxHeight: 640)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Resolve conflicts")
                    .font(.title3.weight(.semibold))
                Text("Git stopped on a commit that doesn't apply cleanly. Resolve the listed files in your editor, then click Continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.10))
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Conflicted files (\(session.conflictedFiles.count))")
                    .font(.caption).textCase(.uppercase).tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    session.refreshConflictedFiles()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Re-check the working tree for unresolved files")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.conflictedFiles.isEmpty {
                        allClearRow
                    } else {
                        ForEach(session.conflictedFiles, id: \.self) { path in
                            fileRow(path)
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var allClearRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.13, green: 0.55, blue: 0.20))
            Text("All conflicts resolved — ready to continue.")
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func fileRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Open") { open(path) }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Open this file in your default editor")
            Button("Reveal") { reveal(path) }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Reveal this file in Finder")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        let canContinue = session.conflictedFiles.isEmpty
        return HStack {
            statusLine
            Spacer()
            Button("Abort", role: .destructive, action: onAbort)
                .help("Abort the rebase and restore the pre-Apply state from the backup ref")
            Button("Skip commit", action: onSkip)
                .help("Drop the conflicting commit and continue with the rest of the plan")
            Button("Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue || session.isApplying)
                .help(canContinue
                      ? "Resume the rebase from this commit"
                      : "Resolve all listed files first")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if session.isApplying {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working…").font(.callout).foregroundStyle(.secondary)
            }
        } else if session.conflictedFiles.isEmpty {
            Label("Ready to continue", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color(red: 0.13, green: 0.55, blue: 0.20))
        } else {
            Label(
                "\(session.conflictedFiles.count) file\(session.conflictedFiles.count == 1 ? "" : "s") still unresolved",
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(Color(red: 0.78, green: 0.42, blue: 0.05))
        }
    }

    // MARK: - File actions

    private func absoluteURL(for path: String) -> URL? {
        guard let repo = session.repoURL else { return nil }
        return repo.appendingPathComponent(path)
    }

    private func open(_ path: String) {
        guard let url = absoluteURL(for: path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ path: String) {
        guard let url = absoluteURL(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
