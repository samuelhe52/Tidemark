//
//  HistoryText.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import TidemarkData

/// User-facing wording for CC Switch usage history.
enum HistoryText {
    static func range(_ range: UsageHistoryRange) -> String {
        switch range {
        case .today: String(localized: "Today")
        case .sevenDays: String(localized: "7 days")
        case .fourteenDays: String(localized: "14 days")
        case .thirtyDays: String(localized: "30 days")
        case .all: String(localized: "All time")
        }
    }

    static func view(_ view: DashboardView.HistoryView) -> String {
        switch view {
        case .chart: String(localized: "Over time")
        case .harness: String(localized: "By harness")
        case .model: String(localized: "By model")
        }
    }

    static func symbol(_ view: DashboardView.HistoryView) -> String {
        switch view {
        case .chart: "chart.bar.xaxis"
        case .harness: "square.stack.3d.up"
        case .model: "cpu"
        }
    }

    static func modelName(_ model: String) -> String {
        model.isEmpty || model.lowercased() == "unknown" ? String(localized: "Unknown model") : model
    }

    /// CC Switch's display name when it has one, else the model ID. With `shortClaude`, a
    /// "Claude " prefix goes from display names: "Claude Opus 5.5" → "Opus 5.5". Raw IDs stay whole.
    static func modelName(_ model: String, displayName: String?, shortClaude: Bool) -> String {
        guard let displayName else { return modelName(model) }
        let prefix = "Claude "
        if shortClaude, displayName.hasPrefix(prefix), displayName.count > prefix.count {
            return String(displayName.dropFirst(prefix.count))
        }
        return displayName
    }

    /// A chart bucket's start: "14:00", "Nov 2", "Nov 2026".
    static func bucket(_ start: Date, unit: Calendar.Component) -> String {
        switch unit {
        case .hour: start.formatted(date: .omitted, time: .shortened)
        case .month: start.formatted(.dateTime.month(.abbreviated).year())
        default: start.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// "412M tokens · $81.20 · 1,203 requests"
    static func summary(_ totals: UsageTotals, requests: Bool = true) -> String {
        var parts = [String(localized: "\(tokens(totals.totalTokens)) tokens"), cost(totals.costUSD)]
        if requests { parts.append(String(localized: "\(totals.requests.formatted()) requests")) }
        return parts.joined(separator: " · ")
    }

    /// CC Switch's app types, named as CC Switch names their session sources.
    static func appName(_ appType: String) -> String {
        switch appType {
        case "claude": String(localized: "Claude Code")
        case "codex": String(localized: "Codex")
        case "gemini": String(localized: "Gemini CLI")
        case "opencode": String(localized: "OpenCode")
        case "grokbuild": String(localized: "Grok Build")
        case "omp": String(localized: "Oh My Pi")
        case "pi": String(localized: "Pi")
        default: appType.prefix(1).uppercased() + appType.dropFirst()
        }
    }

    /// "6.4B", "812K", "950".
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Whole dollars from $100; cents below, where they still mean something.
    static func cost(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd >= 100 ? 0 : 2)))
    }

    static func breakdown(_ totals: UsageTotals) -> String {
        [
            String(localized: "Input \(tokens(totals.inputTokens))"),
            String(localized: "Output \(tokens(totals.outputTokens))"),
            String(localized: "Cache write \(tokens(totals.cacheCreationTokens))"),
            String(localized: "Cache read \(tokens(totals.cacheReadTokens))"),
            String(localized: "\(totals.requests) requests")
        ].joined(separator: " · ")
    }

    static func issue(_ issue: UsageHistoryIssue) -> String {
        switch issue {
        case .missing: String(localized: "No CC Switch history found")
        case .unreadable: String(localized: "CC Switch history could not be read")
        case .unrecognized: String(localized: "CC Switch history is in an unknown format")
        }
    }
}
