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
        try runImpl(args: args, env: env, stdin: nil)
    }

    /// Run git with stdin piped in from a string. Used by the
    /// split-commit engine to feed reassembled patches into
    /// `git apply --cached`, which reads its patch from stdin when
    /// no file argument is given.
    func runWithStdin(_ args: [String], stdin: String, env: [String: String] = [:]) throws -> Result {
        try runImpl(args: args, env: env, stdin: stdin)
    }

    private func runImpl(args: [String], env: [String: String], stdin: String?) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = cwd
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        if stdin != nil {
            process.standardInput = inPipe
        }
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Write stdin (if any), then close so the child sees EOF.
        if let s = stdin, let data = s.data(using: .utf8) {
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                // Child may have already closed its stdin (e.g. invalid
                // patch — git rejects it before reading the whole thing).
                // Ignore broken-pipe errors; the actual failure surfaces
                // via stderr + non-zero exit below.
            }
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain pipes before waiting to avoid deadlock on >64KB output
        // (`git show` on a big commit can fill the buffer).
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
