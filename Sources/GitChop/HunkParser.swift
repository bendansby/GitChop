import Foundation

/// Parses a unified diff (typically the output of `git show --patch
/// --no-color -U3 <commit>`) into structured files and hunks, and can
/// reassemble a subset of those hunks back into a valid unified diff
/// suitable for `git apply --cached`.
///
/// Used by the split-commit flow:
///   1. Sheet calls `parse()` on the full diff of an edit-marked commit
///   2. User assigns hunks to buckets (Set<HunkID>)
///   3. At rebase apply time, engine calls `parse()` again on the
///      working-tree diff (after `git reset HEAD^`), then `reassemble()`
///      per bucket and pipes each result into `git apply --cached`.
enum HunkParser {

    /// Parse a unified diff. Files whose only delta is a binary marker
    /// are flagged with `isBinary` and have an empty hunks array — the
    /// split sheet shows them as "binary, cannot split" rather than
    /// trying to split them across buckets.
    static func parse(_ diffText: String) -> ParsedDiff {
        var files: [ParsedDiff.DiffFile] = []
        // Preserve trailing empty lines so reassembly round-trips
        // bodies that end on a `\n` without dropping the final newline.
        let lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < lines.count {
            // Skip until next file header. Empty/leading lines from
            // `git show`'s commit-message section get skipped here too.
            while i < lines.count && !lines[i].hasPrefix("diff --git ") {
                i += 1
            }
            if i >= lines.count { break }

            // ── header block ──
            // From "diff --git" through the line just before the first
            // "@@ " hunk header (or "Binary files" for binary deltas).
            let fileStart = i
            var headerLines: [String] = []
            var isBinary = false
            while i < lines.count {
                let line = lines[i]
                // First @@ marks the end of the file header block.
                if line.hasPrefix("@@ ") { break }
                // Hitting another file header (other than the one we're
                // already inside) means the current file had no hunks
                // — likely a mode-only or empty rename.
                if line.hasPrefix("diff --git ") && i != fileStart { break }
                if line.hasPrefix("Binary files ") {
                    isBinary = true
                    headerLines.append(line)
                    i += 1
                    break
                }
                headerLines.append(line)
                i += 1
            }

            let header = headerLines.joined(separator: "\n")
            let path = extractPath(headerLines: headerLines)

            // ── hunk blocks ──
            var hunks: [ParsedDiff.Hunk] = []
            while i < lines.count && lines[i].hasPrefix("@@ ") {
                let hunkHeader = lines[i]
                i += 1
                var bodyLines: [String] = []
                while i < lines.count
                        && !lines[i].hasPrefix("@@ ")
                        && !lines[i].hasPrefix("diff --git ") {
                    bodyLines.append(lines[i])
                    i += 1
                }
                hunks.append(ParsedDiff.Hunk(
                    file: path,
                    header: hunkHeader,
                    body: bodyLines.joined(separator: "\n")
                ))
            }

            files.append(ParsedDiff.DiffFile(
                path: path,
                header: header,
                hunks: hunks,
                isBinary: isBinary
            ))
        }

        return ParsedDiff(files: files)
    }

    /// Build a unified diff containing only the listed hunk IDs. Files
    /// with no selected hunks are omitted entirely. Output is suitable
    /// for piping into `git apply --cached`.
    static func reassemble(_ parsed: ParsedDiff, includingHunks ids: Set<String>) -> String {
        var pieces: [String] = []
        for file in parsed.files {
            let selected = file.hunks.filter { ids.contains($0.id) }
            guard !selected.isEmpty else { continue }
            pieces.append(file.header)
            for hunk in selected {
                pieces.append(hunk.header)
                pieces.append(hunk.body)
            }
        }
        // git apply tolerates a trailing newline — and patches without
        // one occasionally trip "corrupt patch at line N" warnings on
        // older git versions, so be safe and append one.
        return pieces.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// Pull the file path from the header lines. Prefers the `+++ b/`
    /// line; falls back to `--- a/` for delete diffs (where +++ is
    /// /dev/null) and to "diff --git" parsing for headers without
    /// either (rare).
    private static func extractPath(headerLines: [String]) -> String {
        for line in headerLines {
            if line.hasPrefix("+++ b/") {
                return String(line.dropFirst(6))
            }
        }
        for line in headerLines {
            if line.hasPrefix("--- a/") {
                return String(line.dropFirst(6))
            }
        }
        // Last resort: parse "diff --git a/foo b/foo" and take the b
        // path. Doesn't handle paths with spaces — those need quoting,
        // which we'd parse via the index/extended headers anyway.
        if let diffLine = headerLines.first(where: { $0.hasPrefix("diff --git ") }) {
            let parts = diffLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count == 4 {
                let bPart = String(parts[3])
                if bPart.hasPrefix("b/") {
                    return String(bPart.dropFirst(2))
                }
                return bPart
            }
        }
        return "(unknown)"
    }
}

// MARK: - Model

struct ParsedDiff {
    var files: [DiffFile]

    /// All hunks across all files in encounter order. Convenience for
    /// the split sheet's flat per-hunk picker.
    var allHunks: [Hunk] {
        files.flatMap { $0.hunks }
    }

    struct DiffFile: Identifiable, Hashable {
        let path: String
        let header: String      // diff/index/---/+++ preamble
        var hunks: [Hunk]
        let isBinary: Bool

        var id: String { path }
    }

    struct Hunk: Identifiable, Hashable {
        let file: String        // path (used in id for stability)
        let header: String      // "@@ -X,Y +A,B @@ optional context"
        let body: String        // " context", "-removed", "+added" lines, joined with \n

        /// Stable content-derived ID. Uses file + header + first body
        /// line, which is unique-enough across re-parses while not
        /// requiring a real hash. Survives close-and-reopen of the
        /// split sheet.
        var id: String {
            let firstBodyLine = body.split(separator: "\n", omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            return "\(file)::\(header)::\(firstBodyLine)"
        }

        /// Counts of +added and -removed lines, used by the sheet's
        /// per-hunk summary chip.
        var addedCount: Int {
            body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
                .count
        }
        var removedCount: Int {
            body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
                .count
        }
    }
}
