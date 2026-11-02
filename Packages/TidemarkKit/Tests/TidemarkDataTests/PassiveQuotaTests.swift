//
//  PassiveQuotaTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import Testing
import TidemarkData

struct PassiveQuotaTests {
    private let event =
        #"{"timestamp":"2026-11-03T00:00:00.123Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":64,"window_minutes":10080,"resets_at":1794000000},"secondary":null}}}"#

    @Test func codexPreservesWeeklyPrimaryAndNullSecondary() throws {
        let windows = PassiveQuotaParser.codexEvent(Data(event.utf8))
        let window = try #require(windows.first)
        #expect(windows.count == 1)
        #expect(window.id == "seven_day")
        #expect(window.duration == 604800)
        #expect(window.usedPercent == 64)
        #expect(window.remainingPercent(at: window.observedAt) == 36)
        #expect(
            PassiveQuotaParser.codexEvent(Data(event.replacingOccurrences(of: "token_count", with: "other").utf8))
                .isEmpty)
    }

    @Test func duplicateCodexDurationsAndInvalidNumbersAreSafe() throws {
        let duplicate = event.replacingOccurrences(
            of: "\"secondary\":null",
            with:
                "\"secondary\":{\"used_percent\":20,\"window_minutes\":10080}")
        #expect(PassiveQuotaParser.codexEvent(Data(duplicate.utf8)).count == 1)
        let boolean = event.replacingOccurrences(of: "\"used_percent\":64", with: "\"used_percent\":true")
        let invalid = try #require(PassiveQuotaParser.codexEvent(Data(boolean.utf8)).first)
        #expect(invalid.usedPercent == nil)
        let hugeReset = event.replacingOccurrences(of: "1794000000", with: "1e308")
        #expect(PassiveQuotaParser.codexEvent(Data(hugeReset.utf8)).first?.resetsAt == nil)
    }

    @Test func claudeScopedValuesOverrideLegacyAndStatuslineNeedsTimestamp() throws {
        let cache =
            #"{"cachedUsageUtilization":{"fetchedAtMs":1793664000000,"accountUuid":"redacted","utilization":{"five_hour":{"utilization":0,"resets_at":null},"seven_day_opus":{"utilization":50},"extra_usage":{"utilization":25},"limits":[{"kind":"weekly_scoped","group":"weekly","scope":{"model":{"display_name":"Opus"}},"percent":75}]}}}"#
        let windows = PassiveQuotaParser.claudeCache(Data(cache.utf8))
        #expect(windows.count == 2)
        #expect(windows.first(where: { $0.id == "five_hour" })?.usedPercent == 0)
        #expect(windows.first(where: { $0.id == "seven_day_opus" })?.usedPercent == 75)
        let tap =
            #"{"received_at":1793664000,"rate_limits":{"five_hour":{"used_percentage":38,"resets_at":1794000000}}}"#
        let window = try #require(PassiveQuotaParser.claudeStatusline(Data(tap.utf8)).first)
        #expect(window.usedPercent == 38)
        #expect(window.source == .statusline)
        #expect(
            PassiveQuotaParser.claudeStatusline(Data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#.utf8))
                .isEmpty)
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

    @Test func readerChoosesNewestClaudeCaptureWithoutMergingAccounts() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let support = home.appending(path: "Library/Application Support/Tidemark")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache =
            #"{"cachedUsageUtilization":{"fetchedAtMs":1793664000000,"utilization":{"seven_day":{"utilization":60}}}}"#
        let tap = #"{"received_at":1793664100,"rate_limits":{"five_hour":{"used_percentage":20}}}"#
        try Data(cache.utf8).write(to: home.appending(path: ".claude.json"))
        try Data(tap.utf8).write(to: support.appending(path: "claude-rate-limits.json"))
        let observations = await PassiveQuotaReader(home: home).read()
        let windows = try #require(observations.first(where: { $0.service == .claude })?.windows)
        #expect(windows.count == 1)
        #expect(windows.first?.id == "five_hour")
        #expect(windows.first?.source == .statusline)
    }

    @Test func newestRolloutWithoutQuotaDoesNotBorrowAnotherSessionsLimits() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = home.appending(path: ".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let older = sessions.appending(path: "rollout-old.jsonl")
        try Data(event.utf8).write(to: older)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try Data("{}\n".utf8).write(to: sessions.appending(path: "rollout-new.jsonl"))
        let observations = await PassiveQuotaReader(home: home).read()
        #expect(observations.first(where: { $0.service == .codex })?.issue == .unrecognized)
    }

    @Test func readerSkipsPartialTailAndKeepsExternalFilesUnchanged() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = home.appending(path: ".codex/sessions/2026/11/03")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rollout = sessions.appending(path: "rollout-test.jsonl")
        let content = Data((String(repeating: "x", count: 600000) + "\n" + event + "\n{\"rate_limits\":\n").utf8)
        try content.write(to: rollout)
        let observations = await PassiveQuotaReader(home: home).read()
        #expect(observations.first(where: { $0.service == .claude })?.issue == .missing)
        #expect(observations.first(where: { $0.service == .codex })?.windows.first?.id == "seven_day")
        #expect(try Data(contentsOf: rollout) == content)
    }
}
