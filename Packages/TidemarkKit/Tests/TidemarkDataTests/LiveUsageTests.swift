//
//  LiveUsageTests.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import Security
import Testing

@testable import TidemarkData

struct LiveUsageTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    @Test func liveOffNeverReadsCredentialsOrSendsRequests() async throws {
        let fixture = try Fixture()
        try fixture.write(Fixture.codexAuth(token: Fixture.jwt(expiry: now + 3600)), to: ".codex/auth.json")
        try fixture.write(Fixture.managed(["acct-a", "acct-b"]), to: ".cc-switch/codex_oauth_auth.json")
        try fixture.write(#"{"chatgpt_account_id":"acct-b"}"#, to: ".cc-switch/codex_managed_oauth_live_auth.json")
        let services = await fixture.service(live: false, now: now).refresh(userInitiated: true)
        #expect(fixture.credentials.reads.isEmpty)
        #expect(fixture.transport.requests.isEmpty)
        #expect(fixture.claudeUsage.runs == 0)
        // `auth.json` names acct-a, so CC Switch's older marker for acct-b does not decide.
        let codex = try #require(services.last?.accounts)
        #expect(codex.map(\.id) == ["codex:managed:local-0", "codex:managed:local-1"])
        #expect(codex.map(\.isActive) == [true, false])
        #expect(codex.last?.issue == .notObserved)
    }

    @Test func claudeLiveRunsClaudeCodeAndNeverReadsItsCredentials() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(Fixture.claudeState(account: "A", fetchedAt: now - 86400, used: 10), to: ".claude.json")
        fixture.claudeUsage.respond = { [fixture] in
            _ = try? fixture.write(
                Fixture.claudeState(account: "A", fetchedAt: clock.now, used: 21, plan: "claude_max"),
                to: ".claude.json")
            return .finished
        }
        let service = fixture.service(live: true, clock: clock)
        let account = try #require(await service.refresh(userInitiated: false).first?.accounts.first)
        #expect(account.issue == nil && account.plan == "max")
        #expect(account.windows.first?.usedPercent == 21)
        #expect(!fixture.credentials.reads.contains { $0.hasPrefix("Claude") })
        #expect(!fixture.transport.requests.contains { $0.url?.host == "api.anthropic.com" })
        // The gate still limits runs.
        clock.now = now + 60
        _ = await service.refresh(userInitiated: false)
        #expect(fixture.claudeUsage.runs == 1)
    }

    @Test func currentClaudeCacheIsUsedWithoutRunningClaudeCode() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(Fixture.claudeState(account: "A", fetchedAt: now - 30, used: 42), to: ".claude.json")
        let service = fixture.service(live: true, clock: clock)
        let account = try #require(await service.refresh(userInitiated: true).first?.accounts.first)
        #expect(account.issue == nil && account.windows.first?.usedPercent == 42)
        #expect(fixture.claudeUsage.runs == 0)
    }

    @Test func cacheOneMinuteOldIsNotCurrentSoClaudeCodeIsAsked() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(Fixture.claudeState(account: "A", fetchedAt: now - 60, used: 42), to: ".claude.json")
        fixture.claudeUsage.respond = { .finished }
        let account = try #require(
            await fixture.service(live: true, clock: clock).refresh(userInitiated: true).first?.accounts.first)
        #expect(account.issue == .requestFailed)
        #expect(fixture.claudeUsage.runs == 1)
    }

    @Test func claudeCacheThatDidNotRefreshOrNamesAnotherAccountIsAFailure() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(Fixture.claudeState(account: "A", fetchedAt: now - 86400, used: 10), to: ".claude.json")
        fixture.claudeUsage.respond = { .finished }
        let service = fixture.service(live: true, clock: clock)
        let stale = try #require(await service.refresh(userInitiated: true).first?.accounts.first)
        #expect(stale.issue == .requestFailed && stale.windows.first?.usedPercent == 10)

        // Backed off: an immediate user refresh does not run Claude Code again.
        clock.now = now + 30
        _ = await service.refresh(userInitiated: true)
        #expect(fixture.claudeUsage.runs == 1)

        clock.now = now + 120
        fixture.claudeUsage.respond = { [fixture] in
            // Still signed in as A, but the cache belongs to B.
            let ms = clock.now.timeIntervalSince1970 * 1000
            _ = try? fixture.write(
                #"{"oauthAccount":{"accountUuid":"A"},"cachedUsageUtilization":{"fetchedAtMs":\#(ms),"accountUuid":"B","utilization":{"five_hour":{"utilization":90}}}}"#,
                to: ".claude.json")
            return .finished
        }
        let other = try #require(await service.refresh(userInitiated: true).first?.accounts.first)
        #expect(other.issue == .requestFailed && other.windows.first?.usedPercent != 90)
    }

    @Test func missingClaudeCodeIsReported() async throws {
        let fixture = try Fixture()
        try fixture.write(Fixture.claudeState(account: "A", fetchedAt: now - 86400, used: 10), to: ".claude.json")
        let account = await fixture.service(live: true, now: now).refresh(userInitiated: true).first?.accounts.first
        #expect(account?.issue == .cliUnavailable)
    }

    @Test func activeCodexAccountIsLiveAndOthersComeFromTheStore() async throws {
        let fixture = try Fixture()
        try fixture.write(Fixture.codexAuth(token: Fixture.jwt(expiry: now + 3600)), to: ".codex/auth.json")
        try fixture.write(Fixture.managed(["acct-a", "acct-b", "acct-c"]), to: ".cc-switch/codex_oauth_auth.json")
        let stored =
            #"{"codex:acct-b":{"email":"b@example.com","windows":[{"id":"seven_day","usedPercent":40,"duration":604800,"observedAt":1793600000,"source":"live"}]}}"#
        try fixture.write(stored, to: "Library/Application Support/Tidemark/usage-snapshots.json")
        fixture.transport.respond = { request in
            guard request.url?.host == "chatgpt.com" else { return (401, Data()) }
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-a")
            return (
                200,
                Data(
                    #"{"email":"a@example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":604800,"reset_at":1794000000}}}"#
                        .utf8)
            )
        }
        let services = await fixture.service(live: true, now: now).refresh(userInitiated: false)
        let codex = try #require(services.last?.accounts)
        #expect(codex.map(\.id) == ["codex:managed:local-0", "codex:managed:local-1", "codex:managed:local-2"])
        #expect(codex[0].isActive && codex[0].email == "a@example.com" && codex[0].plan == "plus")
        #expect(codex[0].windows.first?.remainingPercent(at: now) == 30)
        #expect(codex[1].windows.first?.usedPercent == 40)
        #expect(codex[1].issue == .credentialExpired)
        #expect(codex[2].windows.isEmpty && codex[2].issue == .credentialExpired)
        // The live reading is kept for later, without the token that fetched it.
        let saved = try String(
            contentsOf: fixture.home.appending(path: "Library/Application Support/Tidemark/usage-snapshots.json"),
            encoding: .utf8)
        #expect(saved.contains("codex:managed:local-0"))
        #expect(!saved.contains(Fixture.jwt(expiry: now + 3600)))
    }

    @Test func claudeSwitchDropsTheOldStatuslineReading() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(#"{"oauthAccount":{"accountUuid":"A"}}"#, to: ".claude.json")
        fixture.claudeUsage.respond = { .finished }
        let service = fixture.service(live: true, clock: clock)
        _ = await service.refresh(userInitiated: true)

        // Switch to B. The tap still holds A's reading, taken before Tidemark saw the switch.
        clock.now = now + 60
        try fixture.write(#"{"oauthAccount":{"accountUuid":"B"}}"#, to: ".claude.json")
        try fixture.write(
            #"{"rate_limits":{"five_hour":{"used_percentage":90}},"received_at":\#(now.timeIntervalSince1970 + 30)}"#,
            to: "Library/Application Support/Tidemark/claude-rate-limits.json")
        let claude = try #require(await service.refresh(userInitiated: true).first?.accounts.first)
        #expect(claude.id == "claude:B" && claude.windows.isEmpty && claude.issue == .requestFailed)
    }

    @Test func futureDatedReadingNeverOutranksALiveOne() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(
            #"{"rate_limits":{"five_hour":{"used_percentage":50}},"received_at":\#(now.timeIntervalSince1970 + 86400)}"#,
            to: "Library/Application Support/Tidemark/claude-rate-limits.json")
        try fixture.write(#"{"oauthAccount":{"accountUuid":"A"}}"#, to: ".claude.json")
        fixture.claudeUsage.respond = { [fixture] in
            _ = try? fixture.write(
                Fixture.claudeState(account: "A", fetchedAt: clock.now, used: 10), to: ".claude.json")
            return .finished
        }
        let services = await fixture.service(live: true, clock: clock).refresh(userInitiated: true)
        #expect(services.first?.accounts.first?.windows.first?.usedPercent == 10)
    }

    @Test func keychainCodexGateFollowsTheAccountItNames() async throws {
        let fixture = try Fixture()
        try fixture.write(#"cli_auth_credentials_store = "keyring""#, to: ".codex/config.toml")
        fixture.credentials.items["Codex Auth"] = Data(Fixture.codexAuth(token: Fixture.jwt(expiry: now + 3600)).utf8)
        fixture.transport.respond = { _ in
            (200, Data(#"{"rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":604800}}}"#.utf8))
        }
        let service = fixture.service(live: true, now: now)
        _ = await service.refresh(userInitiated: false)
        let codex = await service.refresh(userInitiated: false).last?.accounts.first
        #expect(fixture.transport.requests.filter { $0.url?.host == "chatgpt.com" }.count == 1)
        #expect(codex?.id == "codex:acct-a" && codex?.windows.first?.usedPercent == 70)
    }

    @Test func gateHonorsRetryAfterThenBacksOffExponentially() {
        var gate = LiveRequestGate()
        let start = Date(timeIntervalSince1970: 0)
        #expect(gate.allows("a", now: start, userInitiated: false))
        gate.recordSuccess("a", now: start)
        #expect(!gate.allows("a", now: start + 299, userInitiated: false))
        #expect(gate.allows("a", now: start + 20, userInitiated: true))

        gate.recordFailure("a", now: start, retryAfter: LiveRequestGate.retryAfter("120", now: start), jitter: 1)
        #expect(!gate.allows("a", now: start + 119, userInitiated: true))
        #expect(gate.allows("a", now: start + 120, userInitiated: false))
        gate.recordFailure("a", now: start, retryAfter: nil, jitter: 1)  // second failure: 120 s
        #expect(!gate.allows("a", now: start + 119, userInitiated: true))
        for _ in 0..<10 { gate.recordFailure("a", now: start, retryAfter: nil, jitter: 1) }
        #expect(!gate.allows("a", now: start + 1799, userInitiated: true))
        #expect(gate.allows("a", now: start + 1800, userInitiated: false))
    }
}

/// A temporary home directory with fake credentials and network.
final class Fixture: @unchecked Sendable {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let credentials = FakeCredentials()
    let transport = FakeTransport()
    let claudeUsage = FakeClaudeUsage()

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func service(live: Bool, now: Date? = nil) -> UsageService {
        service(live: live, clock: now.map(Clock.init))
    }

    func service(live: Bool, clock: Clock?) -> UsageService {
        let environment = UsageEnvironment(
            home: home, codexHome: home.appending(path: ".codex"), ccSwitchHome: home.appending(path: ".cc-switch"),
            supportDirectory: home.appending(path: "Library/Application Support/Tidemark"),
            credentials: credentials, transport: transport, claudeUsage: claudeUsage, now: { clock?.now ?? Date() })
        return UsageService(environment: environment, liveEnabled: live, jitter: { 1 })
    }

    /// `~/.claude.json` signed in as `account`, with a usage cache Claude Code fetched at `fetchedAt`.
    static func claudeState(account: String, fetchedAt: Date, used: Double, plan: String = "claude_pro") -> String {
        #"{"oauthAccount":{"accountUuid":"\#(account)","organizationType":"\#(plan)"},"cachedUsageUtilization":{"fetchedAtMs":\#(fetchedAt.timeIntervalSince1970 * 1000),"accountUuid":"\#(account)","utilization":{"five_hour":{"utilization":\#(used)}}}}"#
    }

    static func jwt(expiry: Date) -> String {
        let payload = Data(#"{"exp":\#(Int(expiry.timeIntervalSince1970))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    static func codexAuth(token: String) -> String {
        #"{"auth_mode":"chatgpt","tokens":{"access_token":"\#(token)","account_id":"acct-a","refresh_token":"r"}}"#
    }

    static func managed(_ ids: [String]) -> String {
        let accounts = ids.enumerated().map { index, id in
            #""local-\#(index)":{"account_id":"local-\#(index)","chatgpt_account_id":"\#(id)","email":"\#(id.suffix(1))@example.com","refresh_token":"r"}"#
        }
        return #"{"version":2,"accounts":{\#(accounts.joined(separator: ","))},"default_account_id":"local-0"}"#
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ now: Date) { stored = now }

    var now: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class FakeCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItems: [String: Data] = [:]
    private var storedReads: [String] = []
    private var storedDenied: Set<String> = []

    var items: [String: Data] {
        get { lock.withLock { storedItems } }
        set { lock.withLock { storedItems = newValue } }
    }
    var reads: [String] { lock.withLock { storedReads } }
    /// Services whose reads fail as if the user denied the Keychain prompt.
    var denied: Set<String> {
        get { lock.withLock { storedDenied } }
        set { lock.withLock { storedDenied = newValue } }
    }

    func genericPassword(service: String, account: String?) throws -> Data? {
        try lock.withLock {
            storedReads.append(service)
            if storedDenied.contains(service) { throw CredentialAccessError(status: errSecUserCanceled) }
            return storedItems[service]
        }
    }
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (500, Data()) }

    var requests: [URLRequest] { lock.withLock { storedRequests } }
    var respond: @Sendable (URLRequest) -> (Int, Data) {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock {
            storedRequests.append(request)
            return handler(request)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

final class FakeClaudeUsage: ClaudeUsageCommand, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable () -> ClaudeUsageRun = { .unavailable }
    private var count = 0

    var runs: Int { lock.withLock { count } }
    var respond: @Sendable () -> ClaudeUsageRun {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func run() async -> ClaudeUsageRun {
        let handler = lock.withLock {
            count += 1
            return self.handler
        }
        return handler()
    }
}
