//
//  RequestLog.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import SQLite3

public struct RequestLogCursor: Equatable, Sendable {
    public let createdAt: Int64
    public let requestID: String
}

public struct RequestLogEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let cursor: RequestLogCursor
    public var date: Date { Date(timeIntervalSince1970: Double(cursor.createdAt)) }
    public let app: String
    public let provider: String
    public let model: String
    /// CC Switch's display name for `model`, when its pricing table has one.
    public let modelName: String?
    public let cost: Double?
    public let input: Int64?
    public let output: Int64?
    public let cacheHit: Int64?
    public let cacheWrite: Int64?
    public let latencyMS: Double?
    public let firstTokenMS: Double?
    public let status: Int64?
    public let source: String
    public let multiplier: Double?
    public var isSession: Bool { !source.isEmpty && source != "proxy" }
    public var cacheInclusive: Bool { ["codex", "gemini", "grokbuild"].contains(app) }
}

public struct RequestLogPage: Sendable {
    public let entries: [RequestLogEntry]
    public let isComplete: Bool

    public init(entries: [RequestLogEntry], isComplete: Bool) {
        self.entries = entries
        self.isComplete = isComplete
    }
}

/// CC Switch c018907, src-tauri/src/services/usage_stats.rs::get_request_logs:
/// raw app/model projection, provider join and cross-source duplicate filter. No range filter;
/// request_id is added as a deterministic tie breaker.
/// Use stored costs without invoking upstream cost backfill.
public struct RequestLogReader: Sendable {
    private let database: URL
    public init(environment: UsageEnvironment) { database = environment.ccSwitchDatabase }
    public init(database: URL) { self.database = database }

    public func page(after: RequestLogCursor? = nil, newerThan: RequestLogCursor? = nil, limit: Int = 50) throws
        -> RequestLogPage
    {
        let count = max(1, min(500, limit))
        let entries = try read(after: after, newerThan: newerThan, limit: count + 1)
        return RequestLogPage(entries: Array(entries.prefix(count)), isComplete: entries.count <= count)
    }

    /// Authoritative snapshot from the newest row through the inclusive paging boundary.
    /// One range query avoids OFFSET paging and mixed snapshots. Materializes O(loaded rows);
    /// SQL sorting/deduplication cost additionally depends on the upstream database's indexes.
    public func loadedSpan(through bottom: RequestLogCursor) throws -> [RequestLogEntry] {
        try read(through: bottom)
    }

    private func read(
        after: RequestLogCursor? = nil, newerThan: RequestLogCursor? = nil,
        through: RequestLogCursor? = nil, limit: Int? = nil
    ) throws -> [RequestLogEntry] {
        let db = try ReadOnlyDatabase.open(database)
        defer { sqlite3_close_v2(db.handle) }
        // dedupFilter also reads counts; keep those and the range query in one snapshot.
        try db.query("BEGIN", bind: []) { _ in }
        var values: [ReadOnlyDatabase.Value] = []
        let dedup = try UsageHistoryReader.dedupFilter(db, start: Int64.min / 2, end: Int64.max / 2)
        var predicate = "1 = 1"
        for (cursor, comparison) in [(after, "<"), (newerThan, ">"), (through, ">=")] {
            if let cursor {
                predicate += " AND (l.created_at, l.request_id) \(comparison) (?, ?)"
                values += [.int(cursor.createdAt), .text(cursor.requestID)]
            }
        }
        if let limit { values.append(.int(Int64(limit))) }
        let names = ModelDisplayNames.read(db)
        var entries: [RequestLogEntry] = []
        try db.query(
            """
            SELECT l.request_id, l.created_at, l.app_type, l.provider_id, p.name, l.model,
              l.total_cost_usd, l.input_tokens, l.output_tokens, l.cache_read_tokens,
              l.cache_creation_tokens, l.latency_ms, l.first_token_ms, l.status_code,
              COALESCE(l.data_source, 'proxy'), l.cost_multiplier, l.input_token_semantics
            FROM proxy_request_logs l
            LEFT JOIN providers p ON l.provider_id = p.id AND l.app_type = p.app_type
            WHERE (\(dedup)) AND \(predicate)
            ORDER BY l.created_at DESC, l.request_id DESC \(limit == nil ? "" : "LIMIT ?")
            """, bind: values
        ) { row in
            func int(_ i: Int32) -> Int64? { row.isNull(i) ? nil : row.int(i) }
            func number(_ i: Int32) -> Double? { row.text(i).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
            let app = row.text(2) ?? ""
            let providerID = row.text(3) ?? ""
            // provider_name_coalesce + providerLabel.ts: joined names take precedence.
            let provider =
                row.text(4)
                ?? (providerID.hasPrefix("_") && providerID.hasSuffix("session") ? "Session logs" : providerID)
            var input = int(7)
            // src/types/usage.ts::getFreshInputTokens, as used by RequestLogTable.
            if ["codex", "gemini", "grokbuild"].contains(app),
                let raw = input, let hit = int(9), raw >= hit
            {
                input = raw - hit
            }
            let model = row.text(5) ?? ""
            entries.append(
                RequestLogEntry(
                    id: row.text(0) ?? "",
                    cursor: RequestLogCursor(createdAt: row.int(1), requestID: row.text(0) ?? ""),
                    app: app, provider: provider, model: model, modelName: names.name(for: model), cost: number(6),
                    input: input,
                    output: int(8), cacheHit: int(9), cacheWrite: int(10), latencyMS: number(11),
                    firstTokenMS: number(12), status: int(13), source: row.text(14) ?? "proxy", multiplier: number(15)))
        }
        return entries
    }
}
