//
//  ManagedCodexTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Darwin
import Foundation
import Testing

@testable import TidemarkData

struct ManagedCodexTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    @Test func inactiveUsersInOneWorkspaceHaveIndependentTokensAndSnapshots() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        let native = Self.identityToken(user: "alice", workspace: "shared", expiry: now + 7200)
        try fixture.write(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"\#(native)","id_token":"\#(native)","account_id":"shared"}}"#,
            to: ".codex/auth.json")
        let before = try Data(contentsOf: fixture.home.appending(path: ".codex/auth.json"))
        try fixture.write(
            Self.store([
                "alice": Self.row("alice", workspace: "shared", identity: native),
                "bob": Self.row(
                    "bob", workspace: "shared",
                    identity: Self.identityToken(user: "bob", workspace: "shared", expiry: now))
            ]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.transport.respond = { request in
            if request.url?.host == "auth.openai.com" {
                let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                #expect(form.contains("refresh_token=refresh-bob%2B%26%3D"))
                #expect(form.contains("scope=openid%20profile%20email"))
                return (
                    200, Data(#"{"access_token":"bob-access","refresh_token":"bob-rotated","expires_in":3600}"#.utf8)
                )
            }
            guard request.url?.host == "chatgpt.com" else { return (401, Data()) }
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "shared")
            let used = request.value(forHTTPHeaderField: "Authorization") == "Bearer bob-access" ? 65 : 10
            return (200, Self.usage(used))
        }
        let service = fixture.service(live: true, clock: clock)
        let accounts = try #require(await service.refresh(userInitiated: true).last?.accounts)
        #expect(accounts.map(\.id) == ["codex:managed:alice", "codex:managed:bob"])
        #expect(accounts.map(\.isActive) == [true, false])
        #expect(accounts.map { $0.windows.first?.usedPercent } == [10, 65])
        clock.now = now + 20
        _ = await service.refresh(userInitiated: true)
        #expect(fixture.transport.requests.filter { $0.url?.host == "auth.openai.com" }.count == 1)
        let root = try Self.readStore(fixture)
        #expect(root["extension"] as? String == "preserve-root")
        #expect(root["default_account_id"] as? String == "alice")
        let rows = try #require(root["accounts"] as? [String: [String: Any]])
        #expect(rows["alice"]?["refresh_token"] as? String == "refresh-alice+&=")
        #expect(rows["bob"]?["refresh_token"] as? String == "bob-rotated")
        #expect(rows["bob"]?["extension"] as? String == "preserve-row")
        #expect(rows["bob"]?["access_token"] == nil)
        let url = fixture.home.appending(path: ".cc-switch/codex_oauth_auth.json")
        #expect(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
                == 0o600)
        #expect(try Data(contentsOf: fixture.home.appending(path: ".codex/auth.json")) == before)
        let saved = try String(
            contentsOf: fixture.home.appending(path: "Library/Application Support/Tidemark/usage-snapshots.json"),
            encoding: .utf8)
        #expect(!saved.contains("bob-access") && !saved.contains("bob-rotated") && !saved.contains(native))
    }

    @Test func writeBackPreservesAnotherAccountsConcurrentUpdate() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a"), "b": Self.row("b")]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.transport.respond = { _ in
            _ = try? fixture.write(
                Self.store(["a": Self.row("a"), "b": Self.row("b", refresh: "new-b")]),
                to: ".cc-switch/codex_oauth_auth.json")
            return (200, Data(#"{"access_token":"access-a","refresh_token":"new-a","expires_in":3600}"#.utf8))
        }
        let token = try await manager(fixture).token(for: account("a"))
        #expect(token.value == "access-a")
        let root = try Self.readStore(fixture)
        let rows = try #require(root["accounts"] as? [String: [String: Any]])
        #expect(rows["a"]?["refresh_token"] as? String == "new-a")
        #expect(rows["b"]?["refresh_token"] as? String == "new-b")
    }

    @Test func workspaceMatchDoesNotMarkADifferentUserAsActive() async throws {
        let fixture = try Fixture()
        let native = Self.identityToken(user: "unmanaged-user", workspace: "shared", expiry: now + 7200)
        let managed = Self.identityToken(user: "managed-user", workspace: "shared", expiry: now + 7200)
        try fixture.write(
            #"{"tokens":{"access_token":"\#(native)","id_token":"\#(native)","account_id":"shared"}}"#,
            to: ".codex/auth.json")
        try fixture.write(
            Self.store(["managed": Self.row("managed", workspace: "shared", identity: managed)]),
            to: ".cc-switch/codex_oauth_auth.json")
        try fixture.write(
            #"{"codex:shared":{"email":"unmanaged@example.com","windows":[{"id":"seven_day","usedPercent":33,"observedAt":1793700000,"source":"live"}]}}"#,
            to: "Library/Application Support/Tidemark/usage-snapshots.json")
        let accounts = try #require(
            await fixture.service(live: false, now: now).refresh(userInitiated: true).last?.accounts)
        #expect(accounts.map(\.id) == ["codex:shared", "codex:managed:managed"])
        #expect(accounts.map(\.isActive) == [true, false])
        #expect(accounts[0].windows.first?.usedPercent == 33 && accounts[1].windows.isEmpty)
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func rotationTimestampStaysAnIntegerForCCSwitch() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.transport.respond = { _ in
            (200, Data(#"{"access_token":"access-a","refresh_token":"new-a","expires_in":3600}"#.utf8))
        }
        let environment = UsageEnvironment(
            home: fixture.home, codexHome: fixture.home.appending(path: ".codex"),
            ccSwitchHome: fixture.home.appending(path: ".cc-switch"),
            supportDirectory: fixture.home.appending(path: "Library/Application Support/Tidemark"),
            credentials: fixture.credentials, transport: fixture.transport, now: { now + 0.331 })
        _ = try await ManagedCodexCredentials(environment: environment).token(for: account("a"))
        // CC Switch decodes this field as `i64`, like this strict decoder.
        struct Store: Decodable {
            struct Row: Decodable { let token_updated_at_ms: Int64 }
            let accounts: [String: Row]
        }
        let data = try Data(contentsOf: fixture.home.appending(path: ".cc-switch/codex_oauth_auth.json"))
        let store = try JSONDecoder().decode(Store.self, from: data)
        let base = Int64(now.timeIntervalSince1970 * 1000)
        #expect(store.accounts["a"].map { (base...base + 331).contains($0.token_updated_at_ms) } == true)
    }

    @Test func deniedKeychainIsNotAskedAgainOnAutomaticRefresh() async throws {
        let fixture = try Fixture()
        let clock = Clock(now)
        try fixture.write(#"cli_auth_credentials_store = "keyring""#, to: ".codex/config.toml")
        try fixture.write(#"{"chatgpt_account_id":"workspace-a"}"#, to: ".cc-switch/codex_managed_oauth_live_auth.json")
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.credentials.denied = ["Codex Auth"]
        fixture.transport.respond = { request in
            request.url?.host == "auth.openai.com"
                ? (200, Data(#"{"access_token":"access-a","refresh_token":"new-a","expires_in":3600}"#.utf8))
                : (200, Self.usage(40))
        }
        let service = fixture.service(live: true, clock: clock)
        let first = await service.refresh(userInitiated: false).last?.accounts.first
        clock.now = now + 60
        _ = await service.refresh(userInitiated: false)
        #expect(fixture.credentials.reads.filter { $0 == "Codex Auth" }.count == 1)
        // The managed account still renews on its own credentials.
        #expect(first?.id == "codex:managed:a" && first?.windows.first?.usedPercent == 40)
    }

    @Test func managedAccountWithoutIdentityIsNotTheKnownNativeUser() async throws {
        let fixture = try Fixture()
        let native = Self.identityToken(user: "bob", workspace: "shared", expiry: now + 7200)
        try fixture.write(
            #"{"tokens":{"access_token":"\#(native)","id_token":"\#(native)","account_id":"shared"}}"#,
            to: ".codex/auth.json")
        try fixture.write(
            Self.store(["alice": Self.row("alice", workspace: "shared")]), to: ".cc-switch/codex_oauth_auth.json")
        let accounts = try #require(
            await fixture.service(live: false, now: now).refresh(userInitiated: true).last?.accounts)
        #expect(accounts.map(\.id) == ["codex:shared", "codex:managed:alice"])
        #expect(accounts.map(\.isActive) == [true, false])
    }

    @Test func newerGenerationOrRemovedAccountIsNeverOverwritten() async throws {
        for remove in [false, true] {
            let fixture = try Fixture()
            try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
            fixture.transport.respond = { _ in
                _ = try? fixture.write(
                    Self.store(remove ? [:] : ["a": Self.row("a", refresh: "newer-owner")]),
                    to: ".cc-switch/codex_oauth_auth.json")
                return (
                    200,
                    Data(#"{"access_token":"stale-access","refresh_token":"stale-rotation","expires_in":3600}"#.utf8)
                )
            }
            do {
                _ = try await manager(fixture).token(for: account("a"))
                Issue.record("A stale generation must not be committed")
            } catch let failure as ManagedCredentialError {
                #expect(failure.issue == (remove ? .signedOut : .credentialChanged))
            }
            let saved = try String(
                contentsOf: fixture.home.appending(path: ".cc-switch/codex_oauth_auth.json"), encoding: .utf8)
            #expect(!saved.contains("stale-rotation"))
        }
    }

    @Test func rejectedRefreshRetriesOnlyANewerDiskGeneration() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.transport.respond = { request in
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if form.contains("refresh-a%2B%26%3D") {
                _ = try? fixture.write(
                    Self.store(["a": Self.row("a", refresh: "owner-new")]), to: ".cc-switch/codex_oauth_auth.json")
                return (400, Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8))
            }
            #expect(form.contains("refresh_token=owner-new"))
            return (200, Data(#"{"access_token":"recovered","refresh_token":"rotated","expires_in":3600}"#.utf8))
        }
        #expect(try await manager(fixture).token(for: account("a")).value == "recovered")
        #expect(fixture.transport.requests.count == 2)
    }

    @Test func rejectedAccountDoesNotPreventAnotherAccountsQuota() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a"), "b": Self.row("b")]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.transport.respond = { request in
            if request.url?.host == "auth.openai.com" {
                let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                return form.contains("refresh-a%2B%26%3D")
                    ? (400, Data(#"{"error":"invalid_grant"}"#.utf8))
                    : (200, Data(#"{"access_token":"b-access","expires_in":3600}"#.utf8))
            }
            return request.url?.host == "chatgpt.com" ? (200, Self.usage(42)) : (401, Data())
        }
        let accounts = try #require(
            await fixture.service(live: true, now: now).refresh(userInitiated: true).last?.accounts)
        #expect(accounts.first { $0.id == "codex:managed:a" }?.issue == .credentialExpired)
        #expect(accounts.first { $0.id == "codex:managed:b" }?.windows.first?.usedPercent == 42)
    }

    @Test func failedPersistenceRetriesTheWriteWithoutReplayingASpentRefreshToken() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        fixture.transport.respond = { _ in
            (200, Data(#"{"access_token":"access","refresh_token":"rotated","expires_in":3600}"#.utf8))
        }
        let writable = Clock(now)
        let manager = ManagedCodexCredentials(
            environment: environment(fixture),
            write: { data, url in
                if writable.now == now { throw CocoaError(.fileWriteNoPermission) }
                try ManagedCodexCredentials.secureWrite(data, to: url)
            })
        do {
            _ = try await manager.token(for: account("a"))
            Issue.record("A persistence error must be exposed")
        } catch let failure as ManagedCredentialError { #expect(failure.issue == .credentialSaveFailed) }
        writable.now = now + 1
        #expect(try await manager.token(for: account("a")).value == "access")
        #expect(fixture.transport.requests.count == 1)
    }

    @Test func anotherTidemarkProcessLockPreventsRefreshExchange() async throws {
        let fixture = try Fixture()
        let env = environment(fixture)
        try FileManager.default.createDirectory(at: env.supportDirectory, withIntermediateDirectories: true)
        let descriptor = open(
            env.supportDirectory.appending(path: "managed-codex-renewal.lock").path, O_CREAT | O_RDWR, 0o600)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        do {
            _ = try await manager(fixture).token(for: account("a"))
            Issue.record("A second process must back off")
        } catch let failure as ManagedCredentialError { #expect(failure.issue == .credentialChanged) }
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func renewalHonorsRetryAfter() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        var env = environment(fixture)
        env.transport = RenewalLimitTransport()
        do {
            _ = try await ManagedCodexCredentials(environment: env).token(for: account("a"))
            Issue.record("Rate limiting must propagate to the account gate")
        } catch let failure as ManagedCredentialError {
            #expect(failure.issue == .rateLimited && failure.retryAfter == 900)
        }
    }

    @Test func disablingLiveDuringRenewalSavesTheRotationButDoesNotQueryUsage() async throws {
        let fixture = try Fixture()
        try fixture.write(Self.store(["a": Self.row("a")]), to: ".cc-switch/codex_oauth_auth.json")
        let transport = PausedRenewalTransport()
        var env = environment(fixture)
        env.transport = transport
        let service = UsageService(environment: env, liveEnabled: true)
        let refresh = Task { await service.refresh(userInitiated: true) }
        await transport.waitUntilStarted()
        await service.setLiveEnabled(false)
        await transport.finish()
        let result = await refresh.value
        #expect(result.last?.accounts.allSatisfy { $0.windows.isEmpty } == true)
        _ = await service.refresh(userInitiated: true)
        #expect(await transport.count == 1)
        let rows = try #require(Self.readStore(fixture)["accounts"] as? [String: [String: Any]])
        #expect(rows["a"]?["refresh_token"] as? String == "rotated")
    }

    private func environment(_ fixture: Fixture) -> UsageEnvironment {
        UsageEnvironment(
            home: fixture.home, codexHome: fixture.home.appending(path: ".codex"),
            ccSwitchHome: fixture.home.appending(path: ".cc-switch"),
            supportDirectory: fixture.home.appending(path: "Library/Application Support/Tidemark"),
            credentials: fixture.credentials, transport: fixture.transport, now: { now })
    }

    private func manager(_ fixture: Fixture) -> ManagedCodexCredentials {
        ManagedCodexCredentials(environment: environment(fixture))
    }

    private func account(_ id: String) -> LocalSources.ManagedCodexAccount {
        .init(localID: id, chatGPTAccountID: "workspace-\(id)", email: nil, userIdentity: nil)
    }

    private static func row(_ id: String, workspace: String? = nil, identity: String? = nil, refresh: String? = nil)
        -> [String: Any]
    {
        var row: [String: Any] = [
            "account_id": id, "chatgpt_account_id": workspace ?? "workspace-\(id)",
            "email": "\(id)@example.com", "refresh_token": refresh ?? "refresh-\(id)+&=",
            "token_updated_at_ms": 1, "extension": "preserve-row"
        ]
        if let identity { row["id_token"] = identity }
        return row
    }

    private static func store(_ rows: [String: [String: Any]]) -> String {
        String(
            data: try! JSONSerialization.data(withJSONObject: [
                "version": 2, "accounts": rows, "default_account_id": "alice", "extension": "preserve-root"
            ]), encoding: .utf8)!
    }

    private static func readStore(_ fixture: Fixture) throws -> [String: Any] {
        try #require(
            QuotaParser.object(Data(contentsOf: fixture.home.appending(path: ".cc-switch/codex_oauth_auth.json"))))
    }

    private static func identityToken(user: String, workspace: String, expiry: Date) -> String {
        let claims: [String: Any] = [
            "sub": user, "exp": expiry.timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": workspace]
        ]
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(
                of: "/", with: "_")
        return "e30.\(payload).sig"
    }

    private static func usage(_ used: Int) -> Data {
        Data(#"{"rate_limit":{"primary_window":{"used_percent":\#(used),"limit_window_seconds":604800}}}"#.utf8)
    }
}

fileprivate struct RenewalLimitTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data(),
            HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "900"])!
        )
    }
}

private actor PausedRenewalTransport: HTTPTransport {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var url: URL?
    private(set) var count = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        url = request.url
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish() {
        continuation?.resume(
            returning: (
                Data(#"{"access_token":"access","refresh_token":"rotated","expires_in":3600}"#.utf8),
                HTTPURLResponse(url: url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        continuation = nil
    }
}
