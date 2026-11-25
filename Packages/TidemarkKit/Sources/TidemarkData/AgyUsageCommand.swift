//
//  AgyUsageCommand.swift
//  Tidemark
//
//  Created by Antigravity on behalf of Samuel He on 2026/11/26.
//

import Foundation
import Synchronization

/// How a request to the Antigravity CLI (`agy`) for quota ended.
public enum AgyUsageRun: Equatable, Sendable {
    /// The command exited 0; `output` is the bounded stdout JSON payload, if readable.
    case finished(Data?)
    /// No `agy` executable could be found or started.
    case unavailable
    /// The command did not exit in time and was stopped.
    case timedOut
    /// The process exited unsuccessfully; `output` is kept only long enough to classify JSON errors.
    case failed(exitCode: Int32, output: Data?)
    /// The selected proxy cannot be used by `agy`.
    case proxyUnavailable
}

/// Asks the Antigravity CLI (`agy`) for the signed-in account's plan quota.
///
/// `agy` answers `/usage` itself, without a model turn or saved conversation, and owns its
/// own credentials and token renewal. Tidemark never reads Google or Antigravity credentials.
public protocol AgyUsageCommand: Sendable {
    /// True when `agy` exists at a known install path or was already located by the login shell.
    var isInstalled: Bool { get }
    func run() async -> AgyUsageRun
}

/// Runs `agy -p /usage --output-format json --log-file /dev/null --print-timeout 40s`.
struct AgyCLIUsageCommand: AgyUsageCommand {
    let home: URL
    private let proxy: UsageProxy
    /// Where the login shell found `agy`, so the user's startup files run once, not on every run.
    private let shellFound = AgyShellAnswer()

    init(home: URL, proxy: UsageProxy) {
        self.home = home
        self.proxy = proxy
    }

    static let timeout: Duration = .seconds(45)
    static let lookupTimeout: Duration = .seconds(10)
    static let maximumOutputBytes = 256 * 1024

    /// Zero-turn JSON quota query; `--log-file /dev/null` keeps periodic polls from creating log files.
    static let arguments = [
        "-p", "/usage", "--output-format", "json", "--log-file", "/dev/null", "--print-timeout", "40s"
    ]

    private var knownPaths: [String] {
        [".local/bin/agy", ".gemini/antigravity-cli/bin/agy"].map { home.appending(path: $0).path }
            + ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
    }

    var isInstalled: Bool {
        if knownPaths.contains(where: FileManager.default.isExecutableFile(atPath:)) { return true }
        if let cached = shellFound.path.withLock({ $0 }), FileManager.default.isExecutableFile(atPath: cached.path) {
            return true
        }
        return false
    }

    func run() async -> AgyUsageRun {
        guard let executable = await locate() else { return .unavailable }
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "tidemark-agy-\(UUID().uuidString)")
        guard
            FileManager.default.createFile(
                atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
            let outputHandle = try? FileHandle(forWritingTo: outputURL)
        else { return .unavailable }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments
        do { process.environment = try await environment(for: executable) } catch {
            try? outputHandle.close()
            return .proxyUnavailable
        }
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            try? outputHandle.close()
            return .unavailable
        }
        let completed = await ClaudeCLIUsageCommand.wait(for: process, timeout: Self.timeout)
        try? outputHandle.close()
        guard completed else { return .timedOut }
        let data = try? LocalSources.bounded(outputURL, maximumBytes: Self.maximumOutputBytes)
        return process.terminationStatus == 0
            ? .finished(data) : .failed(exitCode: process.terminationStatus, output: data)
    }

    func environment(for executable: URL) async throws -> [String: String] {
        var environment = try await proxy.agyEnvironment(ProcessInfo.processInfo.environment)
        let directories = [
            executable.deletingLastPathComponent().path,
            executable.resolvingSymlinksInPath().deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin"
        ]
        let path = environment["PATH"].nonEmpty ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (directories + [path]).joined(separator: ":")
        return environment
    }

    private func locate() async -> URL? {
        if let found = knownPaths.first(where: FileManager.default.isExecutableFile(atPath:)) {
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
        let answer = FileManager.default.temporaryDirectory.appending(path: "tidemark-agy-which-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: answer) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", #"command -v agy > "$TIDEMARK_ANSWER""#]
        var environment = ProcessInfo.processInfo.environment
        environment["TIDEMARK_ANSWER"] = answer.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil,
            await ClaudeCLIUsageCommand.wait(for: process, timeout: Self.lookupTimeout),
            let data = try? LocalSources.bounded(answer, maximumBytes: 4096)
        else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Shared by every copy of the command, so a path found once is reused.
fileprivate final class AgyShellAnswer: Sendable {
    let path = Mutex<URL?>(nil)
}
