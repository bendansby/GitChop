import SwiftUI
import AppKit

/// Top-level application state: a list of open repo sessions (tabs) and
/// the currently active one. Persists the open-repo paths to
/// UserDefaults so the tab set survives quit-and-relaunch.
///
/// Persistence model: just absolute paths. We're not sandboxed, so we
/// don't need security-scoped bookmarks. If a path no longer resolves
/// (repo moved or deleted) we silently skip it on restore.
@MainActor
final class Workspace: ObservableObject {
    @Published var sessions: [RebaseSession] = []
    @Published var activeSessionID: UUID?

    /// UserDefaults key holding `[String]` of absolute repo paths in
    /// tab order. Versioned in case the schema ever changes.
    private let storageKey = "GitChopOpenRepos.v1"

    init() {
        restoreFromDefaults()
    }

    /// The session for the currently-selected tab, if any.
    var activeSession: RebaseSession? {
        sessions.first(where: { $0.id == activeSessionID })
    }

    // MARK: - Open

    func openPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Pick a git repository."
        if panel.runModal() == .OK, let url = panel.url {
            openRepo(url)
        }
    }

    /// Open a repo at `url`. If it's already open in some tab, just
    /// switch to that tab — opening the same repo twice would be
    /// confusing and gives two parallel rebase plans for the same SHA
    /// space.
    func openRepo(_ url: URL) {
        let resolved = url.standardizedFileURL
        if let existing = sessions.first(where: {
            $0.repoURL?.standardizedFileURL.path == resolved.path
        }) {
            activeSessionID = existing.id
            return
        }
        let session = RebaseSession(repoURL: resolved)
        sessions.append(session)
        activeSessionID = session.id
        persist()
    }

    // MARK: - Tab actions

    func setActive(_ id: UUID) {
        activeSessionID = id
    }

    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: idx)
        if activeSessionID == id {
            // Prefer the tab to the right; fall back to the new last one.
            activeSessionID = sessions[safe: idx]?.id
                ?? sessions.last?.id
        }
        persist()
    }

    func closeActive() {
        guard let id = activeSessionID else { return }
        close(id)
    }

    /// Move a tab from one index to another. Used when we add
    /// drag-reorder later — wired up now so the persistence picks up
    /// the new order automatically.
    func moveTab(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let paths = sessions.compactMap { $0.repoURL?.path }
        UserDefaults.standard.set(paths, forKey: storageKey)
    }

    private func restoreFromDefaults() {
        guard let paths = UserDefaults.standard.stringArray(forKey: storageKey) else { return }
        let fm = FileManager.default
        for path in paths {
            // Skip paths that no longer resolve to a directory (repo
            // was moved/deleted while the app was closed). Don't
            // surface errors here — just quietly drop them so the
            // user isn't greeted with a wall of "couldn't open" alerts.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let url = URL(fileURLWithPath: path)
            sessions.append(RebaseSession(repoURL: url))
        }
        activeSessionID = sessions.last?.id
        // Re-persist in case some entries were dropped — keeps the on-
        // disk list in sync with what we actually have open.
        if sessions.count != paths.count {
            persist()
        }
    }
}

// MARK: - Helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
