import SwiftUI

/// Ordered list of plan rows. Drag-reorder; click a row to view its diff;
/// click the verb chip to cycle.
struct CommitListView: View {
    @EnvironmentObject var session: RebaseSession
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if session.plan.isEmpty {
                emptyState
            } else {
                List(selection: Binding(
                    get: { session.selectedID },
                    set: { session.selectCommit($0) }
                )) {
                    ForEach(Array(session.plan.enumerated()), id: \.element.id) { idx, item in
                        CommitRow(
                            item: item,
                            attachedToAbove: PlanInspector.attachedToAbove(at: idx, in: session.plan),
                            absorbedCount:   PlanInspector.absorbedCount(at: idx, in: session.plan)
                        )
                        .tag(item.id)
                    }
                    .onMove { offsets, destination in
                        session.move(from: offsets, to: destination)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(session.repoName)
                .font(.headline)
            if !session.branch.isEmpty {
                Text(session.branch)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            // The count IS the depth menu — single point of interaction
            // for "how many commits am I seeing and how many can I get".
            // When no repo is loaded we drop the menu entirely instead
            // of showing a disabled-everything dropdown.
            if session.repoURL != nil {
                depthMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Header-embedded depth picker. Click the count → choose how many
    /// commits to load.
    private var depthMenu: some View {
        Menu {
            ForEach([12, 25, 50, 100], id: \.self) { d in
                Button {
                    session.reload(depth: d)
                } label: {
                    if d == session.plan.count {
                        Label("Last \(d) commits", systemImage: "checkmark")
                    } else {
                        Text("Last \(d) commits")
                    }
                }
                // A choice that's >= the chopable max while we already
                // hit that max is meaningless, so disable it.
                .disabled(d > session.totalNonMergeCount && session.plan.count >= session.totalNonMergeCount)
            }
            Divider()
            Button {
                session.loadAll()
            } label: {
                if session.plan.count == session.totalNonMergeCount && session.totalNonMergeCount > 0 {
                    Label("All \(session.totalNonMergeCount) commits", systemImage: "checkmark")
                } else if session.totalNonMergeCount > 0 {
                    Text("All \(session.totalNonMergeCount) commits")
                } else {
                    Text("All commits")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(headerCountLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose how many recent commits to show")
    }

    /// "12 commits" when everything's loaded; "12 of 24 commits" when
    /// the view is intentionally truncated to a depth less than total.
    private var headerCountLabel: String {
        if session.totalNonMergeCount > 0 && session.plan.count < session.totalNonMergeCount {
            return "\(session.plan.count) of \(session.totalNonMergeCount) commits"
        }
        return "\(session.plan.count) commit\(session.plan.count == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "scissors")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No repo loaded")
                .font(.headline)
            Text(session.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Open Repo…") { workspace.openPicker() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct CommitRow: View {
    let item: PlanItem
    let attachedToAbove: Bool   // squash/fixup with a valid parent above
    let absorbedCount: Int      // for picks: how many squash/fixup rows fold into me

    @EnvironmentObject var session: RebaseSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            // "Merges into the row above" cue. Only shown for squash/fixup
            // when there's a valid pick chain to attach to. Sized to a
            // fixed width so the verb chip's left edge stays aligned
            // across rows that do and don't have it.
            attachIndicator

            verbChip

            Text(item.commit.shortHash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(item.commit.subject)
                .lineLimit(1)
                .font(.body)
                .foregroundStyle(item.verb == .drop ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.primary))
                .strikethrough(item.verb == .drop)

            // "+N merging in" badge for picks that absorb squash/fixup
            // commits below them. Reads as a counterpart to the attach
            // indicator on those rows.
            if absorbedCount > 0 {
                Text("+\(absorbedCount)")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
                    .help("\(absorbedCount) commit\(absorbedCount == 1 ? "" : "s") below will be merged into this one")
            }

            Spacer(minLength: 8)

            Text(item.commit.author)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(item.verb == .drop ? 0.55 : 1.0)
    }

    /// Up-pointing arrow that indicates the row's commit will be folded
    /// into the row above. Color matches the verb so squash and fixup
    /// chains are visually grouped.
    @ViewBuilder
    private var attachIndicator: some View {
        if attachedToAbove {
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.verb.color)
                .frame(width: 14)
                .help("Merges into the commit above")
        } else {
            // Reserve space so verb chips align across the list
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private var verbChip: some View {
        Menu {
            ForEach(Verb.allCases) { verb in
                Button {
                    session.setVerb(of: item.id, to: verb)
                } label: {
                    Label("\(verb.rawValue.capitalized) — \(verb.explanation)", systemImage: verb == item.verb ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.verb.glyph)
                    .font(.system(.caption, design: .monospaced).bold())
                Text(item.verb.rawValue)
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(item.verb.color)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
