//
//  RequestLogText.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import TidemarkData

/// CC Switch c018907: src/components/usage/{RequestLogTable.tsx,format.ts},
/// src/types/usage.ts (getFreshInputTokens/isUnpricedUsage). USD display, no currency conversion.
enum RequestLogText {
    static func title(_ column: RequestLogColumn) -> String {
        let resource: LocalizedStringResource =
            switch column {
            case .app: "App"
            case .provider: "Provider"
            case .model: "Model"
            case .cost: "Cost"
            case .freshInput: "Fresh Input"
            case .output: "Output"
            case .cacheHit: "Cache Hit"
            case .cacheWrite: "Cache Write"
            case .hitRate: "Hit Rate"
            case .speed: "Speed"
            case .firstToken: "TTFT"
            case .totalTime: "Total Time"
            case .statusCode: "Status Code"
            }
        return String(localized: resource)
    }

    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if abs(value) < 10_000 { return value.formatted() }
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (index, unit) in units.enumerated() where Double(abs(value)) >= unit.0 {
            let scaled = Double(String(format: "%.3g", Double(value) / unit.0))!
            if abs(scaled) >= 1000, index > 0 {
                return String(format: "%.3g", Double(value) / units[index - 1].0) + units[index - 1].1
            }
            return scaled.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) + unit.1
        }
        return String(value)
    }

    static func time(_ entry: RequestLogEntry, full: Bool = false) -> String {
        let format =
            full ? "yyyy-MM-dd HH:mm:ss" : Calendar.current.isDateInToday(entry.date) ? "HH:mm:ss" : "MM-dd HH:mm"
        return timeFormatter(format).string(from: entry.date)
    }

    /// Fitting columns formats every loaded row, and creating a formatter costs far more than using one.
    private static var timeFormatters: [String: DateFormatter] = [:]

    private static func timeFormatter(_ format: String) -> DateFormatter {
        if let formatter = timeFormatters[format] { return formatter }
        let formatter = DateFormatter()
        // Long-lived, so these must follow the system's locale and time zone.
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        timeFormatters[format] = formatter
        return formatter
    }

    static func value(_ column: RequestLogColumn, _ e: RequestLogEntry, shortClaude: Bool) -> String {
        let approximate = e.isSession ? "≈" : ""
        switch column {
        case .app:
            return [
                "claude": "Claude", "claude-desktop": "Desktop", "codex": "Codex", "gemini": "Gemini",
                "opencode": "OpenCode", "grokbuild": "Grok", "mcode": "MiniMax", "kimi": "Kimi", "pi": "Pi",
                "omp": "omp", "agy": "Antigravity", "dsh": "DSH", "openclaw": "OpenClaw", "hermes": "Hermes"
            ][e.app] ?? e.app
        case .provider: return e.provider.isEmpty ? "—" : e.provider
        case .model:
            return e.model.isEmpty && e.modelName == nil
                ? "—" : HistoryText.modelName(e.model, displayName: e.modelName, shortClaude: shortClaude)
        case .cost:
            guard let cost = e.cost else { return "—" }
            if cost == 0, e.multiplier != 0, let status = e.status, (200..<300).contains(status),
                [e.input, e.output, e.cacheHit, e.cacheWrite].contains(where: { ($0 ?? 0) > 0 })
            {
                return String(localized: "Unpriced")
            }
            return "$" + cost.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(4)))
        case .freshInput: return tokens(e.input)
        case .output: return tokens(e.output)
        case .cacheHit: return (e.cacheHit ?? 0) > 0 ? tokens(e.cacheHit) : "—"
        case .cacheWrite: return !e.cacheInclusive && (e.cacheWrite ?? 0) > 0 ? tokens(e.cacheWrite) : "—"
        case .hitRate:
            guard let input = e.input, let hit = e.cacheHit, let write = e.cacheWrite else { return "—" }
            let total = Double(input) + Double(hit) + Double(write)
            guard total > 0 else { return "—" }
            let percent = min(100, max(0, Double(hit) / total * 100))
            return percent >= 100 ? "100%" : String(format: "%.1f%%", floor(percent * 10) / 10)
        case .speed:
            guard let output = e.output, let latency = e.latencyMS else { return "—" }
            let duration: Double
            if e.isSession {
                guard output >= 200, latency >= 1000 else { return "—" }
                duration = latency
            } else {
                guard output >= 100, let first = e.firstTokenMS, latency - first >= 100 else { return "—" }
                duration = latency - first
            }
            let speed = Double(output) * 1000 / duration
            return approximate + String(format: speed >= 1 ? "%.0f tok/s" : "%.1f tok/s", speed)
        case .firstToken:
            guard let ms = e.firstTokenMS, ms >= 0 else { return "—" }
            return approximate + String(format: "%.1fs", ms / 1000)
        case .totalTime:
            guard let ms = e.latencyMS, ms > 0 else { return "—" }
            return approximate + String(format: "%.1fs", ms / 1000)
        case .statusCode: return e.status.map(String.init) ?? "—"
        }
    }
}
