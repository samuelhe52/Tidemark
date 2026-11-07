//
//  UsageService.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import CryptoKit
import Foundation

/// One place that turns local files, live answers and Tidemark's last-good store into usage.
///
/// Native sign-ins stay read-only. Managed CC Switch Codex accounts may renew their OAuth
/// tokens and write rotations back to the owner store; access tokens are cached in memory only.
/// Live Claude usage comes from Claude Code itself, which owns its token and its renewal.
public actor UsageService {
    private let environment: UsageEnvironment
    private let sources: LocalSources
    private let managedCredentials: ManagedCodexCredentials
    private var rejectedNativeTokens: [String: String] = [:]
    private let jitter: @Sendable () -> Double
    private var liveEnabled: Bool
    private var gate = LiveRequestGate()
    private var lastLive: [String: LiveOutcome] = [:]
    /// The native Codex Keychain read was refused; retried only when the user asks.
    private var codexKeychainRefused = false
    /// Codex's configured credential store, read once per refresh pass.
    private var codexStore = CodexCredentialStore.file
    private var lastCodexAccountID: String?
    /// The native Codex sign-in's user, kept with `lastCodexAccountID` for Keychain sign-ins.
    private var lastCodexIdentity: String?
    /// The signed-in Claude account and when Tidemark first saw it; statusline readings older
    /// than a switch belong to the previous account.
    private var claudeIdentity: (id: String, since: Date)?
    private var store: [String: StoredAccount]?
    private var inFlight: Task<[ServiceUsage], Never>?

    public init(environment: UsageEnvironment = .current, liveEnabled: Bool) {
        self.init(environment: environment, liveEnabled: liveEnabled, jitter: { Double.random(in: 0.8...1.2) })
    }

    init(environment: UsageEnvironment, liveEnabled: Bool, jitter: @escaping @Sendable () -> Double) {
        self.environment = environment
        self.sources = LocalSources(environment: environment)
        self.managedCredentials = ManagedCodexCredentials(environment: environment)
        self.liveEnabled = liveEnabled
        self.jitter = jitter
    }

    public func setLiveEnabled(_ enabled: Bool) async {
        liveEnabled = enabled
        if !enabled {
            rejectedNativeTokens.removeAll()
            await managedCredentials.clear()
        }
    }

    /// Coalesced: concurrent callers share one in-flight refresh. Passive files every call; live
    /// requests only when enabled and the account's gate allows.
    public func refresh(userInitiated: Bool) async -> [ServiceUsage] {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.performRefresh(userInitiated: userInitiated) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func performRefresh(userInitiated: Bool) async -> [ServiceUsage] {
        if userInitiated { codexKeychainRefused = false }
        if store == nil { store = SnapshotStore(url: environment.snapshotFile).load() }
        let before = store
        let claude = await claudeUsage(userInitiated: userInitiated)
        let codex = await codexUsage(userInitiated: userInitiated)
        if let store, store != before { SnapshotStore(url: environment.snapshotFile).save(store) }
        return [claude, codex]
    }

    // MARK: - Claude

    private func claudeUsage(userInitiated: Bool) async -> ServiceUsage {
        let file = sources.claudeFile()
        let identity = file.identity
        let id = AccountKey.claude(identity.accountUUID)
        var candidates: [Observation] = []
        if let cache = file.cache,
            cache.accountUUID == nil || identity.accountUUID == nil || cache.accountUUID == identity.accountUUID
        {
            candidates.append(Observation(windows: cache.windows, plan: identity.plan))
        }
        // The tap names no account. Trust it only for readings taken since this account was seen.
        if claudeIdentity?.id != id { claudeIdentity = (id, claudeIdentity == nil ? .distantPast : environment.now()) }
        let tap = Observation(windows: sources.claudeStatusline())
        if !tap.windows.isEmpty, tap.observedAt >= claudeIdentity?.since ?? .distantPast { candidates.append(tap) }
        let reading = await liveClaude(accountID: id, accountUUID: identity.accountUUID, userInitiated: userInitiated)
        let account = resolve(
            id: id, service: .claude, email: identity.email, isActive: true, candidates: candidates + reading.candidates,
            liveIssue: reading.issue, passiveIssue: file.issue)
        return ServiceUsage(service: .claude, accounts: [account])
    }

    // MARK: - Codex

    private func codexUsage(userInitiated: Bool) async -> ServiceUsage {
        codexStore = sources.codexCredentialStore()
        let managed = sources.managedCodexAccounts()
        await managedCredentials.retain(Set(managed.map(\.localID)))
        var activeID = lastCodexAccountID
        var identity = lastCodexIdentity
        if codexStore == .file {
            let auth = sources.codexAuthIdentity()
            activeID = auth.accountID
            identity = auth.userIdentity
        }
        // Resolve Keychain identity before choosing the account gate. Never read it in passive mode.
        if liveEnabled, codexStore != .file, let token = nativeCodexCredential() {
            activeID = token.accountID
            identity = token.userIdentity
            lastCodexAccountID = token.accountID
            lastCodexIdentity = token.userIdentity
        }
        activeID = activeID ?? sources.managedLiveCodexAccountID()
        let sameWorkspace = managed.filter { $0.chatGPTAccountID == activeID }
        let activeManaged =
            identity.flatMap { user in sameWorkspace.first { $0.userIdentity == user } }
            // A known native user never matches a managed account by workspace alone.
            ?? (identity == nil && sameWorkspace.count == 1 ? sameWorkspace.first : nil)
        var activeKey = activeManaged?.key ?? AccountKey.codex(activeID)

        // Old snapshots used workspace keys. Adopt only a unique mapping with a matching email;
        // a workspace-only observation could otherwise belong to an unmanaged user of that workspace.
        for account in managed {
            let oldKey = AccountKey.codex(account.chatGPTAccountID)
            if managed.filter({ $0.chatGPTAccountID == account.chatGPTAccountID }).count == 1,
                store?[account.key] == nil, let old = store?[oldKey], let email = old.email,
                email.caseInsensitiveCompare(account.email ?? "") == .orderedSame,
                !(activeID == account.chatGPTAccountID && identity != nil && account.userIdentity != nil
                    && activeManaged?.localID != account.localID)
            {
                store?[account.key] = old
                store?[oldKey] = nil
            }
        }
        var activeCandidates: [Observation] = []
        var activeIssue: QuotaReadIssue?
        if liveEnabled {
            let reading = await live(
                accountID: activeKey, userInitiated: userInitiated, managed: activeManaged, nativeAllowed: true)
            activeCandidates = reading.candidates
            activeIssue = reading.issue
            // A native credential may be the first source to reveal the workspace.
            if activeManaged == nil, let resolved = lastCodexAccountID { activeKey = AccountKey.codex(resolved) }
        }
        let rollout = sources.codexRollout()
        if let observed = rollout.windows.first?.observedAt,
            observed >= (sources.codexAuthModified() ?? .distantPast),
            sameWorkspace.count <= 1 || activeManaged != nil
        {
            activeCandidates.append(Observation(windows: rollout.windows))
        }
        var accounts = [
            resolve(
                id: activeKey, service: .codex, email: activeManaged?.email, isActive: true,
                candidates: activeCandidates, liveIssue: activeIssue, passiveIssue: rollout.issue)
        ]
        for account in managed where account.localID != activeManaged?.localID {
            let reading = await live(accountID: account.key, userInitiated: userInitiated, managed: account)
            accounts.append(
                resolve(
                    id: account.key, service: .codex, email: account.email, isActive: false,
                    candidates: reading.candidates, liveIssue: reading.issue, passiveIssue: .notObserved))
        }
        // Accounts removed while a renewal was in flight must disappear in this result too.
        let remaining = Set(sources.managedCodexAccounts().map(\.key))
        accounts.removeAll { !$0.isActive && !remaining.contains($0.id) }
        let others = accounts.dropFirst().sorted { ($0.email ?? $0.id) < ($1.email ?? $1.id) }
        return ServiceUsage(service: .codex, accounts: [accounts[0]] + others)
    }

    // MARK: - Choosing an observation

    /// Picks the newest observation among the candidates and the stored one, and records it.
    private func resolve(
        id: String, service: QuotaService, email: String?, isActive: Bool, candidates: [Observation],
        liveIssue: QuotaReadIssue?, passiveIssue: QuotaReadIssue?
    ) -> AccountUsage {
        // A reading dated in the future (the clock was ahead) would outrank every real one until
        // the clock caught up, so it is never chosen and never kept.
        let latest = environment.now().addingTimeInterval(300)
        if let stored = store?[id], stored.observedAt > latest { store?[id] = nil }
        let stored = store?[id]
        let newest = candidates.filter { $0.observedAt <= latest }.max { $0.observedAt < $1.observedAt }
        let email = newest?.email ?? email ?? stored?.email
        let plan = newest?.plan ?? stored?.plan
        if let newest, newest.observedAt > (stored?.observedAt ?? .distantPast) {
            store?[id] = StoredAccount(email: email, plan: plan, windows: newest.windows)
        }
        let windows = store?[id]?.windows ?? []
        let issue = liveIssue ?? (windows.isEmpty ? passiveIssue ?? .missing : nil)
        return AccountUsage(
            id: id, service: service, email: email, plan: plan, isActive: isActive, windows: windows, issue: issue)
    }

    // MARK: - Live requests

    private static let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private enum LiveOutcome {
        case observed(Observation)
        case failed(QuotaReadIssue)
    }

    /// What a live attempt contributes to an account: an observation, an issue, or neither.
    private struct LiveReading {
        var observation: Observation?
        var issue: QuotaReadIssue?

        init(_ outcome: LiveOutcome?) {
            switch outcome {
            case .observed(let observation)?: self.observation = observation
            case .failed(let issue)?: self.issue = issue
            case nil: break
            }
        }

        var candidates: [Observation] { observation.map { [$0] } ?? [] }
    }

    private enum CredentialResult {
        case token(AccessToken)
        case failed(QuotaReadIssue)
    }

    private struct AccessToken {
        let value: String
        let expiry: Date?
        var accountID: String?
        var userIdentity: String?
    }

    /// Asks Claude Code to refresh its usage cache when live usage is on and the account's gate
    /// allows, then accepts the cache only if it was refreshed for this account; otherwise repeats
    /// the last outcome for this account.
    private func liveClaude(accountID: String, accountUUID: String?, userInitiated: Bool) async -> LiveReading {
        guard liveEnabled else { return LiveReading(nil) }
        let now = environment.now()
        guard gate.allows(accountID, now: now, userInitiated: userInitiated) else {
            return LiveReading(lastLive[accountID])
        }
        let outcome: LiveOutcome
        if let accountUUID {
            switch await environment.claudeUsage.run() {
            case .unavailable: outcome = fail(.cliUnavailable, key: accountID, now: now).0
            case .timedOut: outcome = fail(.requestFailed, key: accountID, now: now).0
            case .finished:
                // A cache older than the run means Claude Code could not refresh it, for
                // example because its sign-in needs renewing.
                let file = sources.claudeFile()
                if file.identity.accountUUID == accountUUID, let cache = file.cache, cache.accountUUID == accountUUID,
                    let fetched = cache.windows.first?.observedAt, fetched >= now.addingTimeInterval(-5)
                {
                    gate.recordSuccess(accountID, now: now)
                    outcome = .observed(Observation(windows: cache.windows, plan: file.identity.plan))
                } else {
                    outcome = fail(.requestFailed, key: accountID, now: now).0
                }
            }
        } else {
            outcome = fail(.signedOut, key: accountID, now: now).0
        }
        lastLive[accountID] = outcome
        return LiveReading(outcome)
    }

    /// Sends one Codex live request when live usage is on and the account's gate allows;
    /// otherwise repeats the last outcome for this account.
    private func live(
        accountID: String, userInitiated: Bool, managed: LocalSources.ManagedCodexAccount? = nil,
        nativeAllowed: Bool = false
    ) async -> LiveReading {
        guard liveEnabled else { return LiveReading(nil) }
        let now = environment.now()
        guard managed != nil || !codexKeychainRefused,
            gate.allows(accountID, now: now, userInitiated: userInitiated)
        else { return LiveReading(lastLive[accountID]) }
        let (outcome, key) = await request(accountID: accountID, now: now, managed: managed, nativeAllowed: nativeAllowed)
        lastLive[key] = outcome
        return LiveReading(outcome)
    }

    /// Returns the outcome and the account key it was recorded under: a Codex token can name a
    /// different account than the caller expected, and its gate and outcome belong to that account.
    private func request(
        accountID: String, now: Date, managed: LocalSources.ManagedCodexAccount?, nativeAllowed: Bool
    ) async -> (LiveOutcome, String) {
        let credential: CredentialResult
        var usedNative = false
        if let managed {
            if nativeAllowed, let native = nativeCredential(serving: managed, now: now) {
                credential = .token(native)
                usedNative = true
            } else {
                do {
                    let token = try await managedCredentials.token(for: managed)
                    credential = .token(
                        AccessToken(value: token.value, expiry: token.expiry, accountID: token.workspace))
                } catch {
                    let failure = error as? ManagedCredentialError ?? ManagedCredentialError(issue: .requestFailed)
                    return fail(failure.issue, key: accountID, now: now, retryAfter: failure.retryAfter)
                }
            }
        } else {
            credential = codexCredential()
        }
        guard liveEnabled else {
            await managedCredentials.clear()
            return (.failed(.requestFailed), accountID)
        }
        let token: AccessToken
        switch credential {
        case .token(let value): token = value
        case .failed(let issue):
            if issue == .accessDenied, managed == nil { codexKeychainRefused = true }
            return fail(issue, key: accountID, now: now)
        }
        var key = accountID
        if managed == nil, let resolved = token.accountID {
            lastCodexAccountID = resolved
            lastCodexIdentity = token.userIdentity
            key = AccountKey.codex(resolved)
        }
        if let expiry = token.expiry, expiry <= now.addingTimeInterval(60) {
            gate.recordExpiredCredential(key, now: now)
            return (.failed(.credentialExpired), key)
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await environment.transport.data(for: Self.usageRequest(token: token))
        } catch {
            return fail(.requestFailed, key: key, now: now)
        }
        switch response.statusCode {
        case 200..<300:
            guard let observation = observation(data: data), !observation.windows.isEmpty
            else { return fail(.requestFailed, key: key, now: now) }
            gate.recordSuccess(key, now: now)
            return (.observed(observation), key)
        case 401, 403:
            if let managed {
                if usedNative {
                    rejectedNativeTokens[managed.localID] = token.value
                } else {
                    await managedCredentials.invalidate(managed.localID)
                }
            }
            return fail(.accessDenied, key: key, now: now)
        case 429:
            let retry = LiveRequestGate.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
            return fail(.rateLimited, key: key, now: now, retryAfter: retry)
        default:
            return fail(.requestFailed, key: key, now: now)
        }
    }

    /// Records the failure against the account's gate.
    private func fail(
        _ issue: QuotaReadIssue, key: String, now: Date, retryAfter: TimeInterval? = nil
    ) -> (LiveOutcome, String) {
        gate.recordFailure(key, now: now, retryAfter: retryAfter, jitter: jitter())
        return (.failed(issue), key)
    }

    private static func usageRequest(token: AccessToken) -> URLRequest {
        var request = URLRequest(url: codexUsageURL)
        if let account = token.accountID { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    /// The usage answer as an observation; nil when it is not a usage object.
    private func observation(data: Data) -> Observation? {
        QuotaParser.codexUsage(data, observedAt: environment.now()).map {
            Observation(windows: $0.windows, email: $0.email, plan: $0.plan)
        }
    }

    // MARK: - Credentials (read-only)

    /// The native Codex sign-in, unless a Keychain read was refused; a refusal is remembered
    /// until the user asks to retry, so a denied prompt never reappears on its own.
    private func nativeCodexCredential() -> AccessToken? {
        guard !codexKeychainRefused else { return nil }
        switch codexCredential() {
        case .token(let token): return token
        case .failed(let issue):
            if issue == .accessDenied { codexKeychainRefused = true }
            return nil
        }
    }

    /// The native sign-in when it may serve `managed`. A known native user never serves a managed
    /// account whose user is unknown or different.
    private func nativeCredential(serving managed: LocalSources.ManagedCodexAccount, now: Date) -> AccessToken? {
        guard let native = nativeCodexCredential(),
            native.accountID == managed.chatGPTAccountID,
            native.userIdentity == managed.userIdentity,
            native.expiry.map({ $0 > now.addingTimeInterval(60) }) ?? true,
            rejectedNativeTokens[managed.localID] != native.value
        else { return nil }
        return native
    }

    /// Codex's sign-in from the store its configuration names: `auth.json`, the Keychain, or both.
    private func codexCredential() -> CredentialResult {
        var data: Data?
        if codexStore.usesKeychain {
            do {
                data = try environment.credentials.genericPassword(
                    service: "Codex Auth", account: codexKeychainAccount())
            } catch {
                return .failed(.accessDenied)
            }
        }
        if data == nil, codexStore.mayUseFile {
            data = try? LocalSources.bounded(environment.codexAuthFile, maximumBytes: 1024 * 1024)
        }
        guard let data, let root = QuotaParser.object(data) else { return .failed(.signedOut) }
        guard (root["auth_mode"] as? String).map({ $0.lowercased() == "chatgpt" }) ?? true,
            let tokenFields = root["tokens"] as? [String: Any],
            let value = tokenFields["access_token"] as? String, !value.isEmpty
        else { return .failed(.signedOut) }
        return .token(
            AccessToken(
                value: value, expiry: QuotaParser.tokenExpiry(value), accountID: tokenFields["account_id"] as? String,
                userIdentity: (tokenFields["id_token"] as? String).flatMap(QuotaParser.tokenIdentity)))
    }

    /// `cli|<first 16 hex of SHA-256(codex home)>`, the account Codex files its Keychain item under.
    private func codexKeychainAccount() -> String {
        var path = environment.codexHome.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cli|\(digest.prefix(16))"
    }
}

/// One reading: windows that were observed together, with the identity it reported.
struct Observation: Equatable {
    var windows: [QuotaWindow]
    var email: String? = nil
    var plan: String? = nil

    var observedAt: Date { windows.map(\.observedAt).max() ?? .distantPast }
}
