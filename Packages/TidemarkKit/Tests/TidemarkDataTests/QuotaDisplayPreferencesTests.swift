//
//  QuotaDisplayPreferencesTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import Testing

@testable import TidemarkData

struct QuotaDisplayPreferencesTests {
    private func account(_ id: String, _ service: QuotaService, active: Bool = false) -> AccountUsage {
        AccountUsage(id: id, service: service, email: nil, plan: nil, isActive: active, windows: [], issue: nil)
    }

    @Test func globalOrderSurvivesMissingAccountsAndAppendsDiscoveries() {
        let claude = account("claude", .claude)
        let codex = account("codex", .codex)
        let other = account("other", .codex)
        let new = account("new", .claude)
        var preferences = QuotaDisplayPreferences()
        preferences.accountOrder = ["codex", "absent", "claude", "other", "codex"]
        let services = [
            ServiceUsage(service: .claude, accounts: [new, claude]),
            ServiceUsage(service: .codex, accounts: [other, codex])
        ]
        #expect(preferences.orderedAccounts(in: services).map(\.id) == ["codex", "claude", "other", "new"])
        preferences.setVisible(false, accountID: "claude")
        #expect(preferences.orderedAccounts(in: services, visibleOnly: true).map(\.id) == ["codex", "other", "new"])
        #expect(preferences.accountOrder.contains("absent"))
    }

    @Test func automaticSummaryUsesVisibleActiveAccountsAndRespectsProviderOrder() {
        let services = [
            ServiceUsage(service: .claude, accounts: [account("c", .claude, active: true)]),
            ServiceUsage(service: .codex, accounts: [account("x", .codex, active: true), account("y", .codex)])
        ]
        var preferences = QuotaDisplayPreferences()
        preferences.accountOrder = ["y", "c", "x"]
        #expect(preferences.summaryAccounts(in: services).map(\.account?.id) == ["x", "c"])
        preferences.setVisible(false, accountID: "x")
        #expect(preferences.summaryAccounts(in: services).map(\.account?.id) == ["y", "c"])
        preferences.setVisible(false, accountID: "y")
        preferences.setVisible(false, accountID: "c")
        #expect(preferences.summaryAccounts(in: services).isEmpty)
    }

    @Test func explicitSummaryChoiceAffectsOnlyItsServiceAndNeverSubstitutes() {
        let services = [
            ServiceUsage(service: .claude, accounts: [account("claude", .claude)]),
            ServiceUsage(
                service: .codex, accounts: [account("active", .codex, active: true), account("chosen", .codex)])
        ]
        var preferences = QuotaDisplayPreferences()
        preferences.summaryChoices[.codex] = .account("chosen")
        #expect(preferences.summaryAccounts(in: services).map(\.account?.id) == ["claude", "chosen"])
        preferences.summaryChoices[.claude] = .off
        #expect(preferences.summaryAccounts(in: services).map(\.account?.id) == ["chosen"])
        preferences.summaryChoices[.codex] = .account("absent")
        #expect(preferences.summaryAccounts(in: services) == [QuotaSummaryEntry(service: .codex, account: nil)])
        preferences.summaryChoices = [.claude: .account("claude"), .codex: .account("chosen")]
        preferences.setVisible(false, accountID: "chosen")
        #expect(preferences.summaryChoices == [.claude: .account("claude")])
        #expect(preferences.summaryAccounts(in: services).map(\.account?.id) == ["claude", "active"])
    }

    @Test func storedSummaryChoicesRoundTripAndDropUnknownEntries() {
        var preferences = QuotaDisplayPreferences()
        preferences.summaryChoices = [.claude: .off, .codex: .account("codex:managed:a")]
        #expect(preferences.storedSummaryChoices == ["claude": "off", "codex": "account:codex:managed:a"])
        preferences.summaryChoices[.claude] = .automatic
        #expect(preferences.storedSummaryChoices == ["codex": "account:codex:managed:a"])
        preferences.storedSummaryChoices = ["claude": "account:c", "codex": "bogus", "gemini": "off", "unknown": "off"]
        #expect(preferences.summaryChoices == [.claude: .account("c"), .gemini: .off])
    }

    @Test func normalizeDropsDuplicateOrderAndChoicesForHiddenAccounts() {
        var preferences = QuotaDisplayPreferences()
        preferences.accountOrder = ["b", "a", "b", "c", "a"]
        preferences.hiddenAccountIDs = ["x"]
        preferences.summaryChoices = [.claude: .account("x"), .codex: .account("y")]
        preferences.normalize()
        #expect(preferences.accountOrder == ["b", "a", "c"])
        #expect(preferences.summaryChoices == [.codex: .account("y")])
    }

    @Test func percentageStylesPreserveUnknownReadingsAndTheirBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000)
        for style in QuotaPercentageStyle.allCases {
            #expect(style.value(remaining: nil) == nil)
            for (used, age, reset) in [(20.0, 1800.0, 100.0), (20, 0, -1), (20, -1, 100)] {
                let window = QuotaWindow(
                    id: "five_hour", usedPercent: used, resetsAt: now.addingTimeInterval(reset), duration: 18000,
                    observedAt: now.addingTimeInterval(-age), source: .live)
                #expect(style.value(remaining: window.remainingPercent(at: now)) == nil)
            }
        }
        #expect(QuotaPercentageStyle.used.value(remaining: 0) == 100)
        #expect(QuotaPercentageStyle.used.value(remaining: 100) == 0)
        #expect(QuotaPercentageStyle.remaining.value(remaining: 37) == 37)
        #expect(QuotaPercentageStyle.used.value(remaining: 37) == 63)
    }

    @Test func summaryWindowDefaultsToWeeklyAndHonorsPerServiceSelection() {
        let now = Date(timeIntervalSince1970: 10_000)
        func window(_ id: String, used: Double) -> QuotaWindow {
            QuotaWindow(
                id: id, usedPercent: used, resetsAt: now.addingTimeInterval(3600), duration: 3600,
                observedAt: now, source: .live)
        }

        let claude = AccountUsage(
            id: "claude:local", service: .claude, email: nil, plan: nil, isActive: true,
            windows: [window("five_hour", used: 90), window("seven_day", used: 20), window("seven_day_opus", used: 80)],
            issue: nil)
        let gemini = AccountUsage(
            id: "gemini:local", service: .gemini, email: nil, plan: nil, isActive: true,
            windows: [
                window("five_hour_gemini", used: 30), window("seven_day_gemini", used: 10),
                window("five_hour_3p", used: 100), window("seven_day_3p", used: 60)
            ],
            issue: nil)
        let gemini3POnly = AccountUsage(
            id: "gemini:local", service: .gemini, email: nil, plan: nil, isActive: true,
            windows: [window("five_hour_3p", used: 40), window("seven_day_3p", used: 25)],
            issue: nil)
        let weeklyOnlyCodex = AccountUsage(
            id: "codex:local", service: .codex, email: nil, plan: nil, isActive: true,
            windows: [window("seven_day", used: 15)],
            issue: nil)

        var preferences = QuotaDisplayPreferences()
        // Defaults to weekly, preferring overall seven_day and Gemini's own bucket.
        #expect(preferences.summaryWindow(for: claude, at: now)?.window.id == "seven_day")
        #expect(preferences.summaryWindow(for: gemini, at: now)?.window.id == "seven_day_gemini")
        #expect(preferences.summaryWindow(for: gemini3POnly, at: now)?.window.id == "seven_day_3p")

        // Per-service selection: 5-hour on Gemini, lowest remaining on Claude, 5-hour fallback on weekly-only Codex.
        preferences.summaryWindows[.gemini] = .fiveHour
        preferences.summaryWindows[.claude] = .lowestRemaining
        preferences.summaryWindows[.codex] = .fiveHour
        #expect(preferences.summaryWindow(for: gemini, at: now)?.window.id == "five_hour_gemini")
        #expect(preferences.summaryWindow(for: gemini3POnly, at: now)?.window.id == "five_hour_3p")
        #expect(preferences.summaryWindow(for: claude, at: now)?.window.id == "five_hour")
        #expect(preferences.summaryWindow(for: weeklyOnlyCodex, at: now)?.window.id == "seven_day")

        // Stored round-trip omits default (.weekly) and drops unknown entries.
        #expect(
            preferences.storedSummaryWindows == [
                "claude": "lowestRemaining", "codex": "fiveHour", "gemini": "fiveHour"
            ])
        preferences.storedSummaryWindows = [
            "claude": "weekly", "codex": "fiveHour", "gemini": "bogus", "unknown": "fiveHour"
        ]
        #expect(preferences.summaryWindows == [.codex: .fiveHour])
    }
}
