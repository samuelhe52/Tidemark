//
//  CLILocator.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/26.
//

import Foundation
import Synchronization

/// Finds one command-line tool: known install paths first (a GUI app's `PATH` rarely includes
/// them), then the user's login shell. Copies share the shell's answer.
struct CLILocator: Sendable {
    let name: String
    let home: URL
    private let knownPaths: [String]
    private let shell: String?
    private let cache = ShellAnswer()

    /// `homePaths` are relative to `home`.
    init(
        name: String, home: URL, homePaths: [String], systemDirectories: [String] = Self.systemDirectories,
        shell: String? = nil
    ) {
        self.name = name
        self.home = home
        self.shell = shell
        knownPaths =
            homePaths.map { home.appending(path: $0).path } + systemDirectories.map { "\($0)/\(name)" }
    }

    static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The executable, or nil. A path the shell found is kept while it stays executable; a miss is
    /// kept until `retryMiss`. The shell runs only with `allowShellLookup`.
    func locate(allowShellLookup: Bool = true, retryMiss: Bool) async -> URL? {
        if let found = knownPaths.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        let cached = cache.state.withLock { state in
            if let path = state.path, !FileManager.default.isExecutableFile(atPath: path.path) {
                state = .init()
            }
            return state
        }
        if let path = cached.path { return path }
        guard allowShellLookup, !cached.checked || retryMiss else { return nil }
        let found = await shellLookup()
        cache.state.withLock { $0 = .init(path: found, checked: true) }
        return found
    }

    /// `PATH` for running `executable`: a Node install runs `env node`, which sits beside it.
    static func searchPath(for executable: URL, inherited: String?) -> String {
        let directories =
            [
                executable.deletingLastPathComponent().path,
                executable.resolvingSymlinksInPath().deletingLastPathComponent().path
            ] + systemDirectories
        return (directories + [inherited.nonEmpty ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
    }

    private func shellLookup() async -> URL? {
        let shell = self.shell ?? ProcessInfo.processInfo.environment["SHELL"].nonEmpty ?? "/bin/zsh"
        // The answer goes to a file, so nothing the startup files print can mix with it or fill a pipe.
        let answer = FileManager.default.temporaryDirectory.appending(path: "tidemark-\(name)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: answer) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive, so paths added in `.zshrc` count.
        process.arguments = ["-l", "-i", "-c", "command -v \(name) > \"$TIDEMARK_ANSWER\""]
        var environment = ProcessInfo.processInfo.environment
        environment["TIDEMARK_ANSWER"] = answer.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil,
            await CLIProcess.wait(for: process, timeout: CLIProcess.shellTimeout),
            let data = try? LocalSources.bounded(answer, maximumBytes: 4096)
        else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum CLIProcess {
    /// Longest a login shell may take to answer.
    static let shellTimeout: Duration = .seconds(10)

    /// Whether the process exited within `timeout`; otherwise it is terminated, then killed. A
    /// cancelled task terminates it at once rather than spinning, since its sleeps no longer wait.
    static func wait(for process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                return false
            }
            guard clock.now < deadline else {
                process.terminate()
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

fileprivate final class ShellAnswer: Sendable {
    struct State: Sendable {
        var path: URL?
        var checked = false
    }

    let state = Mutex<State>(State())
}
