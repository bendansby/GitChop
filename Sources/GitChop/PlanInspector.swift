import Foundation

/// Pure-function helpers for analyzing a rebase plan's structural
/// relationships — specifically the "this row attaches to the row
/// above" semantics of `squash` and `fixup`. Used by the commit list
/// row to decide whether to show the merge-up arrow / +N badge, and
/// by the confirm sheet preview for the same reason.
///
/// The helpers are deliberately not methods on `RebaseSession` — they
/// don't need session state, just the plan array, and pulling them out
/// keeps unit-test seams obvious if we ever add tests.
enum PlanInspector {

    /// Whether the row at `idx` is a squash/fixup that has a valid
    /// commit to attach to above. Returns `false` for picks, drops,
    /// or for squash/fixup at the top of the plan with no parent.
    ///
    /// `drop` rows in between don't break the chain — git rebase
    /// processes them by removing them from history, so a fixup right
    /// after a `pick → drop` still attaches to the pick.
    static func attachedToAbove(at idx: Int, in plan: [PlanItem]) -> Bool {
        guard idx >= 0 && idx < plan.count else { return false }
        let v = plan[idx].verb
        guard v == .squash || v == .fixup else { return false }

        // Walk back looking for a non-drop. If we find pick / squash /
        // fixup, this row has something to attach to. (squash/fixup
        // above means we're chaining into an existing absorption.)
        var i = idx - 1
        while i >= 0 {
            switch plan[i].verb {
            case .pick, .squash, .fixup: return true
            case .drop:                  i -= 1
            }
        }
        return false
    }

    /// For a `pick` row at `idx`, the count of squash/fixup rows below
    /// that will fold into it before the next pick. Drops are skipped
    /// (don't count, don't break the chain). Returns 0 for non-picks
    /// and for picks with nothing absorbing into them.
    static func absorbedCount(at idx: Int, in plan: [PlanItem]) -> Int {
        guard idx >= 0 && idx < plan.count else { return 0 }
        guard plan[idx].verb == .pick else { return 0 }

        var count = 0
        var i = idx + 1
        while i < plan.count {
            switch plan[i].verb {
            case .squash, .fixup: count += 1
            case .pick:           return count
            case .drop:           break    // skip, keep walking
            }
            i += 1
        }
        return count
    }
}
