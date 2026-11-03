//
//  UsageEnvironment.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import Security

/// Reads generic-password items. Tidemark never adds, changes or deletes one.
public protocol CredentialStore: Sendable {
    /// Returns the item's data, or nil when it does not exist. Throws when access is denied or cancelled.
    func genericPassword(service: String, account: String?) throws -> Data?
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Where Tidemark looks, and how it reaches credentials and the network.
public struct UsageEnvironment: Sendable {
    public var home: URL
    public var codexHome: URL
    public var ccSwitchHome: URL
    /// Tidemark's own directory; the last-good store and the statusline tap live here.
    public var supportDirectory: URL
    public var credentials: any CredentialStore
    public var transport: any HTTPTransport
    public var now: @Sendable () -> Date

    public init(
        home: URL, codexHome: URL, ccSwitchHome: URL, supportDirectory: URL, credentials: any CredentialStore,
        transport: any HTTPTransport, now: @escaping @Sendable () -> Date
    ) {
        self.home = home
        self.codexHome = codexHome
        self.ccSwitchHome = ccSwitchHome
        self.supportDirectory = supportDirectory
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// The real paths (honoring `$CODEX_HOME`), the login Keychain, and an uncached URL session.
    public static var current: UsageEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        return UsageEnvironment(
            home: home, codexHome: codexHome ?? home.appending(path: ".codex"),
            ccSwitchHome: home.appending(path: ".cc-switch"),
            supportDirectory: home.appending(path: "Library/Application Support/Tidemark"),
            credentials: KeychainCredentialStore(), transport: URLSessionTransport.shared, now: { Date() })
    }
}

struct CredentialAccessError: Error {
    let status: OSStatus
}

struct KeychainCredentialStore: CredentialStore {
    func genericPassword(service: String, account: String?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw CredentialAccessError(status: status)
        }
    }
}

final class URLSessionTransport: HTTPTransport {
    static let shared = URLSessionTransport()
    private let session: URLSession

    private init() {
        // No disk or memory cache and no cookies: answers are read once and dropped.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
