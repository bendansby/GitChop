import Foundation

/// Thin wrapper around invoking /usr/bin/git as a subprocess.
///
/// We intentionally shell out rather than use libgit2: rebase semantics
/// are subtle and `git` is the source of truth for them. libgit2's
/// `git_rebase_*` family covers the common cases but lags behind
/// upstream git on edge cases (e.g. rebase merges, autosquash semantics).
struct GitRunner {
    let cwd: URL

    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        var isSuccess: Bool { exitCode == 0 }
    }

    /// Run git with the given args. Optional env overrides are merged on
    /// top of the current process environment (so PATH etc. survive).
    func run(_ args: [String], env: [String: String] = [:]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = cwd
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Drain pipes before waiting to avoid deadlock on >64KB output
        // (especially `git show` on a big commit can fill the buffer).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
