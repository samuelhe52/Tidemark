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
        if let model = window.weeklyModel { return String(localized: "Weekly · \(model.capitalized)") }
        return switch window.id {
        case QuotaWindow.fiveHourID: String(localized: "5-hour")
        case QuotaWindow.sevenDayID: String(localized: "Weekly")
        case QuotaWindow.thirtyDayID: String(localized: "30-day")
        default:
            window.duration.map { String(localized: "\(duration($0)) window") }
                ?? window.id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "5h", "7d": the window length in one token, for the one-line summary.
    static func shortWindowName(_ window: QuotaWindow) -> String {
        window.duration.map(duration) ?? ""
    }

    /// The account's email, or a generic name when the service reported none.
    static func accountName(_ account: AccountUsage) -> String {
        account.email ?? String(localized: "Signed-in account")
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
                : String(localized: "Sign-in expired. Sign in again in CC Switch or Codex.")
        case .credentialChanged: String(localized: "Sign-in changed or is being renewed. Tidemark will retry.")
        case .credentialSaveFailed: String(localized: "Couldn't save the renewed sign-in. Check CC Switch.")
        case .accessDenied: String(localized: "Access was denied")
        case .rateLimited: String(localized: "Rate limited. Tidemark will retry later.")
        case .cliUnavailable: String(localized: "Claude Code wasn't found. Install it to see live usage.")
        case .cliFailed: String(localized: "Claude Code exited with an error. Check that it runs in Terminal.")
        case .requestFailed:
            service == .claude
                ? String(localized: "Couldn't refresh usage. Check the network or proxy.")
                : String(localized: "Couldn't reach the usage service")
        case .proxyUnavailable:
            String(localized: "Couldn't use the configured proxy. Check its address and proxy type.")
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

    static func percentageDescription(_ remaining: Double, style: QuotaPercentageStyle) -> String {
        let value = percent(style.value(remaining: remaining) ?? remaining)
        return style == .remaining ? String(localized: "\(value) left") : String(localized: "\(value) used")
    }

    static func resetTime(_ date: Date, style: QuotaResetTimeStyle, now: Date) -> String {
        if style == .countdown { return String(localized: "Resets in \(duration(date.timeIntervalSince(now)))") }
        return clockTime(date, now: now)
    }

    /// A one-line heads-up for the weekly window that will run out first at the current pace, if any.
    static func paceWarning(_ account: AccountUsage, style: QuotaResetTimeStyle, now: Date) -> String? {
        let soonest = account.windows.filter(\.isWeekly)
            .compactMap { window in window.projectedExhaustion(at: now).map { (window, $0) } }
            .min { $0.1 < $1.1 }
        guard let (window, date) = soonest else { return nil }
        let name = windowName(window)
        return style == .countdown
            ? String(localized: "Heads up: at this pace, \(name) runs out in \(duration(date.timeIntervalSince(now)))")
            : String(localized: "Heads up: at this pace, \(name) runs out \(clockTime(date, now: now))")
    }

    private static func clockTime(_ date: Date, now: Date) -> String {
        let format = DateFormatter()
        let calendar = Calendar.current
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "jm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now)
            && calendar.component(.era, from: date) == calendar.component(.era, from: now)
        {
            template = "MMMdjm"
        } else {
            template = "yMMMdjm"
        }
        format.setLocalizedDateFormatFromTemplate(template)
        return format.string(from: date)
    }

    static func summary(_ services: [ServiceUsage], preferences: QuotaDisplayPreferences, now: Date) -> String {
        guard !services.isEmpty else { return String(localized: "Reading usage…") }
        let entries = preferences.summaryAccounts(in: services)
        guard !entries.isEmpty else {
            return preferences.orderedAccounts(in: services, visibleOnly: true).isEmpty
                ? String(localized: "No visible accounts") : String(localized: "Summary off")
        }
        return entries.map { entry in
            let name = shortServiceName(entry.service)
            guard let account = entry.account, let (window, remaining) = tightestWindow(account, now: now) else {
                return "\(name) —"
            }
            return [name, shortWindowName(window), percentageDescription(remaining, style: preferences.percentageStyle)]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: "  ·  ")
    }
}
