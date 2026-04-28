import SwiftUI

/// Read-only diff for the selected commit. Toolbar in the header lets
/// you toggle word-wrap and line numbers; both prefs persist via
/// @AppStorage so they survive app relaunches.
struct DiffPaneView: View {
    @EnvironmentObject var session: RebaseSession
    @AppStorage("diff.wordWrap")     private var wordWrap = false
    @AppStorage("diff.lineNumbers")  private var showLineNumbers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            diffArea
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
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
            // Display toggles. Compact icon buttons; tooltip explains
            // the action. Active = primary color, inactive = tertiary.
            toggleButton(
                isOn: $wordWrap,
                onIcon: "text.append",
                offIcon: "text.append",
                helpOn: "Word wrap on (click to disable)",
                helpOff: "Word wrap off (click to enable)"
            )
            toggleButton(
                isOn: $showLineNumbers,
                onIcon: "list.number",
                offIcon: "list.number",
                helpOn: "Line numbers on (click to hide)",
                helpOff: "Line numbers off (click to show)"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func toggleButton(
        isOn: Binding<Bool>,
        onIcon: String,
        offIcon: String,
        helpOn: String,
        helpOff: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: isOn.wrappedValue ? onIcon : offIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn.wrappedValue ? Color.primary.opacity(0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(isOn.wrappedValue ? helpOn : helpOff)
    }

    @ViewBuilder
    private var diffArea: some View {
        if session.diffText.isEmpty {
            placeholderArea
        } else if wordWrap {
            // Wrapping mode: only vertical scroll. Lines re-flow to
            // pane width; line-number gutter (if shown) keeps each
            // logical line's number at the top of its wrapped block.
            ScrollView(.vertical) {
                diffBody
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.textBackgroundColor))
        } else {
            // Non-wrap: classic two-axis scroll. Long lines extend off
            // to the right, user scrolls horizontally to read.
            ScrollView([.vertical, .horizontal]) {
                diffBody
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color(.textBackgroundColor))
        }
    }

    /// The actual lines of the diff, optionally with a line-number gutter.
    /// Each line is its own HStack so the gutter number aligns with the
    /// TOP of any wrapped content next to it.
    @ViewBuilder
    private var diffBody: some View {
        let lines = session.diffText.split(separator: "\n", omittingEmptySubsequences: false)
        let gutterWidth = lineNumberGutterWidth(for: lines.count)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                HStack(alignment: .top, spacing: 10) {
                    if showLineNumbers {
                        Text("\(idx + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: gutterWidth, alignment: .trailing)
                    }
                    Text(String(line))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(color(forLine: line))
                        .lineLimit(wordWrap ? nil : 1)
                        // fixedSize(horizontal:) on each line is what
                        // gives us the "lines extend as wide as needed"
                        // behavior under non-wrap mode. In wrap mode
                        // the Text can flow naturally to the next line.
                        .fixedSize(horizontal: !wordWrap, vertical: true)
                        .frame(maxWidth: wordWrap ? .infinity : nil, alignment: .leading)
                }
            }
        }
    }

    /// Subtle color hint for diff structure: + green, - red, @@ blue,
    /// everything else default. Doesn't try to be a full syntax
    /// highlighter — just enough to scan a diff fast.
    private func color(forLine line: Substring) -> Color {
        guard let first = line.first else { return .primary }
        // Skip the `+++ b/foo` and `--- a/foo` header lines from being
        // treated as add/remove (they start with two of the marker
        // character).
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return .secondary
        }
        switch first {
        case "+": return Color(red: 0.20, green: 0.56, blue: 0.30)
        case "-": return Color(red: 0.78, green: 0.22, blue: 0.22)
        case "@": return Color(red: 0.18, green: 0.42, blue: 0.84)
        default:  return .primary
        }
    }

    /// Width of the line-number gutter, scaled to the digit count of
    /// the largest line number we'll show. Monospaced caption glyphs
    /// are roughly 7px wide each at default sizing — give a touch of
    /// extra room for clarity.
    private func lineNumberGutterWidth(for lineCount: Int) -> CGFloat {
        let digits = max(2, String(lineCount).count)
        return CGFloat(digits) * 8 + 4
    }

    private var placeholderArea: some View {
        ZStack {
            Color(.textBackgroundColor)
            Text(placeholderText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var placeholderText: String {
        if session.plan.isEmpty {
            return "Open a repo to see commits and diffs here."
        }
        return "Select a commit to view its diff."
    }
}
