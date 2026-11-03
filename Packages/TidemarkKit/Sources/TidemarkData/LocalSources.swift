//
//  LocalSources.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// Reads the files other tools write. Every file is opened read-only, and only quota and
/// identity fields are kept. Managed ID tokens are decoded only for user identity hints.
struct LocalSources {
    let environment: UsageEnvironment

    struct ClaudeIdentity: Equatable {
        var accountUUID: String?
        var email: String?
    }

    struct ClaudeFile {
        var identity = ClaudeIdentity()
        var cache: QuotaParser.ClaudeCache?
        var issue: QuotaReadIssue?
    }

    /// `~/.claude.json`: the signed-in account and Claude Code's own usage cache.
    func claudeFile() -> ClaudeFile {
        let url = environment.home.appending(path: ".claude.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ClaudeFile(issue: .missing) }
        guard let data = try? Self.bounded(url, maximumBytes: 8 * 1024 * 1024) else {
            return ClaudeFile(issue: .unreadable)
        }
        var file = ClaudeFile()
        if let account = QuotaParser.object(data)?["oauthAccount"] as? [String: Any] {
            file.identity = ClaudeIdentity(
                accountUUID: account["accountUuid"] as? String, email: account["emailAddress"] as? String)
        }
        file.cache = QuotaParser.claudeCache(data)
        if file.cache == nil { file.issue = .unrecognized }
        return file
    }

    /// The optional statusline tap, which reports what the running Claude Code last learned.
    func claudeStatusline() -> [QuotaWindow] {
        let url = environment.supportDirectory.appending(path: "claude-rate-limits.json")
        guard let data = try? Self.bounded(url, maximumBytes: 1024 * 1024) else { return [] }
        return QuotaParser.claudeStatusline(data)
    }

    /// Newest `token_count.rate_limits` in the newest rollout, from a bounded tail only.
    func codexRollout() -> (windows: [QuotaWindow], issue: QuotaReadIssue?) {
        let manager = FileManager.default
        let sessions = environment.codexHome.appending(path: "sessions")
        guard manager.fileExists(atPath: sessions.path) else { return ([], .missing) }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let enumerator = manager.enumerator(
                at: sessions, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return ([], .unreadable) }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true, let date = values.contentModificationDate
            else { continue }
            if newest.map({ date > $0.date }) ?? true { newest = (url, date) }
        }
        guard let url = newest?.url else { return ([], .missing) }
        do {
            // One bounded tail, 400 lines at most. Never scan conversation bodies from the start.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let window: UInt64 = 512 * 1024
            let offset = size > window ? size - window : 0
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(window)) ?? Data()
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            let marker = Data("\"rate_limits\"".utf8)
            for line in lines.suffix(400).reversed() where line.range(of: marker) != nil {
                let windows = QuotaParser.codexEvent(Data(line))
                if !windows.isEmpty { return (windows, nil) }
            }
            return ([], .unrecognized)
        } catch {
            return ([], .unreadable)
        }
    }

    /// When `auth.json` last changed: CC Switch rewrites it when it switches accounts, so a rollout
    /// event older than this may belong to the previous account. Metadata only.
    func codexAuthModified() -> Date? {
        let url = environment.codexHome.appending(path: "auth.json")
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The ChatGPT account `auth.json` is signed in with. Only `tokens.account_id` is decoded.
    func codexAuthAccountID() -> String? {
        struct Auth: Decodable {
            struct Tokens: Decodable { let account_id: String? }
            let tokens: Tokens?
        }
        let url = environment.codexHome.appending(path: "auth.json")
        guard let data = try? Self.bounded(url, maximumBytes: 1024 * 1024) else { return nil }
        return (try? JSONDecoder().decode(Auth.self, from: data))?.tokens?.account_id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Codex's configured credential store: `file` (the default), `keyring` or `auto`.
    func codexCredentialStore() -> String {
        let url = environment.codexHome.appending(path: "config.toml")
        guard let data = try? Self.bounded(url, maximumBytes: 1024 * 1024),
            let text = String(data: data, encoding: .utf8)
        else { return "file" }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }  // Only top-level keys apply.
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store"
            else { continue }
            let value = parts[1].split(separator: "#").first ?? ""
            return value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return "file"
    }

    struct ManagedCodexAccount: Equatable, Sendable {
        let localID: String
        let chatGPTAccountID: String
        let email: String?
        let userIdentity: String?

        var key: String { "codex:managed:\(localID)" }
    }

    /// CC Switch's managed Codex account identities.
    func managedCodexAccounts() -> [ManagedCodexAccount] {
        struct Store: Decodable {
            struct Account: Decodable {
                let chatgptAccountId: String?
                let email: String?
                let idToken: String?
            }
            let accounts: [String: Account]?
        }
        let url = environment.ccSwitchHome.appending(path: "codex_oauth_auth.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Self.bounded(url, maximumBytes: 4 * 1024 * 1024),
            let store = try? decoder.decode(Store.self, from: data)
        else { return [] }
        return (store.accounts ?? [:]).compactMap { localID, account in
            guard !localID.isEmpty, let id = account.chatgptAccountId, !id.isEmpty else { return nil }
            return ManagedCodexAccount(
                localID: localID, chatGPTAccountID: id, email: account.email,
                userIdentity: account.idToken.flatMap(QuotaParser.tokenIdentity))
        }.sorted { $0.localID < $1.localID }
    }

    func codexAuthUserIdentity() -> String? {
        struct Auth: Decodable {
            struct Tokens: Decodable { let idToken: String? }
            let tokens: Tokens?
        }
        let url = environment.codexHome.appending(path: "auth.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Self.bounded(url, maximumBytes: 1024 * 1024) else { return nil }
        return (try? decoder.decode(Auth.self, from: data))?.tokens?.idToken.flatMap(QuotaParser.tokenIdentity)
    }

    /// The account CC Switch last made live for Codex, from its identity marker (no secrets).
    func managedLiveCodexAccountID() -> String? {
        struct Marker: Decodable { let chatgpt_account_id: String? }
        let url = environment.ccSwitchHome.appending(path: "codex_managed_oauth_live_auth.json")
        guard let data = try? Self.bounded(url, maximumBytes: 64 * 1024) else { return nil }
        return (try? JSONDecoder().decode(Marker.self, from: data))?.chatgpt_account_id
    }

    static func bounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
