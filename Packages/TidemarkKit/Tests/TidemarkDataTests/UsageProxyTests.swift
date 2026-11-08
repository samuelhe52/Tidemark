//
//  UsageProxyTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/8.
//

import CFNetwork
import Foundation
import Testing

@testable import TidemarkData

struct UsageProxyTests {
    private let quota = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let renewal = URL(string: "https://auth.openai.com/oauth/token")!

    @Test func precedenceAndBypassesApplyToQuotaAndRenewal() async throws {
        var proxy = UsageProxy(
            variables: { ["https_proxy": "http://lowercase:8001", "HTTPS_PROXY": "http://uppercase:8002"] },
            systemRoute: { _, _ in .proxy(URL(string: "http://system:8003")!) })
        for target in [quota, renewal] {
            #expect(try await proxy.route(for: target) == .proxy(URL(string: "http://lowercase:8001")!))
        }
        proxy.variables = { [:] }
        #expect(try await proxy.route(for: quota) == .proxy(URL(string: "http://system:8003")!))
        proxy.variables = { ["ALL_PROXY": "http://all:8004", "NO_PROXY": ".openai.com:443,chatgpt.com"] }
        #expect(try await proxy.route(for: quota) == .direct)
        #expect(try await proxy.route(for: renewal) == .direct)
        #expect(!UsageProxy.bypasses(URL(string: "https://notopenai.com")!, list: ".openai.com"))
        #expect(!UsageProxy.bypasses(renewal, list: ".openai.com:80"))
        #expect(!UsageProxy.bypasses(renewal, list: "openai.com"))
        #expect(!UsageProxy.bypasses(URL(string: "https://openai.com")!, list: "*.openai.com"))
        #expect(UsageProxy.bypasses(renewal, list: "*"))
    }

    /// Tidemark's own variables win only when they name a proxy; otherwise the shell's apply.
    @Test func ownVariablesNeedAProxyToHideTheShells() {
        #expect(UsageProxy.proxyVariables(in: ["NO_PROXY": "localhost", "PATH": "/bin"]).isEmpty)
        #expect(UsageProxy.proxyVariables(in: ["HTTPS_PROXY": ""]).isEmpty)
        #expect(
            UsageProxy.proxyVariables(in: ["https_proxy": "http://p:1", "no_proxy": "x", "PATH": "/bin"])
                == ["https_proxy": "http://p:1", "no_proxy": "x"])
    }

    @Test func loginShellVariablesAreReadOnceAndFiltered() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = directory.appending(path: "runs")
        // Called as `shell -l -i -c COMMAND`; startup output must not reach the answer.
        let shell = try executable(
            in: directory, name: "fake-shell",
            """
            #!/bin/sh
            echo run >> "\(count.path)"
            echo "welcome banner"
            export https_proxy='http://shell:7890' NO_PROXY='localhost' SECRET_TOKEN='do-not-keep'
            exec /bin/sh -c "$4"
            """)
        let reader = ShellProxyVariables(home: directory, shell: shell.path)
        async let first = reader.current()
        async let second = reader.current()
        let expected = ["https_proxy": "http://shell:7890", "NO_PROXY": "localhost"]
        #expect(await first == expected)
        #expect(await second == expected)
        #expect(await reader.current() == expected)
        #expect(try String(contentsOf: count, encoding: .utf8) == "run\n")
    }

    @Test func failingShellGivesNoVariables() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = try executable(in: directory, name: "broken-shell", "#!/bin/sh\nexit 1\n")
        #expect(await ShellProxyVariables(home: directory, shell: shell.path).current().isEmpty)
    }

    @Test func guiClaudeGetsSystemHTTPProxyAndClearsAuthenticationSelectors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = UsageProxy(
            variables: { [:] },
            systemRoute: { _, _ in .proxy(URL(string: "http://127.0.0.1:7890")!) },
            systemExceptions: { ["localhost", "*.local"] })
        let original = [
            "PATH": "/usr/bin:/bin", "ANTHROPIC_CUSTOM_HEADERS": "test", "CLAUDE_CODE_USE_FOUNDRY": "1",
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": "test", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/other",
            "ALL_PROXY": "socks5://127.0.0.1:1080"
        ]
        let env = try await proxy.claudeEnvironment(original)
        #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:7890")
        #expect(env["https_proxy"] == env["HTTPS_PROXY"])
        #expect(env["HTTP_PROXY"] == env["HTTPS_PROXY"])
        #expect(env["no_proxy"] == "localhost,*.local")
        #expect(env["ALL_PROXY"] == nil)
        let command = try await ClaudeCLIUsageCommand(home: directory, proxy: proxy).environment(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
        for key in ["ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] {
            #expect(command[key] == nil)
        }
    }

    @Test func invalidOrUnsupportedProxyNeverBecomesDirect() async throws {
        for value in ["not-a-url", "http://proxy:0", "http://proxy:65536", "ftp://proxy:80"] {
            let proxy = UsageProxy(variables: { ["HTTPS_PROXY": value, "NO_PROXY": "*"] })
            await #expect(throws: UsageProxyError.self) { try await proxy.route(for: quota) }
        }
        let socks = UsageProxy(variables: { ["ALL_PROXY": "socks5://127.0.0.1:1080"] })
        #expect(try await socks.route(for: renewal) == .proxy(URL(string: "socks5://127.0.0.1:1080")!))
        let pac = UsageProxy(variables: { [:] }, systemRoute: { _, _ in .automatic })
        #expect(try await pac.route(for: quota) == .automatic)
        await #expect(throws: UsageProxyError.self) { try await pac.claudeEnvironment([:]) }
    }

    @Test func systemSelectionPreservesExceptions() throws {
        let settings: NSDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: 7890,
            kCFNetworkProxiesExceptionsList as String: ["*.openai.com"]
        ]
        #expect(
            try UsageProxy.systemRoute(for: quota, settings: settings) == .proxy(URL(string: "http://127.0.0.1:7890")!))
        #expect(try UsageProxy.systemRoute(for: renewal, settings: settings) == .direct)
    }

    @Test func nativeTransportUsesProxyForBothVendorHosts() async throws {
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
        let proxy = UsageProxy(variables: { ["HTTPS_PROXY": "http://127.0.0.1:\(port)"] })
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
        _ = try executable(in: bin, name: "claude", "#!/bin/sh\nexit 17\n")
        let proxy = UsageProxy(variables: { [:] }, systemRoute: { _, _ in .direct })
        #expect(await ClaudeCLIUsageCommand(home: directory, proxy: proxy).run() == .failed(exitCode: 17))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tidemark-proxy-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(in directory: URL, name: String, _ script: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
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
