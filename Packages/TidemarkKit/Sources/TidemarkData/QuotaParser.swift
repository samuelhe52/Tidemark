//
//  QuotaParser.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import CoreFoundation
import Foundation

/// Parses only quota and identity fields.
///
/// Unknown fields (including credentials and conversation text) are discarded.
enum QuotaParser {
    /// Claude windows Tidemark can name truthfully. Vendor codenames are dropped.
    static let claudeWindowIDs: Set<String> = [
        "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_fable"
    ]

    struct ClaudeCache: Equatable {
        let accountUUID: String?
        let windows: [QuotaWindow]
    }

    struct CodexUsage: Equatable {
        let email: String?
        let plan: String?
        let windows: [QuotaWindow]
    }

    static func claudeCache(_ data: Data) -> ClaudeCache? {
        guard let root = object(data),
            let cache = root["cachedUsageUtilization"] as? [String: Any],
            let milliseconds = number(cache["fetchedAtMs"]), milliseconds > 0,
            let utilization = cache["utilization"] as? [String: Any]
        else { return nil }
        let windows = claudeWindows(
            utilization, observedAt: Date(timeIntervalSince1970: milliseconds / 1000), source: .claudeCache)
        return windows.isEmpty ? nil : ClaudeCache(accountUUID: cache["accountUuid"] as? String, windows: windows)
    }

    static func claudeStatusline(_ data: Data) -> [QuotaWindow] {
        guard let root = object(data), let limits = root["rate_limits"] as? [String: Any],
            let received = number(root["received_at"]), received > 0
        else { return [] }
        return claudeWindows(limits, observedAt: Date(timeIntervalSince1970: received), source: .statusline)
    }

    /// The body of `GET api/oauth/usage`; nil when it is not a usage object.
    static func claudeUsage(_ data: Data, observedAt: Date) -> [QuotaWindow]? {
        guard let root = object(data) else { return nil }
        return claudeWindows(root, observedAt: observedAt, source: .live)
    }

    static func codexEvent(_ data: Data) -> [QuotaWindow] {
        guard let root = object(data), root["type"] as? String == "event_msg",
            let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
            let limits = payload["rate_limits"] as? [String: Any],
            let timestamp = root["timestamp"] as? String, let observedAt = date(timestamp)
        else { return [] }
        return codexWindows(
            ["primary", "secondary"].map { limits[$0] as? [String: Any] }, observedAt: observedAt, source: .rollout,
            seconds: { number($0["window_minutes"]).map { $0 * 60 } },
            reset: { reset($0["resets_at"]) })
    }

    /// The body of `GET backend-api/wham/usage`; nil when it is not a usage object.
    static func codexUsage(_ data: Data, observedAt: Date) -> CodexUsage? {
        guard let root = object(data), let limits = root["rate_limit"] as? [String: Any] else { return nil }
        let windows = codexWindows(
            ["primary_window", "secondary_window"].map { limits[$0] as? [String: Any] }, observedAt: observedAt,
            source: .live, seconds: { number($0["limit_window_seconds"]) },
            reset: { window in
                reset(window["reset_at"])
                    ?? number(window["reset_after_seconds"]).flatMap { seconds in
                        seconds >= 0 && seconds < 1e9 ? observedAt.addingTimeInterval(seconds) : nil
                    }
            })
        return CodexUsage(email: root["email"] as? String, plan: root["plan_type"] as? String, windows: windows)
    }

    /// The `exp` claim of a JWT access token. The signature is not checked; this only avoids
    /// sending a token that has certainly expired.
    static func tokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let exp = number(object(data)?["exp"]), exp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    static func windowID(seconds: TimeInterval?) -> String? {
        switch seconds {
        case 18000: "five_hour"
        case 604800: "seven_day"
        case 2_592_000: "30_day"
        case let seconds?: "window_\(Int(seconds))"
        case nil: nil
        }
    }

    // MARK: - Shared

    private static func codexWindows(
        _ rows: [[String: Any]?], observedAt: Date, source: QuotaSource,
        seconds: ([String: Any]) -> Double?, reset: ([String: Any]) -> Date?
    ) -> [QuotaWindow] {
        var seen = Set<String>()
        return rows.enumerated().compactMap { index, row in
            guard let row else { return nil }
            let duration = seconds(row).flatMap { $0 > 0 && $0 < 1e9 ? $0 : nil }
            let id = windowID(seconds: duration) ?? (index == 0 ? "primary" : "secondary")
            guard seen.insert(id).inserted else { return nil }
            return QuotaWindow(
                id: id, usedPercent: number(row["used_percent"]), resetsAt: reset(row),
                duration: duration, observedAt: observedAt, source: source)
        }
    }

    private static func claudeWindows(
        _ payload: [String: Any], observedAt: Date, source: QuotaSource
    ) -> [QuotaWindow] {
        var windows: [String: QuotaWindow] = [:]
        for id in claudeWindowIDs {
            guard let row = payload[id] as? [String: Any],
                row.keys.contains("utilization") || row.keys.contains("used_percentage")
            else { continue }
            windows[id] = claudeWindow(
                id: id, used: number(row["utilization"] ?? row["used_percentage"]),
                resetValue: row["resets_at"], observedAt: observedAt, source: source)
        }
        for row in payload["limits"] as? [[String: Any]] ?? [] {
            guard row["kind"] as? String == "weekly_scoped", row["group"] as? String == "weekly",
                let scope = row["scope"] as? [String: Any],
                scope["surface"] == nil || scope["surface"] is NSNull,
                let model = scope["model"] as? [String: Any],
                let name = model["display_name"] as? String,
                ["opus", "sonnet", "fable"].contains(name.lowercased()),
                let percent = number(row["percent"]), (0...100).contains(percent)
            else { continue }
            let id = "seven_day_\(name.lowercased())"
            windows[id] = claudeWindow(
                id: id, used: percent, resetValue: row["resets_at"], observedAt: observedAt, source: source)
        }
        return windows.values.sorted { $0.id < $1.id }
    }

    private static func claudeWindow(
        id: String, used: Double?, resetValue: Any?, observedAt: Date, source: QuotaSource
    ) -> QuotaWindow {
        QuotaWindow(
            id: id, usedPercent: used, resetsAt: reset(resetValue),
            duration: id == "five_hour" ? 18000 : 604800, observedAt: observedAt, source: source)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func reset(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0, seconds <= 253_402_300_799 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String { return date(string) }
        return nil
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    /// ISO 8601 with or without fractional seconds. Fractions longer than milliseconds
    /// (`…:59.580758+00:00`) are cut to three digits first.
    static func date(_ string: String) -> Date? {
        if let date = fractional.date(from: string) ?? whole.date(from: string) { return date }
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let digits = string[string.index(after: dot)...].prefix(while: \.isNumber)
        guard digits.count > 3 else { return nil }
        let trimmed = string[..<dot] + "." + digits.prefix(3) + string[digits.endIndex...]
        return fractional.date(from: String(trimmed))
    }
}
