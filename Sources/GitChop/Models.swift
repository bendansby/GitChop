import SwiftUI

/// One of the six interactive-rebase verbs. v0.1 supports the four that
/// don't need extra UI: pick / squash / fixup / drop. reword and edit
/// (split-commit) come in v0.2.
enum Verb: String, CaseIterable, Identifiable {
    case pick
    case squash
    case fixup
    case drop

    var id: String { rawValue }

    /// Short one-glyph hint for the verb chip.
    var glyph: String {
        switch self {
        case .pick:   return "•"
        case .squash: return "↑"
        case .fixup:  return "⤴"
        case .drop:   return "✕"
        }
    }

    /// Human-readable explanation, shown in the verb-cycle menu.
    var explanation: String {
        switch self {
        case .pick:   return "Keep this commit as-is"
        case .squash: return "Combine into the previous commit, keeping both messages"
        case .fixup:  return "Combine into the previous commit, dropping this message"
        case .drop:   return "Remove this commit entirely"
        }
    }

    var color: Color {
        switch self {
        case .pick:   return Color(.secondaryLabelColor)
        case .squash: return Color(red: 0.10, green: 0.41, blue: 0.84)
        case .fixup:  return Color(red: 0.18, green: 0.55, blue: 0.34)
        case .drop:   return Color(red: 0.85, green: 0.22, blue: 0.22)
        }
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
struct PlanItem: Identifiable, Hashable {
    let commit: Commit
    var verb: Verb

    var id: String { commit.fullHash }
}

/// Result returned from a rebase attempt — drives the post-Apply alert.
struct RebaseOutcome {
    enum Kind { case success, failed }
    let kind: Kind
    let log: String
    let backupRef: String
}
