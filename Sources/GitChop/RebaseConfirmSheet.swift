import SwiftUI

/// "Here's what's about to happen" confirmation shown before any
/// `git rebase -i` actually runs. Forces a deliberate confirm step
/// because Apply rewrites real history — even with the auto-backup
/// ref, the user shouldn't be able to one-click their way into a
/// surprise.
///
/// Layout:
///   • header with target branch
///   • headline summary (counts: dropped / squashed / fixup / reordered)
///   • preview of the plan rows in their post-Apply order, color-coded
///     by verb
///   • backup-ref notice
///   • Cancel + Apply buttons
struct RebaseConfirmSheet: View {
    @ObservedObject var session: RebaseSession
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            summary
            Divider()
            planPreview
            Divider()
            backupNotice
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 480, maxHeight: 720)
    }

    // MARK: - Counts

    private var dropCount:   Int { session.plan.filter { $0.verb == .drop   }.count }
    private var squashCount: Int { session.plan.filter { $0.verb == .squash }.count }
    private var fixupCount:  Int { session.plan.filter { $0.verb == .fixup  }.count }
    private var pickCount:   Int { session.plan.filter { $0.verb == .pick   }.count }

    /// Net commit count after Apply: starts at the plan size, drops
    /// removed entries, drops squash/fixup entries (they collapse into
    /// the previous pick).
    private var resultingCommitCount: Int {
        session.plan.count - dropCount - squashCount - fixupCount
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apply rebase to \(session.branch.isEmpty ? "(detached HEAD)" : session.branch)?")
                    .font(.title3.weight(.semibold))
                Text("\(session.plan.count) commit\(session.plan.count == 1 ? "" : "s") will be rewritten in place.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        let bullets = summaryBullets()
        VStack(alignment: .leading, spacing: 6) {
            Text("What will change")
                .font(.caption).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary)
            if bullets.isEmpty {
                Text("Nothing — every commit is set to pick, in the original order.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.body)
                }
            }
            Text("After Apply: **\(resultingCommitCount)** commit\(resultingCommitCount == 1 ? "" : "s") on \(session.branch.isEmpty ? "branch" : session.branch).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    /// Build a humanized bullet list of the changes the user has queued.
    private func summaryBullets() -> [String] {
        var lines: [String] = []
        if session.isReordered {
            lines.append("Commit order has been changed.")
        }
        if dropCount > 0 {
            lines.append("\(dropCount) commit\(dropCount == 1 ? " will be dropped." : "s will be dropped.")")
        }
        if squashCount > 0 {
            lines.append("\(squashCount) commit\(squashCount == 1 ? " will be squashed into the one above it (messages combined)." : "s will be squashed into the one above each of them (messages combined).")")
        }
        if fixupCount > 0 {
            lines.append("\(fixupCount) commit\(fixupCount == 1 ? " will be fixed up into the one above it (this commit's message discarded)." : "s will be fixed up into the one above each of them (their messages discarded).")")
        }
        return lines
    }

    // MARK: - Plan preview

    private var planPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan")
                .font(.caption).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.plan) { item in
                        previewRow(item)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
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

    private func previewRow(_ item: PlanItem) -> some View {
        HStack(spacing: 10) {
            Text(item.verb.rawValue)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.white)
                .frame(width: 56)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(item.verb.color)
                )
            Text(item.commit.shortHash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(item.commit.subject)
                .lineLimit(1)
                .font(.callout)
                .foregroundStyle(item.verb == .drop ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .strikethrough(item.verb == .drop)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: - Backup notice

    private var backupNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lifepreserver")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("A backup ref will be created at `refs/gitchop-backup/<timestamp>` before any change is made.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If the rebase fails or hits a conflict, GitChop aborts and resets HEAD back to that ref automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Apply", action: onApply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
