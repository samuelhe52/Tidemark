//
//  UsageProxy.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/8.
//

import CFNetwork
import Foundation
import Network
import os

/// A routing failure contains no proxy URL: URLs can contain passwords.
enum UsageProxyError: Error { case unavailable }

/// The proxy address the user entered in settings, shared with the running requests.
///
/// Nil or empty means no explicit proxy. Held in memory only; the app saves the text itself.
public final class ProxyOverride: Sendable {
    private let stored: OSAllocatedUnfairLock<String?>

    public init(_ address: String? = nil) {
        stored = OSAllocatedUnfairLock(initialState: Self.trimmed(address))
    }

    public var address: String? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = Self.trimmed(newValue) } }
    }

    /// True for an address the settings field may keep: an HTTP(S) or SOCKS5 proxy without
    /// credentials, so no proxy password is saved in the clear.
    public static func isValid(_ address: String) -> Bool {
        (try? UsageProxy.explicitProxyURL(address)) != nil
    }

    private static func trimmed(_ address: String?) -> String? {
        let text = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

/// The proxy for live usage requests: the one set in Tidemark's settings, then the user's proxy
/// variables, then macOS proxy settings.
///
/// The variables are Tidemark's own when it was started with any (from a terminal), otherwise the
/// ones the user's interactive login shell sets, so a Dock launch routes like a terminal does.
/// The settings proxy sends every request through it, with no bypass list.
struct UsageProxy: Sendable {
    enum Route: Equatable, Sendable {
        case direct
        case proxy(URL)
        /// URLSession can evaluate system PAC; Claude Code cannot.
        case automatic
    }

    /// The proxy variable names, lowercase; each is also read and written uppercase.
    static let variableNames = ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]

    /// Proxy variables only, read on every operation, including renewals.
    var variables: @Sendable () async -> [String: String]
    var systemRoute: @Sendable (URL, Bool) throws -> Route = UsageProxy.systemRoute
    var systemExceptions: @Sendable () -> [String] = UsageProxy.systemExceptions
    /// The settings proxy, read on every operation.
    var override: @Sendable () -> String? = { nil }

    static func live(home: URL, override: ProxyOverride) -> UsageProxy {
        let shell = ShellProxyVariables(home: home)
        return UsageProxy(
            variables: {
                let own = proxyVariables(in: ProcessInfo.processInfo.environment)
                return own.isEmpty ? await shell.current() : own
            },
            override: { override.address })
    }

    /// The proxy variables in `environment`, or none when it names no proxy: a lone `NO_PROXY`
    /// does not hide the shell's proxies.
    static func proxyVariables(in environment: [String: String]) -> [String: String] {
        let keys = variableNames.flatMap { [$0, $0.uppercased()] }
        let found = environment.filter { keys.contains($0.key) && !$0.value.isEmpty }
        return found.keys.contains(where: { !$0.lowercased().hasPrefix("no_") }) ? found : [:]
    }

    func route(for target: URL) async throws -> Route {
        if let address = override() { return .proxy(try Self.explicitProxyURL(address)) }
        return try route(for: target, honorBypass: true, variables: await variables())
    }

    func route(for target: URL, honorBypass: Bool, variables env: [String: String]) throws -> Route {
        let explicit = variable("\(target.scheme ?? "https")_proxy", in: env) ?? variable("all_proxy", in: env)
        if let explicit {
            // Validate before applying bypasses: a broken setting must never become direct traffic.
            let proxy = try Self.proxyURL(explicit)
            if honorBypass, Self.bypasses(target, list: variable("no_proxy", in: env) ?? "") { return .direct }
            return .proxy(proxy)
        }
        return try systemRoute(target, honorBypass)
    }

    /// Resolve each scheme, then set both cases: Node and native clients differ in case precedence.
    ///
    /// Inherited proxy variables are replaced, so an explicit direct route cannot fall back to an
    /// inherited SOCKS proxy.
    func claudeEnvironment(_ original: [String: String]) async throws -> [String: String] {
        var result = original
        for key in Self.variableNames {
            result[key] = nil
            result[key.uppercased()] = nil
        }
        if let address = override() {
            // The user chose this proxy, so one Claude Code cannot use is an error, not a reason
            // to try another source.
            let url = try Self.explicitProxyURL(address)
            guard ["http", "https"].contains(url.scheme) else { throw UsageProxyError.unavailable }
            for key in ["http_proxy", "https_proxy"] {
                result[key] = url.absoluteString
                result[key.uppercased()] = url.absoluteString
            }
            result["NO_PROXY"] = ""
            result["no_proxy"] = ""
            return result
        }
        let env = await variables()
        var bypass = ""
        for scheme in ["http", "https"] {
            let (proxy, schemeBypass) = try claudeProxy(scheme: scheme, variables: env)
            result["\(scheme)_proxy"] = proxy?.absoluteString
            result["\(scheme.uppercased())_PROXY"] = proxy?.absoluteString
            // Claude Code's own traffic is HTTPS, so that route's source owns the bypass list.
            if scheme == "https" { bypass = schemeBypass }
        }
        result["NO_PROXY"] = bypass
        result["no_proxy"] = bypass
        return result
    }

    /// The HTTP(S) proxy Claude Code should use for `scheme` (nil for direct), with the bypass list
    /// of the source it came from.
    ///
    /// Claude Code accepts only HTTP(S) proxies, so a SOCKS variable yields to the next source,
    /// as a terminal's Claude Code would ignore it, instead of blocking the run. A malformed
    /// variable still fails, and so does a system route Claude Code cannot follow: there is no
    /// source left to try.
    private func claudeProxy(scheme: String, variables env: [String: String]) throws -> (URL?, String) {
        for key in ["\(scheme)_proxy", "all_proxy"] {
            guard let value = variable(key, in: env) else { continue }
            let url = try Self.proxyURL(value)
            if ["http", "https"].contains(url.scheme) { return (url, variable("no_proxy", in: env) ?? "") }
        }
        let exceptions = systemExceptions().joined(separator: ",")
        switch try systemRoute(URL(string: "\(scheme)://api.anthropic.com")!, false) {
        case .direct: return (nil, exceptions)
        case .proxy(let url) where ["http", "https"].contains(url.scheme): return (url, exceptions)
        case .proxy, .automatic: throw UsageProxyError.unavailable
        }
    }

    static func configure(_ configuration: URLSessionConfiguration, route: Route) throws {
        switch route {
        case .automatic: break  // Preserve URLSession's system PAC evaluation.
        case .direct: configuration.connectionProxyDictionary = [:]
        case .proxy(let url):
            guard let host = url.host, let number = UInt16(exactly: url.port ?? 0),
                let port = NWEndpoint.Port(rawValue: number)
            else {
                throw UsageProxyError.unavailable
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            var proxy: ProxyConfiguration
            if url.scheme == "socks5" || url.scheme == "socks5h" {
                proxy = ProxyConfiguration(socksv5Proxy: endpoint)
            } else {
                proxy = ProxyConfiguration(
                    httpCONNECTProxy: endpoint, tlsOptions: url.scheme == "https" ? NWProtocolTLS.Options() : nil)
            }
            proxy.allowFailover = false
            if let user = url.user {
                proxy.applyCredential(
                    username: user.removingPercentEncoding ?? user,
                    password: url.password?.removingPercentEncoding ?? url.password ?? "")
            }
            configuration.proxyConfigurations = [proxy]
        }
    }

    /// The settings proxy as a URL; a malformed one, or one with credentials, fails.
    static func explicitProxyURL(_ value: String) throws -> URL {
        let url = try proxyURL(value)
        guard url.user == nil, url.password == nil else { throw UsageProxyError.unavailable }
        return url
    }

    static func proxyURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = parts.scheme?.lowercased(), ["http", "https", "socks5", "socks5h"].contains(scheme),
            let host = parts.host, !host.isEmpty, parts.path.isEmpty || parts.path == "/",
            parts.query == nil, parts.fragment == nil
        else { throw UsageProxyError.unavailable }
        parts.scheme = scheme
        let port = parts.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 1080)
        guard (1...65535).contains(port) else { throw UsageProxyError.unavailable }
        parts.port = port
        guard let url = parts.url else { throw UsageProxyError.unavailable }
        return url
    }

    private func variable(_ key: String, in env: [String: String]) -> String? {
        env[key].nonEmpty ?? env[key.uppercased()].nonEmpty
    }

    /// Match Claude Code's proxy-from-env rules: exact hosts, explicit suffixes, ports, wildcard.
    static func bypasses(_ target: URL, list: String) -> Bool {
        guard let host = target.host?.lowercased() else { return false }
        let port = target.port ?? (target.scheme == "https" ? 443 : 80)
        return list.split(whereSeparator: { $0 == "," || $0.isWhitespace }).contains { entry in
            var name = String(entry).lowercased()
            if name == "*" { return true }
            // Do not interpret the colons within an IPv6 literal as a port separator.
            if let colon = name.lastIndex(of: ":"), !name[..<colon].contains(":"),
                let specifiedPort = Int(name[name.index(after: colon)...])
            {
                guard specifiedPort == port else { return false }
                name = String(name[..<colon])
            }
            if name.hasPrefix("*") {
                name.removeFirst()
                return host.hasSuffix(name)
            }
            if name.hasPrefix(".") { return host.hasSuffix(name) }
            return host == name
        }
    }

    static func systemRoute(for target: URL, honorBypass: Bool) throws -> Route {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            throw UsageProxyError.unavailable
        }
        let dictionary = NSMutableDictionary(dictionary: settings as NSDictionary)
        if !honorBypass {
            dictionary.removeObject(forKey: kCFNetworkProxiesExceptionsList as String)
            dictionary.removeObject(forKey: kCFNetworkProxiesExcludeSimpleHostnames as String)
        }
        return try systemRoute(for: target, settings: dictionary)
    }

    static func systemRoute(for target: URL, settings: NSDictionary) throws -> Route {
        let proxies = CFNetworkCopyProxiesForURL(target as CFURL, settings as CFDictionary).takeRetainedValue()
        guard let first = (proxies as? [[String: Any]])?.first,
            let type = first[kCFProxyTypeKey as String] as? String
        else { throw UsageProxyError.unavailable }
        switch type {
        case _ where type == (kCFProxyTypeNone as String): return .direct
        case _
        where type == (kCFProxyTypeAutoConfigurationURL as String)
            || type == (kCFProxyTypeAutoConfigurationJavaScript as String):
            return .automatic
        case _
        where type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String)
            || type == (kCFProxyTypeSOCKS as String):
            guard let host = first[kCFProxyHostNameKey as String] as? String,
                let port = first[kCFProxyPortNumberKey as String] as? Int
            else { throw UsageProxyError.unavailable }
            var parts = URLComponents()
            // CFProxyTypeHTTPS denotes CONNECT through an HTTP proxy, not TLS to the proxy.
            parts.scheme = type == (kCFProxyTypeSOCKS as String) ? "socks5" : "http"
            parts.host = host
            parts.port = port
            parts.user = first[kCFProxyUsernameKey as String] as? String
            parts.password = first[kCFProxyPasswordKey as String] as? String
            guard let value = parts.string else { throw UsageProxyError.unavailable }
            return .proxy(try proxyURL(value))
        default: throw UsageProxyError.unavailable
        }
    }

    static func systemExceptions() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return []
        }
        return settings[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
    }
}

/// The proxy variables the user's interactive login shell sets, read at most every five minutes.
///
/// A GUI app inherits none of them. A shell that fails or does not finish in time gives none,
/// and the system settings apply.
actor ShellProxyVariables {
    static let maximumAge: Duration = .seconds(300)

    private let home: URL
    private let shell: String
    private var cached: (at: ContinuousClock.Instant, variables: [String: String])?
    private var reading: Task<[String: String], Never>?

    init(home: URL, shell: String? = nil) {
        self.home = home
        self.shell = shell ?? ProcessInfo.processInfo.environment["SHELL"].nonEmpty ?? "/bin/zsh"
    }

    func current() async -> [String: String] {
        let clock = ContinuousClock()
        if let cached, clock.now - cached.at < Self.maximumAge { return cached.variables }
        // Concurrent requests share one shell run.
        if let reading { return await reading.value }
        let task = Task { [home, shell] in await Self.read(shell: shell, home: home) }
        reading = task
        let variables = await task.value
        cached = (clock.now, variables)
        reading = nil
        return variables
    }

    private static func read(shell: String, home: URL) async -> [String: String] {
        // The answer goes to a file, so nothing the startup files print can mix with it. The file
        // holds the whole environment briefly, so only this user can read it.
        let answer = FileManager.default.temporaryDirectory.appending(path: "tidemark-env-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: answer.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { return [:] }
        defer { try? FileManager.default.removeItem(at: answer) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive, so variables set in `.zshrc` count.
        process.arguments = ["-l", "-i", "-c", #"/usr/bin/env -0 > "$TIDEMARK_ANSWER""#]
        // Only what the startup files set counts.
        var environment = ProcessInfo.processInfo.environment
        for key in UsageProxy.variableNames {
            environment[key] = nil
            environment[key.uppercased()] = nil
        }
        environment["TIDEMARK_ANSWER"] = answer.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil,
            await ClaudeCLIUsageCommand.wait(for: process, timeout: ClaudeCLIUsageCommand.lookupTimeout),
            let data = try? LocalSources.bounded(answer, maximumBytes: 1024 * 1024)
        else { return [:] }
        return UsageProxy.proxyVariables(in: parse(data))
    }

    /// `env -0` output: NUL-terminated `NAME=value` entries; values may contain newlines.
    static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            result[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return result
    }
}
