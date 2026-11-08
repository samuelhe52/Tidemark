//
//  UsageProxyTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/8.
//

import CFNetwork
import Foundation
import SQLite3
import Testing

@testable import TidemarkData

struct UsageProxyTests {
    private let quota = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let renewal = URL(string: "https://auth.openai.com/oauth/token")!

    @Test func precedenceAndBypassesApplyToQuotaAndRenewal() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var proxy = UsageProxy(
            ccSwitchHome: directory,
            environment: { ["https_proxy": "http://lowercase:8001", "HTTPS_PROXY": "http://uppercase:8002"] },
            systemRoute: { _, _ in .proxy(URL(string: "http://system:8003")!) })
        for target in [quota, renewal] {
            #expect(try proxy.route(for: target) == .proxy(URL(string: "http://lowercase:8001")!))
        }
        try writeProxy("http://cc-switch:8004", in: directory)
        for target in [quota, renewal] {
            #expect(try proxy.route(for: target) == .proxy(URL(string: "http://cc-switch:8004")!))
        }
        proxy.environment = { ["NO_PROXY": ".openai.com:443,chatgpt.com"] }
        #expect(try proxy.route(for: quota) == .direct)
        #expect(try proxy.route(for: renewal) == .direct)
        #expect(!UsageProxy.bypasses(URL(string: "https://notopenai.com")!, list: ".openai.com"))
        #expect(!UsageProxy.bypasses(renewal, list: ".openai.com:80"))
        #expect(!UsageProxy.bypasses(renewal, list: "openai.com"))
        #expect(!UsageProxy.bypasses(URL(string: "https://openai.com")!, list: "*.openai.com"))
        #expect(UsageProxy.bypasses(renewal, list: "*"))
    }

    @Test func guiClaudeGetsSystemHTTPProxyAndClearsAuthenticationSelectors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = UsageProxy(
            ccSwitchHome: directory,
            environment: {
                [
                    "PATH": "/usr/bin:/bin", "ANTHROPIC_CUSTOM_HEADERS": "test", "CLAUDE_CODE_USE_FOUNDRY": "1",
                    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": "test", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/other"
                ]
            },
            systemRoute: { _, _ in .proxy(URL(string: "http://127.0.0.1:7890")!) },
            systemExceptions: { ["localhost", "*.local"] })
        let env = try ClaudeCLIUsageCommand(home: directory, proxy: proxy).environment(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
        #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:7890")
        #expect(env["https_proxy"] == env["HTTPS_PROXY"])
        #expect(env["HTTP_PROXY"] == env["HTTPS_PROXY"])
        #expect(env["no_proxy"] == "localhost,*.local")
        for key in [
            "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR"
        ] {
            #expect(env[key] == nil)
        }
    }

    @Test func invalidOrUnsupportedProxyNeverBecomesDirect() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for value in ["not-a-url", "http://proxy:0", "http://proxy:65536", "ftp://proxy:80"] {
            let proxy = UsageProxy(ccSwitchHome: directory, environment: { ["HTTPS_PROXY": value, "NO_PROXY": "*"] })
            #expect(throws: UsageProxyError.self) { try proxy.route(for: quota) }
        }
        let socks = UsageProxy(
            ccSwitchHome: directory, environment: { ["ALL_PROXY": "socks5://127.0.0.1:1080"] })
        #expect(try socks.route(for: renewal) == .proxy(URL(string: "socks5://127.0.0.1:1080")!))
        #expect(throws: UsageProxyError.self) { try socks.claudeEnvironment([:]) }
        let pac = UsageProxy(ccSwitchHome: directory, environment: { [:] }, systemRoute: { _, _ in .automatic })
        #expect(try pac.route(for: quota) == .automatic)
        #expect(throws: UsageProxyError.self) { try pac.claudeEnvironment([:]) }
    }

    @Test func systemSelectionPreservesExceptionsAndChangesWithoutRestart() throws {
        let settings: NSDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: 7890,
            kCFNetworkProxiesExceptionsList as String: ["*.openai.com"]
        ]
        #expect(
            try UsageProxy.systemRoute(for: quota, settings: settings) == .proxy(URL(string: "http://127.0.0.1:7890")!))
        #expect(try UsageProxy.systemRoute(for: renewal, settings: settings) == .direct)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = UsageProxy(ccSwitchHome: directory, environment: { [:] }, systemRoute: { _, _ in .direct })
        #expect(try proxy.route(for: quota) == .direct)
        try writeProxy("http://one:7890", in: directory)
        #expect(try proxy.route(for: quota) == .proxy(URL(string: "http://one:7890")!))
        try writeProxy("http://two:7891", in: directory)
        #expect(try proxy.route(for: quota) == .proxy(URL(string: "http://two:7891")!))
    }

    @Test func nativeTransportUsesProxyForBothVendorHosts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [
            "-u", "-c",
            #"""
            import socket
            s=socket.socket();s.bind(('127.0.0.1',0));s.listen();s.settimeout(10)
            print(s.getsockname()[1],flush=True)
            for _ in range(2):
                c,_=s.accept();c.settimeout(5);data=c.recv(8192)
                print(data.split(b'\r\n')[0].decode(),flush=True)
                c.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');c.close()
            """#
        ]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let reader = output.fileHandleForReading
        let port = try #require(Int(readLine(reader)))
        let proxy = UsageProxy(ccSwitchHome: directory, environment: { ["HTTPS_PROXY": "http://127.0.0.1:\(port)"] })
        let transport = URLSessionTransport(proxy: proxy)
        for target in [quota, renewal] {
            do {
                var request = URLRequest(url: target)
                if target == renewal { request.httpMethod = "POST" }
                _ = try await transport.data(for: request)
                Issue.record("The rejecting proxy should fail the request")
            } catch {}
            #expect(readLine(reader) == "CONNECT \(target.host!):443 HTTP/1.1")
        }
    }

    @Test func claudeNonzeroExitIsPreserved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appending(path: "claude")
        try Data("#!/bin/sh\nexit 17\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let proxy = UsageProxy(ccSwitchHome: directory, environment: { [:] }, systemRoute: { _, _ in .direct })
        #expect(await ClaudeCLIUsageCommand(home: directory, proxy: proxy).run() == .failed(exitCode: 17))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tidemark-proxy-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeProxy(_ value: String, in directory: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.appending(path: "cc-switch.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(
            sqlite3_exec(
                database, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil)
                == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(
                database, "INSERT OR REPLACE INTO settings VALUES ('global_proxy_url', ?1)", -1, &statement, nil)
                == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        _ = value.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }

    private func readLine(_ handle: FileHandle) -> String {
        var line = Data()
        while let byte = try? handle.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 { break }
            line.append(byte)
        }
        return String(decoding: line, as: UTF8.self)
    }
}
