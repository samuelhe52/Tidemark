//
//  PassiveQuotaTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import Testing

@testable import TidemarkData

struct PassiveQuotaTests {
    static let event =
        #"{"timestamp":"2026-11-03T00:00:00.123Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":64,"window_minutes":10080,"resets_at":1794000000},"secondary":null}}}"#

    @Test func codexPreservesWeeklyPrimaryAndNullSecondary() throws {
        let windows = QuotaParser.codexEvent(Data(Self.event.utf8))
        let window = try #require(windows.first)
        #expect(windows.count == 1)
        #expect(window.id == "seven_day")
        #expect(window.duration == 604800)
        #expect(window.usedPercent == 64)
        #expect(window.remainingPercent(at: window.observedAt) == 36)
        #expect(
            QuotaParser.codexEvent(Data(Self.event.replacingOccurrences(of: "token_count", with: "other").utf8))
                .isEmpty)
    }

    @Test func duplicateCodexDurationsAndInvalidNumbersAreSafe() throws {
        let event = Self.event
        let duplicate = event.replacingOccurrences(
            of: "\"secondary\":null", with: "\"secondary\":{\"used_percent\":20,\"window_minutes\":10080}")
        #expect(QuotaParser.codexEvent(Data(duplicate.utf8)).count == 1)
        let boolean = event.replacingOccurrences(of: "\"used_percent\":64", with: "\"used_percent\":true")
        let invalid = try #require(QuotaParser.codexEvent(Data(boolean.utf8)).first)
        #expect(invalid.usedPercent == nil)
        let hugeDuration = event.replacingOccurrences(of: "10080", with: "1e308")
        #expect(QuotaParser.codexEvent(Data(hugeDuration.utf8)).first?.duration == nil)
        let hugeReset = event.replacingOccurrences(of: "1794000000", with: "1e308")
        #expect(QuotaParser.codexEvent(Data(hugeReset.utf8)).first?.resetsAt == nil)
    }

    @Test func claudeKeepsNamedWindowsOnlyAndScopedValuesWin() throws {
        let cache =
            #"{"cachedUsageUtilization":{"fetchedAtMs":1793664000000,"accountUuid":"a","utilization":{"five_hour":{"utilization":0,"resets_at":null},"seven_day_opus":{"utilization":50},"iguana_necktie":{"utilization":67},"extra_usage":{"utilization":25},"limits":[{"kind":"weekly_scoped","group":"weekly","scope":{"model":{"display_name":"Opus"}},"percent":75}]}}}"#
        let parsed = try #require(QuotaParser.claudeCache(Data(cache.utf8)))
        #expect(parsed.accountUUID == "a")
        #expect(parsed.windows.map(\.id) == ["five_hour", "seven_day_opus"])
        #expect(parsed.windows.last?.usedPercent == 75)
        let tap =
            #"{"received_at":1793664000,"rate_limits":{"five_hour":{"used_percentage":38,"resets_at":1794000000}}}"#
        let window = try #require(QuotaParser.claudeStatusline(Data(tap.utf8)).first)
        #expect(window.usedPercent == 38)
        #expect(window.source == .statusline)
        #expect(
            QuotaParser.claudeStatusline(Data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#.utf8)).isEmpty)
    }

    @Test func usageAnswersParseMicrosecondDatesAndWindowLengths() throws {
        let now = Date(timeIntervalSince1970: 1_793_700_000)
        let claude =
            #"{"cachedUsageUtilization":{"fetchedAtMs":1793700000000,"utilization":{"five_hour":{"utilization":13.0,"resets_at":"2026-11-03T04:59:59.580758+00:00"},"seven_day":null,"iguana_necktie":{"utilization":67}}}}"#
        let windows = try #require(QuotaParser.claudeCache(Data(claude.utf8))?.windows)
        #expect(windows.map(\.id) == ["five_hour"])
        let reset = try #require(windows.first?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_793_681_999.58) < 0.01)

        let codex =
            #"{"email":"user@example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":70,"limit_window_seconds":604800,"reset_at":1793774148},"secondary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":600}}}"#
        let usage = try #require(QuotaParser.codexUsage(Data(codex.utf8), observedAt: now))
        #expect(usage.email == "user@example.com")
        #expect(usage.plan == "plus")
        #expect(usage.windows.map(\.id) == ["seven_day", "five_hour"])
        #expect(usage.windows.last?.resetsAt == now.addingTimeInterval(600))
    }

    @Test func missingInvalidStaleFutureAndExpiredNeverLookFull() {
        let seen = Date(timeIntervalSince1970: 1000)
        func window(_ used: Double?, reset: Date? = nil) -> QuotaWindow {
            QuotaWindow(
                id: "five_hour", usedPercent: used, resetsAt: reset, duration: 18000,
                observedAt: seen, source: .rollout)
        }
        #expect(window(0).remainingPercent(at: seen) == 100)
        for used in [nil, -1, 101, Double.nan, Double.infinity] as [Double?] {
            #expect(window(used).remainingPercent(at: seen) == nil)
        }
        #expect(window(0).freshness(at: seen.addingTimeInterval(120)) == .aging)
        #expect(window(0).remainingPercent(at: seen.addingTimeInterval(1800)) == nil)
        #expect(window(0).remainingPercent(at: seen.addingTimeInterval(-60)) == nil)
        #expect(window(0, reset: seen).freshness(at: seen) == .expired)
        #expect(window(0, reset: seen).remainingPercent(at: seen) == nil)
    }

    @Test func newestClaudeCaptureWinsWithoutMerging() async throws {
        let fixture = try Fixture()
        let cache =
            #"{"cachedUsageUtilization":{"fetchedAtMs":1793664000000,"utilization":{"seven_day":{"utilization":60}}}}"#
        let tap = #"{"received_at":1793664100,"rate_limits":{"five_hour":{"used_percentage":20}}}"#
        try fixture.write(cache, to: ".claude.json")
        try fixture.write(tap, to: "Library/Application Support/Tidemark/claude-rate-limits.json")
        let services = await fixture.service(live: false).refresh(userInitiated: false)
        let windows = try #require(services.first?.accounts.first?.windows)
        #expect(windows.map(\.id) == ["five_hour"])
        #expect(windows.first?.source == .statusline)
    }

    @Test func newestRolloutWithoutQuotaDoesNotBorrowAnotherSessionsLimits() async throws {
        let fixture = try Fixture()
        let older = try fixture.write(Self.event, to: ".codex/sessions/rollout-old.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try fixture.write("{}\n", to: ".codex/sessions/rollout-new.jsonl")
        let services = await fixture.service(live: false).refresh(userInitiated: false)
        #expect(services.last?.accounts.first?.issue == .unrecognized)
    }

    @Test func rolloutTailSkipsPartialLinesAndLeavesFilesUnchanged() async throws {
        let fixture = try Fixture()
        let content = String(repeating: "x", count: 600000) + "\n" + Self.event + "\n{\"rate_limits\":\n"
        let rollout = try fixture.write(content, to: ".codex/sessions/2026/11/03/rollout-test.jsonl")
        let services = await fixture.service(live: false).refresh(userInitiated: false)
        #expect(services.first?.accounts.first?.issue == .missing)
        #expect(services.last?.accounts.first?.windows.first?.id == "seven_day")
        #expect(try Data(contentsOf: rollout) == Data(content.utf8))
    }
}
