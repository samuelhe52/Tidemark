//
//  ClaudeUsageCommand.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/7.
//

import Foundation
import Synchronization

/// How a request to Claude Code to refresh its usage cache ended.
public enum ClaudeUsageRun: Equatable, Sendable {
    /// The command exited; the cache may or may not have been refreshed.
    case finished
    /// No `claude` executable could be found or started.
    case unavailable
    /// The command did not exit in time and was stopped.
    case timedOut
    /// The process exited unsuccessfully; raw output is never retained.
    case failed(exitCode: Int32)
    /// The selected proxy cannot be used by Claude Code.
    case proxyUnavailable
}

/// Asks Claude Code to refresh `cachedUsageUtilization` in `~/.claude.json`.
///
/// Claude Code answers `/usage` itself, without a model turn, and renews its own token
/// under its own lock when needed. Tidemark never touches Claude's credentials.
public protocol ClaudeUsageCommand: Sendable {
    func run() async -> ClaudeUsageRun
}

/// Runs `claude -p /usage` in the default config directory, the way CC Switch does.
struct ClaudeCLIUsageCommand: ClaudeUsageCommand {
    let home: URL
    private let proxy: UsageProxy
    /// Where the login shell found `claude`, so the user's startup files run once, not on every run.
    private let shellFound = ShellAnswer()

    init(home: URL, proxy: UsageProxy) {
        self.home = home
        self.proxy = proxy
    }

    static let timeout: Duration = .seconds(45)
    static let lookupTimeout: Duration = .seconds(10)

    /// No tools, MCP servers, settings (so no user hooks), or saved session.
    static let arguments = [
        "-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
        "--no-session-persistence"
    ]

    func run() async -> ClaudeUsageRun {
        guard let executable = await locate() else { return .unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments
        do { process.environment = try await environment(for: executable) } catch { return .proxyUnavailable }
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable }
        guard await Self.wait(for: process, timeout: Self.timeout) else { return .timedOut }
        return process.terminationStatus == 0 ? .finished : .failed(exitCode: process.terminationStatus)
    }

    /// The environment for the run: the account comes from Claude Code's own sign-in only, and
    /// `/usage` must be allowed to reach the network.
    func environment(for executable: URL) async throws -> [String: String] {
        var environment = try await proxy.claudeEnvironment(ProcessInfo.processInfo.environment)
        for key in Array(environment.keys)
        where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_USE_") {
            environment[key] = nil
        }
        for key in [
            "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
            // Inherited when Tidemark is started from a Claude Code session or a cloud setup.
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
            "CLAUDE_CODE_OAUTH_SCOPES", "CLAUDE_SECURESTORAGE_CONFIG_DIR"
        ] {
            environment[key] = nil
        }
        for key in [
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER"
        ] {
            environment[key] = "1"
        }
        // A Node install's `claude` runs `env node`, which sits beside it.
        let directories = [
            executable.deletingLastPathComponent().path,
            executable.resolvingSymlinksInPath().deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin"
        ]
        let path = environment["PATH"].nonEmpty ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (directories + [path]).joined(separator: ":")
        return environment
    }

    /// Known install locations first; a GUI app's `PATH` rarely includes them. Then the user's
    /// login shell, which knows where they installed it. The shell's answer is kept while it
    /// stays executable.
    private func locate() async -> URL? {
        let candidates =
            [
                ".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude"
            ].map { home.appending(path: $0).path } + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        if let cached = shellFound.path.withLock({ $0 }), FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }
        let found = await shellLookup()
        shellFound.path.withLock { $0 = found }
        return found
    }

    private func shellLookup() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].nonEmpty ?? "/bin/zsh"
        // The answer goes to a file, so nothing the startup files print can mix with it or fill a pipe.
        let answer = FileManager.default.temporaryDirectory.appending(path: "tidemark-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: answer) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive, so paths added in `.zshrc` count.
        process.arguments = ["-l", "-i", "-c", #"command -v claude > "$TIDEMARK_ANSWER""#]
        var environment = ProcessInfo.processInfo.environment
        environment["TIDEMARK_ANSWER"] = answer.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil, await Self.wait(for: process, timeout: Self.lookupTimeout),
            let data = try? LocalSources.bounded(answer, maximumBytes: 4096)
        else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

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

/// Shared by every copy of the command, so a path found once is reused.
fileprivate final class ShellAnswer: Sendable {
    let path = Mutex<URL?>(nil)
}
