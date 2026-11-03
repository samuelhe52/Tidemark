//
//  UsageHistoryTests.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import SQLite3
import Testing

@testable import TidemarkData

struct UsageHistoryTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-03 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_707_200)

    @Test func rangesAndWholeRollupDaysFollowCCSwitch() {
        let midnight = Self.calendar.startOfDay(for: Self.now)
        #expect(UsageHistoryRange.today.interval(endingAt: Self.now, calendar: Self.calendar).start == midnight)
        let week = UsageHistoryRange.sevenDays.interval(endingAt: Self.now, calendar: Self.calendar)
        #expect(week.start == midnight.addingTimeInterval(-6 * 86400))
        #expect(
            UsageHistoryReader.rollupDays(start: week.start, end: Self.now, calendar: Self.calendar)
                == ["2026-10-28", "2026-11-02"])
        // A start after midnight skips its day; an end at 23:59 keeps its day.
        let lastMinute = midnight.addingTimeInterval(86400 - 30)
        #expect(
            UsageHistoryReader.rollupDays(start: week.start + 1, end: lastMinute, calendar: Self.calendar)
                == ["2026-10-29", "2026-11-03"])
        #expect(UsageHistoryReader.rollupDays(start: midnight, end: Self.now, calendar: Self.calendar) == nil)
        // CC Switch writes Gregorian dates whatever the user's calendar.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Self.calendar.timeZone
        #expect(
            UsageHistoryReader.rollupDays(start: week.start, end: Self.now, calendar: buddhist)
                == ["2026-10-28", "2026-11-02"])
    }

    @Test func viewsAddRollupsDedupSessionsAndNormalizeInput() throws {
        let fixture = try Fixture()
        #expect(read(fixture, .thirtyDays) == .failure(.missing))
        let base = Int(Self.now.timeIntervalSince1970)
        try makeDatabase(
            fixture,
            rollups: [
                "('2026-10-10', 'claude', 'p', 'm', '', 2, 100, 10, 0, 0, '1.5')",
                // Grouped under its pricing model.
                "('2026-10-11', 'claude-desktop', 'p', 'alias', 'm', 1, 50, 0, 0, 0, '0.5')",
                "('2026-10-01', 'codex', 'p', 'gpt', '', 9, 999, 0, 0, 0, '9')"  // before 30 days
            ],
            logs: [
                // OpenAI-style input includes the 600 cached tokens.
                "('a', 'codex', 'gpt', 1000, 20, 600, 0, '2', 200, 'codex_session', \(base - 7200))",
                "('b', 'claude', 'm', 7, 3, 0, 0, '0.25', 200, 'proxy', \(base - 100_000))",
                // The same request imported again from the session log.
                "('c', 'claude', 'm', 7, 3, 0, 0, '0.25', 200, 'session_log', \(base - 99_940))",
                "('d', 'claude', 'm', 5, 5, 0, 0, '1', 200, 'session_log', \(base - 40 * 86400))"
            ])

        let month = try read(fixture, .thirtyDays).get()
        #expect(month.apps.map(\.key) == ["codex", "claude"])
        #expect(month.models.map(\.key) == ["gpt", "m"])
        #expect(month.models.map(\.totals.totalTokens) == [1020, 170])
        #expect(
            month.apps[0].totals
                == UsageTotals(requests: 1, costUSD: 2, inputTokens: 400, outputTokens: 20, cacheReadTokens: 600))
        #expect(month.apps[1].totals == UsageTotals(requests: 4, costUSD: 2.25, inputTokens: 157, outputTokens: 13))
        #expect(month.latestRecordAt == Self.now.addingTimeInterval(-7200))

        // Daily buckets from the range start through today, adding up to the total.
        #expect(month.buckets.count == 30)
        #expect(month.buckets.first?.interval.start == month.interval.start)
        #expect(month.buckets.map(\.totals.totalTokens).reduce(0, +) == month.total.totalTokens)
        #expect(month.buckets[5].totals.totalTokens == 110)  // 2026-10-10
        #expect(month.buckets[29].totals.totalTokens == 1020)  // today

        // Today has no whole rollup day and excludes yesterday's detail rows; it shows every hour.
        let today = try read(fixture, .today).get()
        #expect(today.apps.map(\.key) == ["codex"])
        #expect(today.buckets.count == 24)
        #expect(today.buckets[10].totals.totalTokens == 1020)

        // All time runs by month from the first usage: September through November.
        let all = try read(fixture, .all).get()
        #expect(all.buckets.map(\.totals.totalTokens) == [10, 1159, 1030])
        #expect(all.days.reduce(UsageTotals()) { $0 + $1.totals } == all.total)
        #expect(all.days.first?.interval.start == Self.calendar.startOfDay(for: Self.now - 40 * 86400))
        #expect(all.days.last?.interval.start == Self.calendar.startOfDay(for: Self.now))
        #expect(all.days.count == 41)
        #expect(all.days.last?.totals.totalTokens == 1020)
        #expect(all.days[16].totals.totalTokens == 110)  // Oct 10 rollup
        #expect(all.days[17].totals.totalTokens == 50)  // Oct 11 rollup
        #expect(all.days[39].totals.totalTokens == 10)  // deduplicated Nov 2 detail
        #expect(all.days[38].totals.isEmpty == true)
        #expect(month.days.isEmpty)
    }

    @Test func dailyHeatmapPreservesDSTAndLongHistories() throws {
        let fixture = try Fixture()
        try makeDatabase(
            fixture,
            rollups: ["('2020-01-01', 'claude', 'p', 'm', '', 1, 10, 0, 0, 0, '1')"],
            logs: ["('a', 'claude', 'm', 20, 0, 0, 0, '1', 200, 'proxy', \(Int(Self.now.timeIntervalSince1970)))"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let all = try read(fixture, .all, calendar: calendar).get()
        #expect(all.days.count > 2000)
        #expect(all.days.reduce(UsageTotals()) { $0 + $1.totals } == all.total)
        #expect(all.days.first?.totals.totalTokens == 10)
        #expect(all.days.last?.totals.totalTokens == 20)
        #expect(all.days.contains { $0.interval.duration == 23 * 3600 })
        #expect(all.days.contains { $0.interval.duration == 25 * 3600 })
        #expect(
            zip(all.days, all.days.dropFirst()).allSatisfy {
                $0.interval.end == $1.interval.start && calendar.component(.hour, from: $1.interval.start) == 0
            })
    }

    @Test func allTimeFoldsImplausiblyOldDatesIntoTheOldestBucket() throws {
        let fixture = try Fixture()
        try makeDatabase(
            fixture,
            rollups: [
                "('1970-01-02', 'claude', 'p', 'm', '', 1, 5, 0, 0, 0, '1')",
                "('2026-11-01', 'claude', 'p', 'm', '', 1, 10, 0, 0, 0, '1')"
            ],
            logs: ["('a', 'claude', 'm', 20, 0, 0, 0, '1', 200, 'proxy', \(Int(Self.now.timeIntervalSince1970)))"])
        let all = try read(fixture, .all).get()
        #expect(all.days.count <= UsageHistoryReader.allTimeYears * 366 + 1)
        #expect(all.buckets.count <= UsageHistoryReader.allTimeYears * 12 + 1)
        #expect(all.days.first?.totals.totalTokens == 5)
        #expect(all.days.reduce(UsageTotals()) { $0 + $1.totals } == all.total)
    }

    private func read(
        _ fixture: Fixture, _ range: UsageHistoryRange, calendar: Calendar = Self.calendar
    ) -> Result<UsageHistory, UsageHistoryIssue> {
        let environment = UsageEnvironment(
            home: fixture.home, codexHome: fixture.home.appending(path: ".codex"),
            ccSwitchHome: fixture.home.appending(path: ".cc-switch"),
            supportDirectory: fixture.home.appending(path: "Tidemark"), credentials: fixture.credentials,
            transport: fixture.transport, now: { Self.now })
        return UsageHistoryReader(environment: environment).read(range, now: Self.now, calendar: calendar)
    }

    /// The columns Tidemark reads, with CC Switch's names and defaults.
    private func makeDatabase(_ fixture: Fixture, rollups: [String], logs: [String]) throws {
        let directory = fixture.home.appending(path: ".cc-switch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(directory.appending(path: "cc-switch.db").path, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE proxy_request_logs (
                request_id TEXT PRIMARY KEY, app_type TEXT NOT NULL, model TEXT NOT NULL, pricing_model TEXT,
                input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                total_cost_usd TEXT NOT NULL DEFAULT '0', status_code INTEGER NOT NULL,
                data_source TEXT NOT NULL DEFAULT 'proxy', created_at INTEGER NOT NULL,
                input_token_semantics INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE usage_daily_rollups (
                date TEXT NOT NULL, app_type TEXT NOT NULL, provider_id TEXT NOT NULL, model TEXT NOT NULL,
                pricing_model TEXT NOT NULL DEFAULT '',
                request_count INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                cache_creation_tokens INTEGER NOT NULL DEFAULT 0, total_cost_usd TEXT NOT NULL DEFAULT '0',
                input_token_semantics INTEGER NOT NULL DEFAULT 0);
            INSERT INTO usage_daily_rollups (date, app_type, provider_id, model, pricing_model, request_count,
                input_tokens,
                output_tokens, cache_read_tokens, cache_creation_tokens, total_cost_usd)
                VALUES \(rollups.joined(separator: ", "));
            INSERT INTO proxy_request_logs (request_id, app_type, model, input_tokens, output_tokens,
                cache_read_tokens, cache_creation_tokens, total_cost_usd, status_code, data_source, created_at)
                VALUES \(logs.joined(separator: ", "));
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}
