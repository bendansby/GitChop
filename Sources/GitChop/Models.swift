import SwiftUI

/// Interactive-rebase verbs supported by GitChop. `pick / squash /
/// fixup / drop` mirror raw `git rebase -i`. `edit` is GitChop's hook
/// for split-commit-in-window: when an edit commit is reached during
/// rebase, the running plan's `editPlan` is consulted and the commit
/// is split into the configured buckets without dropping back to the
/// terminal.
enum Verb: String, CaseIterable, Identifiable {
    case pick
    case edit
    case squash
    case fixup
    case drop

    var id: String { rawValue }

    /// Short one-glyph hint for the verb chip.
    var glyph: String {
        switch self {
        case .pick:   return "•"
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
        case .edit:   return "Split this commit into multiple smaller commits"
        case .squash: return "Combine into the previous commit, keeping both messages"
        case .fixup:  return "Combine into the previous commit, dropping this message"
        case .drop:   return "Remove this commit entirely"
        }
    }

    var color: Color {
        switch self {
        case .pick:   return Color(.secondaryLabelColor)
        case .edit:   return Color(red: 0.55, green: 0.30, blue: 0.85)   // violet
        case .squash: return Color(red: 0.10, green: 0.41, blue: 0.84)
        case .fixup:  return Color(red: 0.18, green: 0.55, blue: 0.34)
        case .drop:   return Color(red: 0.85, green: 0.22, blue: 0.22)
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
}

/// One commit loaded from `git log`. Hash is short, `fullHash` is the SHA-1.
struct Commit: Identifiable, Hashable {
    let fullHash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: String

    var id: String { fullHash }
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

    var id: String { commit.fullHash }
}

/// Result returned from a rebase attempt — drives the post-Apply alert.
struct RebaseOutcome {
    enum Kind { case success, failed }
    let kind: Kind
    let log: String
    let backupRef: String
}
