//
//  PassiveQuotaParser.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import CoreFoundation
import Foundation

/// Parses only quota fields. Unknown fields (including credentials and conversation text) are discarded.
public enum PassiveQuotaParser {
    public static func claudeCache(_ data: Data) -> [QuotaWindow] {
        guard let root = object(data),
            let cache = root["cachedUsageUtilization"] as? [String: Any],
            let milliseconds = number(cache["fetchedAtMs"]), milliseconds > 0,
            let utilization = cache["utilization"] as? [String: Any]
        else { return [] }
        return claudeWindows(
            utilization, observedAt: Date(timeIntervalSince1970: milliseconds / 1000), source: .claudeCache)
    }

    public static func claudeStatusline(_ data: Data) -> [QuotaWindow] {
        guard let root = object(data), let limits = root["rate_limits"] as? [String: Any],
            let received = number(root["received_at"]), received > 0
        else { return [] }
        return claudeWindows(limits, observedAt: Date(timeIntervalSince1970: received), source: .statusline)
    }

    public static func codexEvent(_ data: Data) -> [QuotaWindow] {
        guard let root = object(data), root["type"] as? String == "event_msg",
            let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count",
            let limits = payload["rate_limits"] as? [String: Any],
            let timestamp = root["timestamp"] as? String, let observedAt = date(timestamp)
        else { return [] }
        var seen = Set<String>()
        return ["primary", "secondary"].compactMap { name in
            guard let window = limits[name] as? [String: Any] else { return nil }
            let minutes = number(window["window_minutes"])
            let duration = minutes.flatMap { $0 > 0 ? $0 * 60 : nil }
            let id: String
            switch duration {
            case 18000: id = "five_hour"
            case 604800: id = "seven_day"
            case 2_592_000: id = "30_day"
            default: id = duration.map { "window_\($0)" } ?? name
            }
            guard seen.insert(id).inserted else { return nil }
            return QuotaWindow(
                id: id, usedPercent: number(window["used_percent"]), resetsAt: reset(window["resets_at"]),
                duration: duration, observedAt: observedAt, source: .rollout)
        }
    }

    private static func claudeWindows(
        _ payload: [String: Any], observedAt: Date, source: QuotaSource
    ) -> [QuotaWindow] {
        var windows: [String: QuotaWindow] = [:]
        for (id, value) in payload where id != "extra_usage" {
            guard let row = value as? [String: Any],
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
            duration: id == "five_hour" ? 18000 : (id.hasPrefix("seven_day") ? 604800 : nil),
            observedAt: observedAt, source: source)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
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

    private static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
