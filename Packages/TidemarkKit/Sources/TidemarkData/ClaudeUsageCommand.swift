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
    private let locator: CLILocator

    init(home: URL, proxy: UsageProxy) {
        self.home = home
        self.proxy = proxy
        locator = CLILocator(
            name: "claude", home: home,
            homePaths: [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude"])
    }

    static let timeout: Duration = .seconds(45)

    /// No tools, MCP servers, settings (so no user hooks), or saved session.
    static let arguments = [
        "-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
        "--no-session-persistence"
    ]

    func run() async -> ClaudeUsageRun {
        guard let executable = await locator.locate(retryMiss: true) else { return .unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments
        do { process.environment = try await environment(for: executable) } catch { return .proxyUnavailable }
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable }
        guard await CLIProcess.wait(for: process, timeout: Self.timeout) else { return .timedOut }
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
        environment["PATH"] = CLILocator.searchPath(for: executable, inherited: environment["PATH"])
        return environment
    }
}
