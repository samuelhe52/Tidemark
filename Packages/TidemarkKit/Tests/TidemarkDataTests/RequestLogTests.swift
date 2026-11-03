//
//  RequestLogTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import SQLite3
import Testing

@testable import TidemarkData

struct RequestLogTests {
    @Test func preferencesMigrateMoveAndReset() {
        var columns = RequestLogColumns(
            storedOrder: ["model", "unknown", "app", "model"], storedHidden: ["app", "unknown"])
        #expect(columns.order.count == RequestLogColumn.allCases.count)
        #expect(Set(columns.order).count == columns.order.count)
        #expect(columns.order.firstIndex(of: .model)! < columns.order.firstIndex(of: .app)!)
        #expect(columns.order.firstIndex(of: .provider) == 1)
        #expect(columns.hidden.contains(.app))
        #expect(columns.hidden.contains(.cacheWrite))
        columns.setVisible(true, .cost)
        columns.move(.cost, toVisibleIndex: 0)
        #expect(columns.visible.first == .cost)
        columns.move(.statusCode, to: 0)
        #expect(columns.order.first == .statusCode)
        columns.reset()
        #expect(columns == .standard)
        #expect(columns.visible == [.app, .model, .speed, .firstToken, .totalTime])
        #expect(RequestLogColumns(storedOrder: [], storedHidden: []).visible == columns.visible)

        let original = columns.order
        let hidden = columns.hidden
        // Drop app onto model: the destination is just after model before removal.
        columns.move(.app, to: 3)
        #expect(columns.order == [.provider, .model, .app] + Array(original.dropFirst(3)))
        // Drop back onto the first row from below.
        columns.move(.app, to: 0)
        #expect(columns.order == original)
        columns.move(.app, to: 1)
        #expect(columns.order == original)
        columns.move(.app, to: columns.order.count)
        #expect(columns.order == Array(original.dropFirst()) + [.app])
        columns.move(.app, to: -1)
        #expect(columns.order == original)
        columns.move(.statusCode, to: columns.order.count + 1)
        #expect(columns.order == original)
        // Native header reordering still uses a final visible index, skipping hidden columns.
        columns.move(.app, toVisibleIndex: 2)
        #expect(columns.visible == [.model, .speed, .app, .firstToken, .totalTime])
        columns.move(.app, toVisibleIndex: 0)
        #expect(columns.visible == RequestLogColumns.standard.visible)
        #expect(columns.hidden == hidden)
    }

    @Test func fixturePagesNewerRowsProvidersAndDedupAreReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: String(cString: sqlite3_errmsg(db)), code: 1)
            }
        }
        try execute(
            """
            CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, PRIMARY KEY(id, app_type));
            INSERT INTO providers VALUES ('p', 'claude-desktop', 'Desktop provider'), ('p', 'codex', 'Codex provider');
            CREATE TABLE proxy_request_logs (
              request_id TEXT PRIMARY KEY, created_at INTEGER, app_type TEXT, provider_id TEXT,
              model TEXT, total_cost_usd TEXT, input_tokens INTEGER, output_tokens INTEGER,
              cache_read_tokens INTEGER, cache_creation_tokens INTEGER, latency_ms INTEGER,
              first_token_ms INTEGER, status_code INTEGER, data_source TEXT, cost_multiplier TEXT,
              input_token_semantics INTEGER);
            INSERT INTO proxy_request_logs VALUES
              ('a', 100, 'codex', '_codex_session', 'gpt', '0.1', 1000, 300, 600, 0, 2000, NULL, 200, 'codex_session', '1', 0),
              ('b', 100, 'codex', 'p', 'gpt', '0.2', 2000, 400, 100, 0, 3000, 500, 200, 'proxy', '1', 0),
              ('c', 101, 'claude-desktop', 'p', 'Claude', '0.3', 10, 50, 20, 3, 4000, 600, 200, NULL, '1', 0),
              ('duplicate', 102, 'claude', '_session', 'claude', '0.3', 10, 50, 20, 3, 4000, 600, 200, 'session_log', '1', 0),
              ('failed-proxy', 103, 'codex', 'p', 'gpt', '0', 1000, 300, 600, 0, 1000, NULL, 500, 'proxy', '1', 0);
            """)
        let before = try Data(contentsOf: url)
        let reader = RequestLogReader(database: url)
        let head = try reader.page(limit: 2)
        #expect(head.entries.map(\.id) == ["failed-proxy", "c"])
        #expect(head.entries.last?.provider == "Desktop provider")
        #expect(!head.isComplete)
        let second = try reader.page(after: head.entries.last?.cursor, limit: 2)
        #expect(second.entries.map(\.id) == ["b", "a"])
        #expect(second.isComplete)
        #expect(second.entries[0].provider == "Codex provider")
        #expect(second.entries[1].provider == "Session logs")
        #expect(second.entries[1].input == 400)
        #expect(try Data(contentsOf: url) == before)
        try execute(
            "INSERT INTO proxy_request_logs SELECT 'new', 104, app_type, provider_id, model, total_cost_usd, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms, first_token_ms, status_code, data_source, cost_multiplier, input_token_semantics FROM proxy_request_logs WHERE request_id = 'b'"
        )
        let newer = try reader.page(newerThan: head.entries.first?.cursor)
        #expect(newer.entries.map(\.id) == ["new"])
        #expect(try reader.page(after: second.entries.last?.cursor).entries.isEmpty)
        let ro = try ReadOnlyDatabase.open(url)
        defer { sqlite3_close_v2(ro.handle) }
        #expect(sqlite3_exec(ro.handle, "DELETE FROM proxy_request_logs", nil, nil, nil) == SQLITE_READONLY)

        let bottom = try #require(second.entries.last?.cursor)
        #expect(try reader.loadedSpan(through: bottom).map(\.id) == ["new", "failed-proxy", "c", "b", "a"])
        // Tie sorts below the previous top; imported session lands inside the loaded range.
        try execute(
            """
            INSERT INTO proxy_request_logs
              SELECT 'm-tied', 104, app_type, provider_id, model, total_cost_usd, input_tokens,
                output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms, first_token_ms,
                status_code, data_source, cost_multiplier, input_token_semantics
              FROM proxy_request_logs WHERE request_id = 'b';
            INSERT INTO proxy_request_logs
              SELECT 'imported', 101, app_type, '_codex_session', model, total_cost_usd, 9999,
                output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms, first_token_ms,
                status_code, 'codex_session', cost_multiplier, input_token_semantics
              FROM proxy_request_logs WHERE request_id = 'b';
            UPDATE proxy_request_logs SET total_cost_usd = '9.5' WHERE request_id = 'b';
            """)
        let refreshed = try reader.loadedSpan(through: bottom)
        #expect(refreshed.map(\.id) == ["new", "m-tied", "failed-proxy", "imported", "c", "b", "a"])
        #expect(refreshed.first(where: { $0.id == "b" })?.cost == 9.5)
        // A successful proxy now hides the already loaded bottom session. The original
        // boundary still works even though its row is no longer in the filtered result.
        try execute(
            """
            INSERT INTO proxy_request_logs
              SELECT 'replacement', 105, app_type, 'p', model, total_cost_usd, input_tokens,
                output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms, first_token_ms,
                status_code, 'proxy', cost_multiplier, input_token_semantics
              FROM proxy_request_logs WHERE request_id = 'a';
            INSERT INTO proxy_request_logs
              SELECT 'older', 99, app_type, provider_id, model, total_cost_usd, input_tokens,
                output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms, first_token_ms,
                status_code, data_source, cost_multiplier, input_token_semantics
              FROM proxy_request_logs WHERE request_id = 'b';
            WITH RECURSIVE ids(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM ids WHERE n < 60)
            INSERT INTO proxy_request_logs
              SELECT 'bulk-' || n, 102, app_type, provider_id, model, total_cost_usd, input_tokens,
                output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms, first_token_ms,
                status_code, data_source, cost_multiplier, input_token_semantics
              FROM ids CROSS JOIN proxy_request_logs WHERE request_id = 'b';
            """)
        let beforeRefresh = try Data(contentsOf: url)
        let reconciled = try reader.loadedSpan(through: bottom)
        #expect(reconciled.count == 67)
        #expect(!reconciled.contains(where: { $0.id == "a" || $0.id == "duplicate" || $0.id == "older" }))
        #expect(reconciled.first?.id == "replacement")
        #expect(reconciled.contains(where: { $0.id == "imported" }))
        #expect(try reader.page().entries.count == 50)
        #expect(try reader.page(after: bottom).entries.map(\.id) == ["older"])
        #expect(try Data(contentsOf: url) == beforeRefresh)
    }
}
