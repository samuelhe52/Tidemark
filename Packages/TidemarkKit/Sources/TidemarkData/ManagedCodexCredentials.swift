//
//  ManagedCodexCredentials.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Darwin
import Foundation

struct ManagedCodexToken: Sendable {
    let value: String
    let expiry: Date
    let workspace: String
}

struct ManagedCredentialError: Error {
    let issue: QuotaReadIssue
    var retryAfter: TimeInterval? = nil
}

/// CC Switch CLI's OAuth flow, without its database or a second persistent access-token store.
///
/// Reload before renewing and before committing. The file lock serializes Tidemark processes;
/// CC Switch does not honor it, so its in-memory refresh-token races remain possible.
actor ManagedCodexCredentials {
    private struct Generation: Equatable {
        let refresh: String
        let idToken: String?
        let updated: Double?
        let workspace: String
    }

    private struct Cached {
        let token: ManagedCodexToken
        let generation: Generation
    }

    private struct Rotation {
        let before: Generation
        let refresh: String?
        let idToken: String?
        let updated: Double
        let token: ManagedCodexToken
    }

    private let environment: UsageEnvironment
    private let write: @Sendable (Data, URL) throws -> Void
    private var cache: [String: Cached] = [:]
    /// Keep an unsaved rotation in memory so a transient write failure never replays its spent token.
    private var pending: [String: Rotation] = [:]
    private var url: URL { environment.ccSwitchHome.appending(path: "codex_oauth_auth.json") }

    init(
        environment: UsageEnvironment,
        write: @escaping @Sendable (Data, URL) throws -> Void = ManagedCodexCredentials.secureWrite
    ) {
        self.environment = environment
        self.write = write
    }

    func clear() { cache.removeAll() }

    func invalidate(_ localID: String) { cache[localID] = nil }

    func retain(_ localIDs: Set<String>) {
        cache = cache.filter { localIDs.contains($0.key) }
        pending = pending.filter { localIDs.contains($0.key) }
    }

    func token(for account: LocalSources.ManagedCodexAccount) async throws
        -> ManagedCodexToken
    {
        let initial = try generation(in: read(), for: account)
        if let cached = cache[account.localID], cached.generation == initial,
            cached.token.expiry > environment.now().addingTimeInterval(60)
        {
            return cached.token
        }
        cache[account.localID] = nil
        // Nonblocking: a second Tidemark process backs off instead of waiting on a network call.
        let lock = try renewalLock()
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        if let rotation = pending[account.localID] {
            let committed = try commit(rotation, for: account)
            pending[account.localID] = nil
            try validate(rotation.token)
            cache[account.localID] = Cached(token: rotation.token, generation: committed)
            return rotation.token
        }
        var generation = try generation(in: read(), for: account)
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            let fields = [
                ("grant_type", "refresh_token"), ("refresh_token", generation.refresh),
                ("client_id", "app_EMoamEEZ73f0CkXaXp7hrann"), ("scope", "openid profile email")
            ]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(
                fields.map { key, value in
                    "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
                }.joined(separator: "&").utf8)
            request.timeoutInterval = 15
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await environment.transport.data(for: request) } catch {
                throw ManagedCredentialError(issue: .requestFailed)
            }

            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 429 {
                    throw ManagedCredentialError(
                        issue: .rateLimited,
                        retryAfter: LiveRequestGate.retryAfter(
                            response.value(forHTTPHeaderField: "Retry-After"), now: environment.now()))
                }
                // Another owner may have advanced the disk generation while this request ran.
                let latest = try self.generation(in: read(), for: account)
                if attempt == 0, latest != generation {
                    generation = latest
                    continue
                }
                let error = QuotaParser.object(data)?["error"]
                let code = (error as? [String: Any])?["code"] as? String ?? error as? String
                let expired = [
                    "invalid_grant", "refresh_token_reused", "refresh_token_expired", "refresh_token_invalidated"
                ]
                .contains(code ?? "")
                throw ManagedCredentialError(
                    issue: expired || [400, 401, 403].contains(response.statusCode)
                        ? .credentialExpired : .requestFailed)
            }
            guard let body = QuotaParser.object(data), let value = body["access_token"] as? String, !value.isEmpty
            else {
                throw ManagedCredentialError(issue: .requestFailed)
            }
            let now = environment.now()
            let seconds = QuotaParser.number(body["expires_in"]).flatMap { $0 > 0 && $0 < 1e9 ? $0 : nil } ?? 3600
            let expiry = QuotaParser.tokenExpiry(value) ?? now.addingTimeInterval(seconds)
            // Save rotations before deciding whether the returned access token is usable.
            let token = ManagedCodexToken(value: value, expiry: expiry, workspace: account.chatGPTAccountID)
            let rotation = Rotation(
                before: generation,
                refresh: (body["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                idToken: (body["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                updated: (now.timeIntervalSince1970 * 1000).rounded(.down), token: token)
            pending[account.localID] = rotation
            let committed = try commit(rotation, for: account)
            pending[account.localID] = nil
            try validate(token)
            cache[account.localID] = Cached(token: token, generation: committed)
            return token
        }
        throw ManagedCredentialError(issue: .credentialChanged)
    }

    private func validate(_ token: ManagedCodexToken) throws {
        guard token.expiry > environment.now().addingTimeInterval(60),
            QuotaParser.tokenWorkspace(token.value).map({ $0 == token.workspace }) ?? true
        else { throw ManagedCredentialError(issue: .credentialExpired) }
    }

    private func commit(_ rotation: Rotation, for account: LocalSources.ManagedCodexAccount) throws -> Generation {
        var root = try read()
        let current = try generation(in: root, for: account)
        let after = Generation(
            refresh: rotation.refresh ?? rotation.before.refresh,
            idToken: rotation.idToken ?? rotation.before.idToken,
            updated: rotation.updated, workspace: rotation.before.workspace)
        if current == after { return after }
        guard current == rotation.before else {
            pending[account.localID] = nil
            throw ManagedCredentialError(issue: .credentialChanged)
        }
        var accounts = root["accounts"] as! [String: Any]
        var row = accounts[account.localID] as! [String: Any]
        row["refresh_token"] = after.refresh
        if let idToken = after.idToken { row["id_token"] = idToken }
        // CC Switch declares this field `i64`; a fractional value makes its whole store unreadable.
        row["token_updated_at_ms"] = after.updated.map { NSNumber(value: Int64($0)) }
        accounts[account.localID] = row
        root["accounts"] = accounts
        do { try write(JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), url) } catch {
            throw ManagedCredentialError(issue: .credentialSaveFailed)
        }
        return after
    }

    private func read() throws -> [String: Any] {
        guard let data = try? LocalSources.bounded(url, maximumBytes: 4 * 1024 * 1024),
            let root = QuotaParser.object(data), QuotaParser.number(root["version"]) == 2
        else { throw ManagedCredentialError(issue: .unreadable) }
        return root
    }

    private func generation(in root: [String: Any], for account: LocalSources.ManagedCodexAccount) throws -> Generation
    {
        guard let accounts = root["accounts"] as? [String: Any], let row = accounts[account.localID] as? [String: Any],
            let refresh = row["refresh_token"] as? String, !refresh.isEmpty,
            let workspace = row["chatgpt_account_id"] as? String, workspace == account.chatGPTAccountID,
            (row["account_id"] as? String).map({ $0 == account.localID }) ?? true
        else { throw ManagedCredentialError(issue: .signedOut) }
        return Generation(
            refresh: refresh, idToken: row["id_token"] as? String,
            updated: QuotaParser.number(row["token_updated_at_ms"]), workspace: workspace)
    }

    private func renewalLock() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: environment.supportDirectory, withIntermediateDirectories: true)
        } catch { throw ManagedCredentialError(issue: .credentialSaveFailed) }
        let path = environment.supportDirectory.appending(path: "managed-codex-renewal.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagedCredentialError(issue: .credentialSaveFailed) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ManagedCredentialError(issue: .credentialChanged)
        }
        return descriptor
    }

    /// A same-directory, mode-0600 temporary file: credentials are never briefly world-readable.
    static func secureWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".tidemark-oauth-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
