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
                            absorbedCount: PlanInspector.absorbedCount(at: idx, in: session.plan),
                            isSelected: session.selectedID == item.id
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
    let absorbedCount: Int      // for picks: how many squash/fixup rows fold into me
    let isSelected: Bool        // whether this row is the active selection (for icon contrast)

    @EnvironmentObject var session: RebaseSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            // Attach-relationship column. Mutually exclusive states:
            //   • squash/fixup with a valid parent → up-arrow in verb color
            //   • pick absorbing N below          → "+N" mono text
            //   • otherwise                        → reserved blank space
            // Single column so verb chips line up vertically across
            // every row regardless of which (if either) cue is present.
            relationshipIndicator

            verbChip

            Text(item.commit.shortHash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(item.displaySubject)
                .lineLimit(1)
                .font(.body)
                .foregroundStyle(subjectColor)
                .strikethrough(item.verb == .drop)
            Spacer(minLength: 8)
            Text(item.commit.author)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(item.verb == .drop ? 0.55 : 1.0)
    }

    private var subjectColor: AnyShapeStyle {
        if item.verb == .drop { return AnyShapeStyle(Color.secondary) }
        // On a selected row, custom verb-tinted text would clash with
        // the system selection background — fall back to white.
        if isSelected && item.verb == .reword && item.newMessage != nil {
            return AnyShapeStyle(Color.white)
        }
        if item.verb == .reword && item.newMessage != nil { return AnyShapeStyle(Verb.reword.color) }
        return AnyShapeStyle(.primary)
    }

    /// One column that shows either "I merge up into the row above"
    /// (squash/fixup) or "N rows merge into me" (pick), in the same
    /// horizontal slot so the layout stays aligned regardless of which
    /// cue (or none) applies.
    @ViewBuilder
    private var relationshipIndicator: some View {
        ZStack {
            // Attach-arrow used to live here for squash/fixup rows but
            // duplicated the chip's ↑ / ⤴ glyph — same row, same idea,
            // twice. Only the absorbed-count badge is kept: it's unique
            // info the chip can't carry.
            if absorbedCount > 0 {
                Text("+\(absorbedCount)")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .help("\(absorbedCount) commit\(absorbedCount == 1 ? "" : "s") below will merge into this one")
            }
        }
        .frame(width: 22)
    }

    private var verbChip: some View {
        Menu {
            // Picker(.inline) renders as a proper macOS menu section with
            // radio-style selection (filled circle on the active item),
            // which reads cleaner than a list of Buttons each with their
            // own checkmark prefix. The section header doubles as a
            // category label so the action items below feel separate.
            Picker(
                "Verb",
                selection: Binding(
                    get: { item.verb },
                    set: { session.setVerb(of: item.id, to: $0) }
                )
            ) {
                ForEach(Verb.allCases) { verb in
                    // Glyph + name + explanation. The explanation is the
                    // discoverability win — first-time users don't have
                    // to remember what each verb does, and even regulars
                    // benefit from the squash-vs-fixup distinction
                    // spelled out at point of use.
                    Text("\(verb.glyph)  \(verb.rawValue.capitalized) — \(verb.explanation)")
                        .tag(verb)
                }
            }
            .pickerStyle(.inline)

            // For already-edit rows, expose a way to re-open the
            // split sheet without first toggling away and back. The
            // verb itself doesn't change.
            if item.verb == .edit {
                Divider()
                Button {
                    session.openSplitSheet(for: item.id)
                } label: {
                    Label(
                        item.editPlan == nil ? "Configure split…" : "Edit split…",
                        systemImage: "rectangle.split.3x1"
                    )
                }
            }
            // Same for reword: re-open the sheet without toggling the
            // verb away and back.
            if item.verb == .reword {
                Divider()
                Button {
                    session.openRewordSheet(for: item.id)
                } label: {
                    Label(
                        item.newMessage == nil ? "Edit message…" : "Edit message again…",
                        systemImage: "pencil.line"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.verb.glyph)
                    .font(.system(.caption, design: .monospaced).bold())
                Text(item.verb.rawValue)
                    .font(.system(.caption, design: .monospaced))
                // Bucket-count badge: only shown for edit rows that
                // have a saved plan, so it's a positive signal "yes,
                // this is configured" rather than visual noise.
                if item.verb == .edit, let plan = item.editPlan {
                    Text("(\(plan.buckets.count))")
                        .font(.system(.caption2, design: .monospaced))
                        .opacity(0.85)
                }
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

