import SwiftUI

/// Reword editor. Single TextEditor preloaded with the commit's full
/// original message (subject + body, separated by a blank line per git
/// convention). The user edits in place; Save stores the full new
/// message on the session via `saveReword(_:newMessage:original:)`.
/// At apply time the engine writes the saved message into git's
/// COMMIT_EDITMSG via the reword helper script.
struct RewordSheet: View {
    @ObservedObject var session: RebaseSession
    let planItemID: String
    let onSave: (_ newMessage: String, _ original: String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var originalMessage: String = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 620)
        .frame(minHeight: 420, idealHeight: 520, maxHeight: 720)
        .onAppear(perform: load)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reword commit")
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
            Image(systemName: "pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Verb.reword.color)
        }
    }

    private var editor: some View {
        // Convention: subject on line 1, blank line, then body. The
        // TextEditor renders that as plain monospaced text — same shape
        // git itself shows when invoking the editor.
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .focused($focused)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Color(.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var footer: some View {
        HStack {
            statusLine
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave(text, originalMessage) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!loaded || !hasRealChange)
        }
    }

    /// True when Save would actually change the commit's message.
    /// Empty / whitespace-only or identical-to-original both count as
    /// "no change" — saving in those cases would mark the row reword
    /// without doing anything at apply time, which the session also
    /// guards against on cancel.
    private var hasRealChange: Bool {
        let trimmedNew = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrig = originalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedNew.isEmpty && trimmedNew != trimmedOrig
    }

    @ViewBuilder
    private var statusLine: some View {
        let trimmedNew = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrig = originalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNew.isEmpty {
            Label("Empty — saving will leave the original intact", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if trimmedNew == trimmedOrig {
            Label("Unchanged — saving will leave it as-is", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Will rewrite this commit's message", systemImage: "arrow.right.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Verb.reword.color)
        }
    }

    // MARK: - Load + identity

    private var currentItem: PlanItem? {
        session.plan.first { $0.id == planItemID }
    }

    private func load() {
        guard let item = currentItem else { return }

        // Pull the commit's full original message via `git log %B`.
        // %B emits the raw message (subject + body) verbatim, including
        // any trailing newline git stored — we trim trailing whitespace
        // so the editor doesn't open with a phantom blank line.
        var fetched: String? = nil
        if let repo = session.repoURL {
            let runner = GitRunner(cwd: repo)
            if let result = try? runner.run(["log", "-1", "--pretty=format:%B", item.commit.fullHash]),
               result.isSuccess {
                fetched = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Fallback to the indexed subject if git log somehow failed —
        // worst case the user edits just the subject, same as before.
        let baseline = fetched ?? item.commit.subject
        originalMessage = baseline
        // If the user already saved a reword, keep their text;
        // otherwise pre-fill with the original so they can edit in place.
        text = item.newMessage ?? baseline
        loaded = true
        focused = true
    }
}
