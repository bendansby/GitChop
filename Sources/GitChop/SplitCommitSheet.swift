import SwiftUI

/// Split-commit configurator. Loads the diff of the target commit,
/// parses it into hunks, and lets the user assign each hunk to one
/// of N "buckets" (which become individual commits at apply time).
/// Each bucket has its own subject. Saving stores the resulting
/// EditPlan onto the corresponding PlanItem in the session.
///
/// Layout (top-to-bottom):
///   • Header: commit identity + intro copy
///   • Hunks list: one row per hunk, with a bucket picker on the right
///   • Buckets list: subject input + per-bucket summary, plus + button
///   • Footer: validation status + Cancel / Save
struct SplitCommitSheet: View {
    @ObservedObject var session: RebaseSession
    /// ID of the PlanItem being split.
    let planItemID: String
    let onSave: (EditPlan) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var parsedDiff: ParsedDiff?
    @State private var loadError: String?
    @State private var buckets: [EditPlan.Bucket] = []

    /// Map of hunk-ID → bucket-ID (which bucket each hunk is currently
    /// assigned to). Source of truth for the picker UI; derived back
    /// into Set<HunkID> per bucket on save.
    @State private var assignments: [String: UUID] = [:]

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 720)
        .frame(minHeight: 540, maxHeight: 820)
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Split commit")
                    .font(.title3.weight(.semibold))
                if let item = currentItem {
                    HStack(spacing: 6) {
                        Text(item.commit.shortHash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.commit.subject)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Content (loading / error / form)

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorState(err)
        } else if let diff = parsedDiff {
            if diff.allHunks.isEmpty {
                emptyState
            } else {
                form(diff: diff)
            }
        } else {
            loadingState
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading diff…").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't load the diff", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.red)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing to split", systemImage: "tray")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This commit has no hunks GitChop can split — likely a merge commit, a binary-only delta, or an empty commit.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func form(diff: ParsedDiff) -> some View {
        HSplitView {
            hunksColumn(diff: diff)
                .frame(minWidth: 320, idealWidth: 380)
            bucketsColumn
                .frame(minWidth: 280, idealWidth: 320)
        }
    }

    // MARK: - Hunks column

    private func hunksColumn(diff: ParsedDiff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hunks (\(diff.allHunks.count))")
                .font(.caption).textCase(.uppercase).tracking(0.4)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.files) { file in
                        if file.isBinary {
                            binaryFileRow(file)
                        } else {
                            ForEach(file.hunks) { hunk in
                                hunkRow(hunk)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .background(Color(.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func binaryFileRow(_ file: ParsedDiff.DiffFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.system(.body, design: .monospaced))
                Text("Binary — can't split. Goes to bucket 1.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func hunkRow(_ hunk: ParsedDiff.Hunk) -> some View {
        let assignedBucketID = assignments[hunk.id]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hunk.file)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(hunk.header.prefix(64))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if hunk.addedCount > 0 {
                        Text("+\(hunk.addedCount)")
                            .foregroundStyle(Color(red: 0.20, green: 0.56, blue: 0.30))
                    }
                    if hunk.removedCount > 0 {
                        Text("−\(hunk.removedCount)")
                            .foregroundStyle(Color(red: 0.78, green: 0.22, blue: 0.22))
                    }
                }
                .font(.system(.caption2, design: .monospaced).bold())
            }
            Spacer()
            bucketPicker(for: hunk, assignedBucketID: assignedBucketID)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    private func bucketPicker(for hunk: ParsedDiff.Hunk, assignedBucketID: UUID?) -> some View {
        Menu {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, bucket in
                Button {
                    assignments[hunk.id] = bucket.id
                } label: {
                    if assignedBucketID == bucket.id {
                        Label("Bucket \(idx + 1)", systemImage: "checkmark")
                    } else {
                        Text("Bucket \(idx + 1)")
                    }
                }
            }
        } label: {
            if let bid = assignedBucketID, let idx = buckets.firstIndex(where: { $0.id == bid }) {
                Text("Bucket \(idx + 1)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.18))
                    )
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Unassigned")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    )
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Buckets column

    private var bucketsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Buckets (\(buckets.count))")
                    .font(.caption).textCase(.uppercase).tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addBucket()
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, bucket in
                        bucketCard(idx: idx, bucket: bucket)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
    }

    private func bucketCard(idx: Int, bucket: EditPlan.Bucket) -> some View {
        let hunkCount = assignments.values.filter { $0 == bucket.id }.count
        let counts = lineCounts(for: bucket.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bucket \(idx + 1)")
                    .font(.callout.weight(.semibold))
                Spacer()
                if buckets.count > 2 {
                    Button {
                        removeBucket(bucket.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this bucket — its hunks become Unassigned")
                }
            }
            TextField("Commit message", text: bindingForSubject(of: bucket.id))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            HStack(spacing: 12) {
                Text("\(hunkCount) hunk\(hunkCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if counts.added > 0 {
                    Text("+\(counts.added)")
                        .foregroundStyle(Color(red: 0.20, green: 0.56, blue: 0.30))
                }
                if counts.removed > 0 {
                    Text("−\(counts.removed)")
                        .foregroundStyle(Color(red: 0.78, green: 0.22, blue: 0.22))
                }
            }
            .font(.system(.caption2, design: .monospaced).bold())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            statusLine
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(buildPlan())
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
    }

    private var statusLine: some View {
        Group {
            if isValid {
                Label("All hunks assigned", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            } else if unassignedCount > 0 {
                Label(
                    "\(unassignedCount) hunk\(unassignedCount == 1 ? "" : "s") unassigned",
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(.orange)
            } else if emptyBucketCount > 0 {
                Label(
                    "\(emptyBucketCount) bucket\(emptyBucketCount == 1 ? "" : "s") empty",
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(.orange)
            } else if missingSubjectCount > 0 {
                Label(
                    "\(missingSubjectCount) bucket\(missingSubjectCount == 1 ? "" : "s") need a message",
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    // MARK: - Validation

    private var allHunkIDs: Set<String> {
        Set(parsedDiff?.allHunks.map(\.id) ?? [])
    }

    private var unassignedCount: Int {
        allHunkIDs.subtracting(assignments.keys).count
    }

    private var emptyBucketCount: Int {
        buckets.filter { b in !assignments.values.contains(b.id) }.count
    }

    private var missingSubjectCount: Int {
        buckets.filter { $0.subject.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private var isValid: Bool {
        unassignedCount == 0 && emptyBucketCount == 0 && missingSubjectCount == 0
    }

    // MARK: - Actions

    private func addBucket() {
        var b = EditPlan.Bucket()
        b.subject = ""
        buckets.append(b)
    }

    private func removeBucket(_ id: UUID) {
        buckets.removeAll { $0.id == id }
        // Unassign hunks that pointed at the removed bucket — they
        // become unassigned and the user can reassign.
        for (hid, bid) in assignments where bid == id {
            assignments.removeValue(forKey: hid)
        }
    }

    private func bindingForSubject(of bucketID: UUID) -> Binding<String> {
        Binding(
            get: {
                buckets.first { $0.id == bucketID }?.subject ?? ""
            },
            set: { newValue in
                if let idx = buckets.firstIndex(where: { $0.id == bucketID }) {
                    buckets[idx].subject = newValue
                }
            }
        )
    }

    private func lineCounts(for bucketID: UUID) -> (added: Int, removed: Int) {
        guard let diff = parsedDiff else { return (0, 0) }
        let hunkIDs = assignments.compactMap { $0.value == bucketID ? $0.key : nil }
        let hunks = diff.allHunks.filter { hunkIDs.contains($0.id) }
        let added = hunks.reduce(0) { $0 + $1.addedCount }
        let removed = hunks.reduce(0) { $0 + $1.removedCount }
        return (added, removed)
    }

    private func buildPlan() -> EditPlan {
        let resolved = buckets.map { b -> EditPlan.Bucket in
            var copy = b
            copy.hunkIDs = Set(assignments.compactMap { $0.value == b.id ? $0.key : nil })
            return copy
        }
        return EditPlan(buckets: resolved)
    }

    // MARK: - Loading

    private var currentItem: PlanItem? {
        session.plan.first { $0.id == planItemID }
    }

    private func loadIfNeeded() {
        guard parsedDiff == nil else { return }
        guard let item = currentItem, let repo = session.repoURL else {
            loadError = "Couldn't find the commit in the current plan."
            return
        }

        // git show --no-color is the same diff GitChop renders in the
        // diff pane, so the user sees consistent hunks here. We use
        // -U3 (default) — same as `git diff` — so hunk boundaries
        // match what the rebase apply step will see.
        Task {
            let runner = GitRunner(cwd: repo)
            do {
                let result = try runner.run(["show", "--patch", "--no-color", item.commit.fullHash])
                guard result.isSuccess else {
                    await MainActor.run { loadError = result.stderr }
                    return
                }
                let diff = HunkParser.parse(result.stdout)
                await MainActor.run {
                    self.parsedDiff = diff
                    self.bootstrapBuckets(diff: diff, existing: item.editPlan)
                }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }

    /// Initialize the buckets array. If the user has an existing plan,
    /// restore it. Otherwise default to two empty buckets — the "split
    /// in half" common case.
    private func bootstrapBuckets(diff: ParsedDiff, existing: EditPlan?) {
        if let existing = existing {
            buckets = existing.buckets
            // Replay the existing assignments. Hunks whose IDs no
            // longer parse out of the diff (e.g. content drifted)
            // become unassigned, which the validation will surface.
            let validIDs = Set(diff.allHunks.map(\.id))
            for bucket in existing.buckets {
                for hid in bucket.hunkIDs where validIDs.contains(hid) {
                    assignments[hid] = bucket.id
                }
            }
        } else {
            buckets = [
                EditPlan.Bucket(subject: ""),
                EditPlan.Bucket(subject: ""),
            ]
            // Auto-assign all binary-file hunks (none — binaries don't
            // produce hunks, but for files that DO have hunks, leave
            // them unassigned so the user makes deliberate choices).
        }
    }
}
