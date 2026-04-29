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
            HStack(alignment: .top, spacing: 14) {
                fileList
                    .frame(maxWidth: .infinity)
                remainingTodoList
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 720)
        .frame(minHeight: 420, idealHeight: 520, maxHeight: 720)
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

    // MARK: - Remaining-todo (mid-rebase reorder)

    /// Drag-reorderable list of commits git hasn't processed yet.
    /// Edits stay in memory until Continue / Skip flushes them to the
    /// rebase TODO file. Empty list (e.g. the conflicting commit was
    /// the last one) collapses to a friendly note.
    private var remainingTodoList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remaining commits (\(session.remainingTodo.count))")
                .font(.caption).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary)
            if session.remainingTodo.isEmpty {
                emptyTodoNote
            } else {
                List {
                    ForEach(session.remainingTodo) { item in
                        todoRow(item)
                    }
                    .onMove { offsets, destination in
                        session.moveRemainingTodo(from: offsets, to: destination)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var emptyTodoNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing left to apply")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Resolving this commit will finish the rebase.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func todoRow(_ item: PlanItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            HStack(spacing: 4) {
                Text(item.verb.glyph)
                    .font(.system(.caption, design: .monospaced).bold())
                Text(item.verb.rawValue)
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(item.verb.color)
            .clipShape(Capsule())
            Text(item.commit.shortHash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(item.commit.subject)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    // MARK: - File actions

    private func absoluteURL(for path: String) -> URL? {
        guard let repo = session.repoURL else { return nil }
        return repo.appendingPathComponent(path)
    }

    private func open(_ path: String) {
        guard let url = absoluteURL(for: path) else { return }
        Preferences.shared.openFileForEditing(url)
    }

    private func reveal(_ path: String) {
        guard let url = absoluteURL(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
