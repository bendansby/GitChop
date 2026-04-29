import SwiftUI

/// Interactive-rebase verbs supported by GitChop. `pick / squash /
/// fixup / drop` mirror raw `git rebase -i`. `edit` is GitChop's hook
/// for split-commit-in-window: when an edit commit is reached during
/// rebase, the running plan's `editPlan` is consulted and the commit
/// is split into the configured buckets without dropping back to the
/// terminal.
enum Verb: String, CaseIterable, Identifiable {
    case pick
    case reword
    case edit
    case squash
    case fixup
    case drop

    var id: String { rawValue }

    /// Short one-glyph hint for the verb chip.
    var glyph: String {
        switch self {
        case .pick:   return "•"
        case .reword: return "✎"
        case .edit:   return "✂"     // chop — fits the app theme + signals action
        case .squash: return "↑"
        case .fixup:  return "⤴"
        case .drop:   return "✕"
        }
    }

    /// Human-readable explanation, shown in the verb-cycle menu.
    var explanation: String {
        switch self {
        case .pick:   return "Keep this commit as-is"
        case .reword: return "Edit this commit's message"
        case .edit:   return "Split this commit into multiple smaller commits"
        case .squash: return "Combine into the previous commit, keeping both messages"
        case .fixup:  return "Combine into the previous commit, dropping this message"
        case .drop:   return "Remove this commit entirely"
        }
    }

    var color: Color {
        switch self {
        case .pick:   return Color(.secondaryLabelColor)
        case .reword: return Color(red: 0.85, green: 0.55, blue: 0.10)   // amber
        case .edit:   return Color(red: 0.55, green: 0.30, blue: 0.85)   // violet
        case .squash: return Color(red: 0.10, green: 0.41, blue: 0.84)
        case .fixup:  return Color(red: 0.18, green: 0.55, blue: 0.34)
        case .drop:   return Color(red: 0.85, green: 0.22, blue: 0.22)
        }
    }

    /// SF Symbol name for the verb-chip menu. Mirrors the chip's text
    /// glyph but renders crisper as a native menu icon.
    var symbolName: String {
        switch self {
        case .pick:   return "circle"
        case .reword: return "pencil"
        case .edit:   return "scissors"
        case .squash: return "arrow.up"
        case .fixup:  return "arrow.up.right"
        case .drop:   return "xmark"
        }
    }
}

/// Plan for splitting a single edit-marked commit into N smaller
/// commits. Populated by the SplitCommitSheet; consumed by the
/// rebase engine when git pauses at the corresponding `edit` step.
///
/// Hunk IDs reference parsed hunks of the commit's diff. The split
/// engine re-parses the diff at apply time and matches by ID (a
/// content-derived stable key, not a UUID), so the plan survives
/// closing and reopening the sheet.
struct EditPlan: Hashable, Codable {
    var buckets: [Bucket]

    struct Bucket: Identifiable, Hashable, Codable {
        var id = UUID()
        var subject: String = ""
        /// Hunk IDs assigned to this bucket. The set is ordered by
        /// diff-encounter order at apply time; insertion order here
        /// is irrelevant.
        var hunkIDs: Set<String> = []
    }

    /// Visual identity for the bucket at index `idx`. Cycles through a
    /// fixed palette so each bucket has a distinct color shared across
    /// the split sheet's bucket cards, the hunk-row dot, and the ghost
    /// rows that preview this bucket in the commit list.
    static func bucketColor(_ idx: Int) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo]
        return palette[idx % palette.count]
    }
}

/// One commit loaded from `git log`. Hash is short, `fullHash` is the
/// SHA-1. `date` is the absolute display string ("Apr 22, 2026");
/// `timestamp` is the committer date as a unix epoch so we can format
/// relative times ("3d") in the chronology column without re-parsing.
struct Commit: Identifiable, Hashable {
    let fullHash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: String
    let timestamp: TimeInterval

    var id: String { fullHash }

    /// Compact relative-age token for the commit list's chronology
    /// column: "now" / "Xm" / "Xh" / "Xd" / "Xw" / "Xmo" / "Xy".
    /// Hand-rolled so we get short tokens — RelativeDateTimeFormatter's
    /// "2 weeks ago" doesn't fit the row.
    var relativeAge: String {
        let now = Date().timeIntervalSince1970
        let delta = max(0, now - timestamp)
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day
        let month = 30 * day
        let year = 365 * day
        switch delta {
        case ..<minute:    return "now"
        case ..<hour:      return "\(Int(delta / minute))m"
        case ..<day:       return "\(Int(delta / hour))h"
        case ..<week:      return "\(Int(delta / day))d"
        case ..<month:     return "\(Int(delta / week))w"
        case ..<year:      return "\(Int(delta / month))mo"
        default:           return "\(Int(delta / year))y"
        }
    }
}

/// One row in the rebase plan: a commit + the verb the user wants applied.
/// The plan as a whole is just an ordered array of these. Reordering the
/// array is what reorders the rebase.
///
/// `editPlan` is set when verb is `.edit` and the user has configured a
/// split via SplitCommitSheet. Nil means "edit but no split configured
/// yet" — the engine treats that as a no-op edit and continues the
/// rebase past the commit unchanged.
struct PlanItem: Identifiable, Hashable {
    let commit: Commit
    var verb: Verb
    var editPlan: EditPlan? = nil
    /// New full commit message when the user has reworded this commit
    /// (subject + optional body, separated by a blank line per git
    /// convention). Nil means "keep the original message." Only
    /// meaningful when `verb == .reword`; `setVerb` clears this when
    /// leaving the reword verb.
    var newMessage: String? = nil

    var id: String { commit.fullHash }

    /// First line of the new message if reworded, otherwise the commit's
    /// original subject. Used by the row + confirm sheet preview.
    var displaySubject: String {
        if let m = newMessage {
            return String(m.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        return commit.subject
    }
}

/// Result returned from a rebase attempt — drives the post-Apply alert
/// or the conflict-resolution sheet.
///
/// `.conflicted` means git stopped on merge conflicts and `.git/rebase-merge/`
/// is still around. The caller is expected to surface the listed files
/// to the user, who then resolves them and asks GitChop to continue
/// (or skip the commit, or abort the whole thing). The corresponding
/// `ActiveRebase` carries the state needed to resume.
struct RebaseOutcome {
    enum Kind: Equatable {
        case success
        case failed
        case conflicted(files: [String])
    }
    let kind: Kind
    let log: String
    let backupRef: String
}
