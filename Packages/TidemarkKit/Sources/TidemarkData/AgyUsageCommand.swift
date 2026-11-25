//
//  AgyUsageCommand.swift
//  Tidemark
//
//  Created by Antigravity on behalf of Samuel He on 2026/11/26.
//

import Foundation

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
    /// Whether `agy` can be found. The login shell is asked only with `allowShellLookup`, and a
    /// miss is kept until `retryMiss`, so refreshes do not repeatedly start a shell.
    func isInstalled(allowShellLookup: Bool, retryMiss: Bool) async -> Bool
    func run() async -> AgyUsageRun
}

/// Runs `agy -p /usage --output-format json --log-file /dev/null --print-timeout 40s`.
struct AgyCLIUsageCommand: AgyUsageCommand {
    let home: URL
    private let proxy: UsageProxy
    private let locator: CLILocator

    init(home: URL, proxy: UsageProxy, locator: CLILocator? = nil) {
        self.home = home
        self.proxy = proxy
        self.locator = locator ?? CLILocator(name: "agy", home: home, homePaths: Self.homePaths)
    }

    static let homePaths = [".local/bin/agy", ".gemini/antigravity-cli/bin/agy"]
    static let timeout: Duration = .seconds(45)
    static let maximumOutputBytes = 256 * 1024

    /// Zero-turn JSON quota query; `--log-file /dev/null` keeps periodic polls from creating log files.
    static let arguments = [
        "-p", "/usage", "--output-format", "json", "--log-file", "/dev/null", "--print-timeout", "40s"
    ]

    func isInstalled(allowShellLookup: Bool, retryMiss: Bool) async -> Bool {
        await locator.locate(allowShellLookup: allowShellLookup, retryMiss: retryMiss) != nil
    }

    func run() async -> AgyUsageRun {
        guard let executable = await locator.locate(retryMiss: false) else { return .unavailable }
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
        let completed = await CLIProcess.wait(for: process, timeout: Self.timeout)
        try? outputHandle.close()
        guard completed else { return .timedOut }
        let data = try? LocalSources.bounded(outputURL, maximumBytes: Self.maximumOutputBytes)
        return process.terminationStatus == 0
            ? .finished(data) : .failed(exitCode: process.terminationStatus, output: data)
    }

    func environment(for executable: URL) async throws -> [String: String] {
        var environment = try await proxy.agyEnvironment(ProcessInfo.processInfo.environment)
        environment["PATH"] = CLILocator.searchPath(for: executable, inherited: environment["PATH"])
        return environment
    }
}
