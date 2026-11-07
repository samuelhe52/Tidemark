//
//  ClaudeUsageCommand.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/7.
//

import Foundation

/// How a request to Claude Code to refresh its usage cache ended.
public enum ClaudeUsageRun: Equatable, Sendable {
    /// The command exited; the cache may or may not have been refreshed.
    case finished
    /// No `claude` executable could be found or started.
    case unavailable
    /// The command did not exit in time and was stopped.
    case timedOut
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
        process.environment = environment(for: executable)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable }
        return await Self.wait(for: process, timeout: Self.timeout) ? .finished : .timedOut
    }

    /// The environment for the run: the account comes from Claude Code's own sign-in only, and
    /// `/usage` must be allowed to reach the network.
    private func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"
        ] {
            environment[key] = nil
        }
        for key in ["CLAUDE_CODE_DISABLE_AUTO_MEMORY", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER"]
        {
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
    /// login shell, which knows where they installed it.
    private func locate() async -> URL? {
        let candidates = [
            ".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude"
        ].map { home.appending(path: $0).path } + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        return await shellLookup()
    }

    private func shellLookup() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].nonEmpty ?? "/bin/zsh"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive, so paths added in `.zshrc` count. A marker separates the answer from
        // anything the shell's startup files print.
        process.arguments = ["-l", "-i", "-c", "printf '\\n__tidemark__%s\\n' \"$(command -v claude)\""]
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil, await Self.wait(for: process, timeout: Self.lookupTimeout) else {
            return nil
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .last { $0.hasPrefix("__tidemark__") }?.dropFirst("__tidemark__".count)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: String(path)) else {
            return nil
        }
        return URL(fileURLWithPath: String(path))
    }

    /// Whether the process exited within `timeout`; otherwise it is terminated, then killed.
    private static func wait(for process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning {
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
