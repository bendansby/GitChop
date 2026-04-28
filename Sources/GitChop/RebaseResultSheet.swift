import SwiftUI
import AppKit

/// Polished post-rebase sheet. Replaces the system .alert which cramped
/// the multi-line backup ref + log into illegible body text. Layout:
///
///   • status icon (✓ green / ✕ red)
///   • headline + one-line summary
///   • backup ref (monospace, copyable)
///   • collapsible detail log (monospace, scrollable, copyable)
///   • Done + Copy log buttons
struct RebaseResultSheet: View {
    let outcome: RebaseOutcome
    let dismiss: () -> Void

    @State private var showFullLog = false

    private var isSuccess: Bool { outcome.kind == .success }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            backupRefRow
            if !outcome.log.isEmpty {
                Divider()
                logSection
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 320, maxHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: isSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(isSuccess ? Color.green : Color.red)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isSuccess ? "Rebase complete" : "Rebase failed — rolled back")
                    .font(.title3.weight(.semibold))
                Text(summaryLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryLine: String {
        if isSuccess {
            return "Your branch was rewritten in place. The original tip is preserved at the backup ref below in case you need to roll back."
        } else {
            return "git rebase reported an error. GitChop aborted the rebase and reset HEAD back to the backup ref — your branch is in the same state as before you hit Apply."
        }
    }

    // MARK: - Backup ref

    private var backupRefRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backup ref")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            HStack(spacing: 8) {
                Text(outcome.backupRef.isEmpty ? "(none)" : outcome.backupRef)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !outcome.backupRef.isEmpty {
                    Button {
                        copyToPasteboard(outcome.backupRef)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy backup ref")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            if !outcome.backupRef.isEmpty {
                Text("To restore: `git update-ref HEAD \(outcome.backupRef) && git reset --hard HEAD`")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    showFullLog.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showFullLog ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Details")
                            .font(.caption)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                if showFullLog {
                    Button {
                        copyToPasteboard(outcome.log)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy full log to clipboard")
                }
            }
            if showFullLog {
                ScrollView(.vertical) {
                    Text(outcome.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 220)
                .background(Color(.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !outcome.log.isEmpty && !showFullLog {
                // Quick "copy log" affordance even with details collapsed,
                // for users who just want the raw output.
                Button {
                    copyToPasteboard(outcome.log)
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                }
                .controlSize(.regular)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    // MARK: - Pasteboard

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
