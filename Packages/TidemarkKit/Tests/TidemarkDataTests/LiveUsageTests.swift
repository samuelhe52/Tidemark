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
        // `auth.json` names acct-a, so CC Switch's older marker for acct-b does not decide.
        let codex = try #require(services.last?.accounts)
        #expect(codex.map(\.id) == ["codex:managed:local-0", "codex:managed:local-1"])
        #expect(codex.map(\.isActive) == [true, false])
        #expect(codex.last?.issue == .notObserved)
    }

    @Test func expiredClaudeTokenIsReportedAndNeverSent() async throws {
        let fixture = try Fixture()
        let expired = (now.timeIntervalSince1970 - 10) * 1000
        fixture.credentials.items["Claude Code-credentials"] = Data(
            #"{"claudeAiOauth":{"accessToken":"t","expiresAt":\#(expired)}}"#.utf8)
        let services = await fixture.service(live: true, now: now).refresh(userInitiated: true)
        #expect(services.first?.accounts.first?.issue == .credentialExpired)
        #expect(!fixture.transport.requests.contains { $0.url?.host == "api.anthropic.com" })
    }

    @Test func renewedClaudeCredentialCanBeRetriedAfterExpiry() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        let expired = (now.timeIntervalSince1970 - 10) * 1000
        fixture.credentials.items["Claude Code-credentials"] = Data(
            #"{"claudeAiOauth":{"accessToken":"old","expiresAt":\#(expired)}}"#.utf8)
        fixture.transport.respond = { _ in (200, Data(#"{"five_hour":{"utilization":21}}"#.utf8)) }
        let service = fixture.service(live: true, clock: clock)
        #expect(await service.refresh(userInitiated: true).first?.accounts.first?.issue == .credentialExpired)
        clock.now = now + 60
        #expect(await service.refresh(userInitiated: false).first?.accounts.first?.issue == .credentialExpired)
        fixture.credentials.items["Claude Code-credentials"] = Data(
            #"{"claudeAiOauth":{"accessToken":"new","expiresAt":\#((now.timeIntervalSince1970 + 3600) * 1000)}}"#.utf8)
        clock.now = now + 80
        let account = try #require(await service.refresh(userInitiated: true).first?.accounts.first)
        #expect(account.issue == nil)
        #expect(account.windows.first?.usedPercent == 21)
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

    @Test func claudeSwitchRereadsTheTokenAndDropsTheOldStatuslineReading() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        fixture.transport.respond = { request in
            let token = request.value(forHTTPHeaderField: "Authorization")
            return token == "Bearer tok-a" ? (200, Data(#"{"five_hour":{"utilization":10}}"#.utf8)) : (500, Data())
        }
        try fixture.write(#"{"oauthAccount":{"accountUuid":"A"}}"#, to: ".claude.json")
        fixture.credentials.items["Claude Code-credentials"] = Data(#"{"claudeAiOauth":{"accessToken":"tok-a"}}"#.utf8)
        let service = fixture.service(live: true, clock: clock)
        _ = await service.refresh(userInitiated: true)

        // Switch to B. The tap still holds A's reading, taken before Tidemark saw the switch.
        clock.now = now + 60
        try fixture.write(#"{"oauthAccount":{"accountUuid":"B"}}"#, to: ".claude.json")
        fixture.credentials.items["Claude Code-credentials"] = Data(#"{"claudeAiOauth":{"accessToken":"tok-b"}}"#.utf8)
        try fixture.write(
            #"{"rate_limits":{"five_hour":{"used_percentage":90}},"received_at":\#(now.timeIntervalSince1970 + 30)}"#,
            to: "Library/Application Support/Tidemark/claude-rate-limits.json")
        let claude = try #require(await service.refresh(userInitiated: true).first?.accounts.first)
        #expect(fixture.transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-b")
        #expect(claude.id == "claude:B" && claude.windows.isEmpty && claude.issue == .requestFailed)
    }

    @Test func futureDatedReadingNeverOutranksALiveOne() async throws {
        let fixture = try Fixture()
        let future = (now.timeIntervalSince1970 + 86400) * 1000
        try fixture.write(
            #"{"oauthAccount":{"accountUuid":"A"},"cachedUsageUtilization":{"fetchedAtMs":\#(future),"accountUuid":"A","utilization":{"five_hour":{"utilization":50}}}}"#,
            to: ".claude.json")
        fixture.credentials.items["Claude Code-credentials"] = Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8)
        fixture.transport.respond = { _ in (200, Data(#"{"five_hour":{"utilization":10}}"#.utf8)) }
        let services = await fixture.service(live: true, now: now).refresh(userInitiated: true)
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
            credentials: credentials, transport: transport, now: { clock?.now ?? Date() })
        return UsageService(environment: environment, liveEnabled: live, jitter: { 1 })
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
