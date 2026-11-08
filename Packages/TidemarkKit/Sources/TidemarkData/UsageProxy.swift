//
//  UsageProxy.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/8.
//

import CFNetwork
import Foundation
import Network
import SQLite3

/// A routing failure contains no proxy URL: URLs can contain passwords.
enum UsageProxyError: Error { case unavailable }

struct UsageProxy: Sendable {
    enum Route: Equatable, Sendable {
        case direct
        case proxy(URL)
        /// URLSession can evaluate system PAC; Claude Code cannot.
        case automatic
    }

    let ccSwitchHome: URL
    var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    var systemRoute: @Sendable (URL, Bool) throws -> Route = UsageProxy.systemRoute
    var systemExceptions: @Sendable () -> [String] = UsageProxy.systemExceptions

    /// Read on every operation, including renewals.
    ///
    /// No cached session pins an old network route.
    func route(for target: URL, honorBypass: Bool = true) throws -> Route {
        let env = environment()
        let configured = try ccSwitchProxy()
        let explicit =
            configured ?? variable("\(target.scheme ?? "https")_proxy", in: env)
            ?? variable("all_proxy", in: env)
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
    /// ALL_PROXY is removed so an explicit direct route cannot fall back to an inherited SOCKS proxy.
    func claudeEnvironment(_ original: [String: String]) throws -> [String: String] {
        var result = original
        for key in ["ALL_PROXY", "all_proxy"] { result[key] = nil }
        for scheme in ["http", "https"] {
            let route = try route(for: URL(string: "\(scheme)://api.anthropic.com")!, honorBypass: false)
            let value: String?
            switch route {
            case .direct: value = nil
            case .proxy(let url):
                guard ["http", "https"].contains(url.scheme) else { throw UsageProxyError.unavailable }
                value = url.absoluteString
            case .automatic: throw UsageProxyError.unavailable
            }
            result["\(scheme)_proxy"] = value
            result["\(scheme.uppercased())_PROXY"] = value
        }
        let env = environment()
        let hasExplicitProxy =
            try ccSwitchProxy() != nil || variable("https_proxy", in: env) != nil
            || variable("all_proxy", in: env) != nil
        let bypass = hasExplicitProxy ? variable("no_proxy", in: env) ?? "" : systemExceptions().joined(separator: ",")
        result["NO_PROXY"] = bypass
        result["no_proxy"] = bypass
        return result
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

    private func ccSwitchProxy() throws -> String? {
        let file = ccSwitchHome.appending(path: "cc-switch.db")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw UsageProxyError.unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT value FROM settings WHERE key = 'global_proxy_url'", -1, &statement, nil) == SQLITE_OK
        else { throw UsageProxyError.unavailable }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let value = sqlite3_column_text(statement, 0) else { return nil }
            let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        default: throw UsageProxyError.unavailable
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
