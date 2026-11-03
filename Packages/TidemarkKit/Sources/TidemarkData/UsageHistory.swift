//
//  UsageHistory.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import SQLite3

/// The history scopes of the compact picker, resolved the way CC Switch's dashboard resolves them.
public enum UsageHistoryRange: String, CaseIterable, Codable, Sendable {
    case today
    case sevenDays = "7d"
    case fourteenDays = "14d"
    case thirtyDays = "30d"
    case all

    /// `today` starts at local midnight; `7d`, `14d` and `30d` at local midnight N−1 calendar days
    /// ago (counted by calendar days, so a DST change never shifts the start); `all` at the epoch.
    public func interval(endingAt now: Date, calendar: Calendar) -> DateInterval {
        let midnight = calendar.startOfDay(for: now)
        let days: Int
        switch self {
        case .today: days = 1
        case .sevenDays: days = 7
        case .fourteenDays: days = 14
        case .thirtyDays: days = 30
        case .all: return DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
        }
        let start =
            calendar.date(byAdding: .day, value: 1 - days, to: midnight).map(calendar.startOfDay) ?? midnight
        return DateInterval(start: min(start, now), end: now)
    }

    /// Chart buckets: hours for today, days for the day ranges, months for all time.
    public var bucketUnit: Calendar.Component {
        switch self {
        case .today: .hour
        case .sevenDays, .fourteenDays, .thirtyDays: .day
        case .all: .month
        }
    }
}

/// Token and API-equivalent cost totals. Input counts fresh tokens only, so the four token
/// kinds add up without counting cache reads twice.
public struct UsageTotals: Equatable, Sendable {
    public var requests: Int
    /// What the same tokens would cost at API prices; not a bill.
    public var costUSD: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(
        requests: Int = 0, costUSD: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0,
        cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0
    ) {
        self.requests = requests
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    public var isEmpty: Bool { requests == 0 && totalTokens == 0 }

    public static func + (lhs: Self, rhs: Self) -> Self {
        UsageTotals(
            requests: lhs.requests + rhs.requests, costUSD: lhs.costUSD + rhs.costUSD,
            inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// Usage grouped under one key: an app type or a model.
public struct UsageGroup: Identifiable, Equatable, Sendable {
    public var id: String { key }
    /// For apps, CC Switch's app type with `claude-desktop` folded into `claude`; for models, the
    /// pricing model when set, else the reported model.
    public let key: String
    public let totals: UsageTotals

    public init(key: String, totals: UsageTotals) {
        self.key = key
        self.totals = totals
    }
}

/// One bar of the chart: a local hour, day or month.
public struct UsageBucket: Equatable, Sendable {
    public let interval: DateInterval
    public let totals: UsageTotals
}

public struct UsageHistory: Equatable, Sendable {
    public let range: UsageHistoryRange
    public let interval: DateInterval
    /// Apps with any usage in the range, most tokens first.
    public let apps: [UsageGroup]
    /// Models with any usage in the range, most tokens first.
    public let models: [UsageGroup]
    /// Consecutive buckets in `range.bucketUnit`, oldest first, including empty ones. All time
    /// starts at the month of the first usage.
    public let buckets: [UsageBucket]
    /// The newest detail row CC Switch recorded, in any range; tells how current the history is.
    public let latestRecordAt: Date?

    public var total: UsageTotals { apps.reduce(UsageTotals()) { $0 + $1.totals } }
}

public enum UsageHistoryIssue: Error, Equatable, Sendable {
    /// No CC Switch database.
    case missing
    /// The database could not be opened or was busy.
    case unreadable
    /// The tables or columns are not the ones Tidemark knows.
    case unrecognized
}

/// Reads CC Switch's usage history read-only. Totals follow its dashboard queries
/// (`get_usage_summary_by_app`, `get_model_stats` and `get_daily_trends` in CC Switch's
/// `services/usage_stats.rs`, commit `c018907`); one grouped query feeds all three views, so they
/// always add up to the same total.
public struct UsageHistoryReader: Sendable {
    private let database: URL

    public init(environment: UsageEnvironment) {
        database = environment.ccSwitchDatabase
    }

    /// One grouped row: a detail quarter-hour or a rollup day, for one app and model.
    private struct Slice {
        let date: Date
        let app: String
        let model: String
        let totals: UsageTotals
    }

    /// Detail rows are grouped by quarter hour. Every current UTC offset is a multiple of 15 minutes,
    /// so local hour, day and month boundaries never split a group.
    private static let slotSeconds: Int64 = 900

    public func read(
        _ range: UsageHistoryRange, now: Date, calendar: Calendar = .current
    ) -> Result<UsageHistory, UsageHistoryIssue> {
        guard FileManager.default.fileExists(atPath: database.path) else { return .failure(.missing) }
        // `mode=ro` still reads the WAL; `immutable=1` would not.
        var components = URLComponents()
        components.scheme = "file"
        components.path = database.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        var handle: OpaquePointer?
        defer { sqlite3_close_v2(handle) }
        guard let uri = components.string,
            sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
            let handle
        else { return .failure(.unreadable) }
        sqlite3_busy_timeout(handle, 2000)
        let connection = ReadOnlyDatabase(handle: handle)

        let interval = range.interval(endingAt: now, calendar: calendar)
        let start = Int64(interval.start.timeIntervalSince1970.rounded(.down))
        let end = Int64(interval.end.timeIntervalSince1970.rounded(.down))
        let days = Self.rollupDays(start: interval.start, end: interval.end, calendar: calendar)
        let formatter = Self.dayFormatter(calendar)
        do {
            let dedup = try Self.dedupFilter(connection, start: start, end: end)
            let rollupWhere = days.map { _ in "WHERE r.date >= ?3 AND r.date <= ?4" } ?? "WHERE 1 = 0"
            let sql = """
                SELECT 0, (l.created_at / \(Self.slotSeconds)) * \(Self.slotSeconds),
                    \(Self.foldedAppType("l")), \(Self.effectiveModel("l")), COUNT(*),
                    COALESCE(SUM(CAST(l.total_cost_usd AS REAL)), 0),
                    COALESCE(SUM(\(Self.freshInput("l"))), 0),
                    COALESCE(SUM(l.output_tokens), 0),
                    COALESCE(SUM(l.cache_creation_tokens), 0),
                    COALESCE(SUM(l.cache_read_tokens), 0)
                FROM proxy_request_logs l
                WHERE \(dedup) AND l.created_at >= ?1 AND l.created_at <= ?2
                GROUP BY 2, 3, 4
                UNION ALL
                SELECT 1, r.date, \(Self.foldedAppType("r")), \(Self.effectiveModel("r")),
                    COALESCE(SUM(r.request_count), 0),
                    COALESCE(SUM(CAST(r.total_cost_usd AS REAL)), 0),
                    COALESCE(SUM(\(Self.freshInput("r"))), 0),
                    COALESCE(SUM(r.output_tokens), 0),
                    COALESCE(SUM(r.cache_creation_tokens), 0),
                    COALESCE(SUM(r.cache_read_tokens), 0)
                FROM usage_daily_rollups r \(rollupWhere)
                GROUP BY 2, 3, 4
                """
            var slices: [Slice] = []
            try connection.query(sql, bind: [.int(start), .int(end), .text(days?.first ?? ""), .text(days?.last ?? "")])
            { row in
                let date =
                    row.int(0) == 0
                    ? Date(timeIntervalSince1970: TimeInterval(row.int(1)))
                    : row.text(1).flatMap(formatter.date(from:))
                let totals = UsageTotals(
                    requests: Int(row.int(4)), costUSD: row.double(5), inputTokens: Int(row.int(6)),
                    outputTokens: Int(row.int(7)), cacheCreationTokens: Int(row.int(8)),
                    cacheReadTokens: Int(row.int(9)))
                guard let date, !totals.isEmpty else { return }
                slices.append(Slice(date: date, app: row.text(2) ?? "", model: row.text(3) ?? "", totals: totals))
            }
            var latest: Int64?
            try connection.query("SELECT MAX(created_at) FROM proxy_request_logs", bind: []) { row in
                latest = row.isNull(0) ? nil : row.int(0)
            }
            return .success(
                UsageHistory(
                    range: range, interval: interval, apps: Self.group(slices, by: \.app),
                    models: Self.group(slices, by: \.model),
                    buckets: Self.buckets(slices, range: range, interval: interval, calendar: calendar),
                    latestRecordAt: latest.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
        } catch let issue as UsageHistoryIssue {
            return .failure(issue)
        } catch {
            return .failure(.unreadable)
        }
    }

    // MARK: - Grouping

    private static func group(_ slices: [Slice], by key: KeyPath<Slice, String>) -> [UsageGroup] {
        var totals: [String: UsageTotals] = [:]
        for slice in slices { totals[slice[keyPath: key], default: UsageTotals()] += slice.totals }
        return totals.map { UsageGroup(key: $0.key, totals: $0.value) }
            .sorted { ($0.totals.totalTokens, $1.key) > ($1.totals.totalTokens, $0.key) }
    }

    private static func buckets(
        _ slices: [Slice], range: UsageHistoryRange, interval: DateInterval, calendar: Calendar
    ) -> [UsageBucket] {
        let unit = range.bucketUnit
        let first: Date
        if range == .all {
            let earliest = slices.map(\.date).min() ?? interval.end
            first = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
        } else {
            first = interval.start
        }
        // Today shows every hour of the day; other ranges end with the bucket holding now.
        let last =
            range == .today
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: interval.end)) ?? interval.end
            : calendar.dateInterval(of: unit, for: interval.end)?.end ?? interval.end
        var starts: [Date] = []
        var cursor = first
        while cursor < last, starts.count < 2000 {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        guard !starts.isEmpty else { return [] }
        var totals = Array(repeating: UsageTotals(), count: starts.count)
        for slice in slices {
            // The last start at or before the slice.
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= slice.date { low = mid } else { high = mid - 1 }
            }
            totals[low] += slice.totals
        }
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : last
            return UsageBucket(interval: DateInterval(start: starts[index], end: end), totals: totals[index])
        }
    }

    // MARK: - CC Switch's query rules

    /// The whole local days the range covers, as `yyyy-MM-dd`: the start day counts only from
    /// its midnight, the end day only from 23:59. Nil when no whole day is covered.
    static func rollupDays(start: Date, end: Date, calendar: Calendar) -> [String]? {
        let startDay = calendar.startOfDay(for: start)
        let first = startDay == start ? startDay : calendar.date(byAdding: .day, value: 1, to: startDay)
        let parts = calendar.dateComponents([.hour, .minute], from: end)
        let endDay = calendar.startOfDay(for: end)
        let last =
            parts.hour == 23 && parts.minute == 59 ? endDay : calendar.date(byAdding: .day, value: -1, to: endDay)
        guard let first, let last, first <= last else { return nil }
        let formatter = dayFormatter(calendar)
        return [formatter.string(from: first), formatter.string(from: last)]
    }

    /// CC Switch's rollup `date`: a local Gregorian `yyyy-MM-dd`, whatever the user's calendar.
    static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = gregorian
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// `effective_model_sql`: the pricing model when set, else the reported model.
    static func effectiveModel(_ alias: String) -> String {
        "COALESCE(NULLIF(\(alias).pricing_model, ''), \(alias).model)"
    }

    /// `fresh_input_sql`: OpenAI-style apps count cache tokens inside `input_tokens`.
    static func freshInput(_ alias: String) -> String {
        let a = alias
        let inclusive = "('codex', 'gemini', 'grokbuild')"
        return """
            CASE WHEN \(a).input_token_semantics = 2 THEN \(a).input_tokens \
            WHEN \(a).app_type IN \(inclusive) AND \(a).input_token_semantics = 1 \
            AND \(a).input_tokens >= (\(a).cache_read_tokens + \(a).cache_creation_tokens) \
            THEN (\(a).input_tokens - \(a).cache_read_tokens - \(a).cache_creation_tokens) \
            WHEN \(a).app_type IN \(inclusive) AND \(a).input_token_semantics = 0 \
            AND \(a).input_tokens >= \(a).cache_read_tokens \
            THEN (\(a).input_tokens - \(a).cache_read_tokens) \
            ELSE \(a).input_tokens END
            """
    }

    static func foldedAppType(_ alias: String) -> String {
        "CASE WHEN \(alias).app_type = 'claude-desktop' THEN 'claude' ELSE \(alias).app_type END"
    }

    /// `effective_usage_log_filter_for_range`: drop session-imported rows that repeat a successful
    /// proxy row within ten minutes. Skipped when the window lacks either kind of row.
    static func dedupFilter(_ connection: ReadOnlyDatabase, start: Int64, end: Int64) throws -> String {
        let window: Int64 = 600
        let lo = start - window
        let hi = end + window
        let sessions = "'session_log', 'codex_session', 'gemini_session', 'opencode_session'"
        var counts: (proxy: Int64, session: Int64) = (0, 0)
        try connection.query(
            """
            SELECT
                COALESCE(SUM(CASE WHEN COALESCE(c.data_source, 'proxy') = 'proxy'
                    AND c.status_code >= 200 AND c.status_code < 300 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN COALESCE(c.data_source, 'proxy') IN (\(sessions)) THEN 1 ELSE 0 END), 0)
            FROM proxy_request_logs c WHERE c.created_at BETWEEN ?1 AND ?2
            """, bind: [.int(lo), .int(hi)]
        ) { row in counts = (row.int(0), row.int(1)) }
        guard counts.proxy > 0, counts.session > 0 else { return "1 = 1" }
        let source = "COALESCE(s.data_source, 'proxy')"
        return """
            l.rowid NOT IN (
                SELECT s.rowid
                FROM proxy_request_logs p
                JOIN proxy_request_logs s
                  ON s.app_type IN (p.app_type, CASE WHEN p.app_type = 'claude-desktop' THEN 'claude' ELSE p.app_type END)
                 AND \(source) IN (\(sessions))
                 AND s.input_tokens = p.input_tokens
                 AND s.output_tokens = p.output_tokens
                 AND s.cache_read_tokens = p.cache_read_tokens
                 AND s.created_at BETWEEN p.created_at - \(window) AND p.created_at + \(window)
                 AND (
                     p.cache_creation_tokens = s.cache_creation_tokens
                     OR (s.cache_creation_tokens = 0
                         AND \(source) IN ('codex_session', 'gemini_session', 'opencode_session'))
                     OR (p.cache_creation_tokens = 0 AND p.input_token_semantics = 0
                         AND \(source) = 'codex_session')
                 )
                 AND (LOWER(p.model) = LOWER(s.model) OR LOWER(p.model) = 'unknown' OR LOWER(s.model) = 'unknown')
                WHERE COALESCE(p.data_source, 'proxy') = 'proxy'
                  AND p.status_code >= 200 AND p.status_code < 300
                  AND p.created_at BETWEEN \(lo) AND \(hi)
            )
            """
    }
}

// MARK: - A minimal read-only SQLite wrapper

struct ReadOnlyDatabase {
    let handle: OpaquePointer

    enum Value {
        case int(Int64)
        case text(String)
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    }

    func query(_ sql: String, bind values: [Value], row: (Row) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            // A missing table or column is a format change; anything else is a read failure.
            throw prepared == SQLITE_ERROR ? UsageHistoryIssue.unrecognized : UsageHistoryIssue.unreadable
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, Int32(index + 1), number)
            case .text(let text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw UsageHistoryIssue.unreadable
            }
        }
    }
}
