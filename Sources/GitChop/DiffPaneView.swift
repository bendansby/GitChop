import SwiftUI

/// Read-only diff for the selected commit. v0.1 just shows `git show`
/// output; v0.2 will color-code +/- lines and let you pick hunks (the
/// split-commit UI lives here).
struct DiffPaneView: View {
    @EnvironmentObject var session: RebaseSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(session.diffText.isEmpty ? placeholderText : session.diffText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color(.textBackgroundColor))
        }
    }

    private var header: some View {
        HStack {
            if let id = session.selectedID,
               let item = session.plan.first(where: { $0.id == id }) {
                Text(item.commit.shortHash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(item.commit.subject)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(item.commit.date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Diff")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholderText: String {
        if session.plan.isEmpty {
            return "Open a repo to see commits and diffs here."
        }
        return "Select a commit to view its diff."
    }
}
