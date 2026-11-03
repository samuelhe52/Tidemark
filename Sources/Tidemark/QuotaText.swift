//
//  QuotaText.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import TidemarkData

/// User-facing wording for quota values, shared by the summary and the dashboard.
enum QuotaText {
    static func serviceName(_ service: QuotaService) -> String {
        switch service {
        case .claude: String(localized: "Claude Code")
        case .codex: String(localized: "Codex")
        }
    }

    static func shortServiceName(_ service: QuotaService) -> String {
        switch service {
        case .claude: String(localized: "Claude")
        case .codex: String(localized: "Codex")
        }
    }

    static func windowName(_ window: QuotaWindow) -> String {
        switch window.id {
        case "five_hour": String(localized: "5-hour")
        case "seven_day": String(localized: "Weekly")
        case "30_day": String(localized: "30-day")
        case "seven_day_opus": String(localized: "Weekly · Opus")
        case "seven_day_sonnet": String(localized: "Weekly · Sonnet")
        case "seven_day_fable": String(localized: "Weekly · Fable")
        default:
            window.duration.map { String(localized: "\(duration($0)) window") }
                ?? window.id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "5h", "7d": the window length in one token, for the one-line summary.
    static func shortWindowName(_ window: QuotaWindow) -> String {
        window.duration.map(duration) ?? ""
    }

    static func plan(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    static func source(_ source: QuotaSource) -> String {
        switch source {
        case .claudeCache: String(localized: "Cache")
        case .statusline: String(localized: "Statusline")
        case .rollout: String(localized: "Session log")
        case .live: String(localized: "Live")
        }
    }

    static func issue(_ issue: QuotaReadIssue, service: QuotaService) -> String {
        switch issue {
        case .missing: String(localized: "No local reading yet")
        case .unreadable: String(localized: "The local file could not be read")
        case .unrecognized: String(localized: "No quota in the local file")
        case .signedOut: String(localized: "Not signed in")
        case .credentialExpired:
            service == .claude
                ? String(localized: "Sign-in expired. Open Claude Code to renew it.")
                : String(localized: "Sign-in expired. Open Codex to renew it.")
        case .accessDenied: String(localized: "Access was denied")
        case .rateLimited: String(localized: "Rate limited. Tidemark will retry later.")
        case .requestFailed: String(localized: "Couldn't reach the usage service")
        case .notObserved: String(localized: "Not seen in use yet")
        }
    }

    /// Time until or since, in at most two units: "<1m", "42m", "3h 12m", "2d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return String(localized: "<1m") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        if minutes < 1440 {
            return minutes % 60 == 0
                ? String(localized: "\(minutes / 60)h") : String(localized: "\(minutes / 60)h \(minutes % 60)m")
        }
        let hours = minutes % 1440 / 60
        return hours == 0
            ? String(localized: "\(minutes / 1440)d") : String(localized: "\(minutes / 1440)d \(hours)h")
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return String(localized: "clock mismatch") }
        return seconds < 60 ? String(localized: "just now") : String(localized: "\(duration(seconds)) ago")
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// The window that runs out first, among those with a current reading.
    static func tightestWindow(_ account: AccountUsage, now: Date) -> (QuotaWindow, Double)? {
        account.windows.compactMap { window in window.remainingPercent(at: now).map { (window, $0) } }
            .min { $0.1 < $1.1 }
    }

    /// "Claude 5h 87% · Codex 7d 30%"
    static func summary(_ services: [ServiceUsage], now: Date) -> String {
        guard !services.isEmpty else { return String(localized: "Reading usage…") }
        return services.map { service in
            let name = shortServiceName(service.service)
            guard let account = service.accounts.first(where: \.isActive) ?? service.accounts.first,
                let (window, remaining) = tightestWindow(account, now: now)
            else { return "\(name) —" }
            return [name, shortWindowName(window), percent(remaining)].filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: "  ·  ")
    }
}
