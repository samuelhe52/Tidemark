//
//  SettingsStore.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation
import Observation
import TidemarkData
import TidemarkEngine

/// Shared by settings, dashboard controls, and the companion.
///
/// Only Tidemark defaults are written.
@Observable @MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    var liveUsageEnabled: Bool {
        didSet {
            defaults.set(liveUsageEnabled, forKey: "liveUsageEnabled")
            onChange?()
        }
    }
    var hoverToExpand: Bool {
        didSet {
            defaults.set(hoverToExpand, forKey: "hoverToExpand")
            onChange?()
        }
    }
    var expansionDelay: Double {
        didSet {
            defaults.set(expansionDelay, forKey: "expansionDelay")
            onChange?()
        }
    }
    var retractionDelay: Double {
        didSet {
            defaults.set(retractionDelay, forKey: "retractionDelay")
            onChange?()
        }
    }
    var display: QuotaDisplayPreferences {
        didSet {
            defaults.set(display.hiddenAccountIDs.sorted(), forKey: "hiddenDashboardAccountIDs")
            defaults.set(display.accountOrder, forKey: "dashboardAccountOrder")
            defaults.set(Self.encode(display.summaryChoices), forKey: "compactSummaryChoices")
            defaults.set(display.percentageStyle.rawValue, forKey: "quotaPercentageStyle")
            defaults.set(display.resetTimeStyle.rawValue, forKey: "quotaResetTimeStyle")
            onChange?()
        }
    }
    private var services: [ServiceUsage] = []
    var accounts: [AccountUsage] { services.flatMap(\.accounts) }

    var behavior: CompanionBehavior {
        CompanionBehavior(
            hoverToExpand: hoverToExpand, expansionDelay: expansionDelay, retractionDelay: retractionDelay)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        liveUsageEnabled = defaults.bool(forKey: "liveUsageEnabled")
        hoverToExpand = defaults.object(forKey: "hoverToExpand") as? Bool ?? true
        let normalized = CompanionBehavior(
            expansionDelay: defaults.object(forKey: "expansionDelay") as? Double ?? 0.6,
            retractionDelay: defaults.object(forKey: "retractionDelay") as? Double ?? 0.4)
        expansionDelay = normalized.expansionDelay
        retractionDelay = normalized.retractionDelay
        var display = QuotaDisplayPreferences()
        display.hiddenAccountIDs = Set(defaults.stringArray(forKey: "hiddenDashboardAccountIDs") ?? [])
        var seen: Set<String> = []
        display.accountOrder = (defaults.stringArray(forKey: "dashboardAccountOrder") ?? [])
            .filter { seen.insert($0).inserted }
        // The earlier single-account choice was never released; its service is unknown until usage loads.
        defaults.removeObject(forKey: "summaryAccountID")
        display.summaryChoices = Self.decode(
            defaults.dictionary(forKey: "compactSummaryChoices") as? [String: String] ?? [:])
        display.percentageStyle =
            defaults.string(forKey: "quotaPercentageStyle")
            .flatMap(QuotaPercentageStyle.init(rawValue:)) ?? .remaining
        display.resetTimeStyle =
            defaults.string(forKey: "quotaResetTimeStyle")
            .flatMap(QuotaResetTimeStyle.init(rawValue:)) ?? .countdown
        display.summaryChoices = display.summaryChoices.filter { _, choice in
            if case .account(let id) = choice { return !display.hiddenAccountIDs.contains(id) }
            return true
        }
        self.display = display
    }

    /// Automatic is stored as an absent key; Off as `off`; an account as `account:<id>`.
    private static func encode(_ choices: [QuotaService: QuotaSummaryChoice]) -> [String: String] {
        var encoded: [String: String] = [:]
        for (service, choice) in choices {
            switch choice {
            case .automatic: break
            case .off: encoded[service.rawValue] = "off"
            case .account(let id): encoded[service.rawValue] = "account:\(id)"
            }
        }
        return encoded
    }

    private static func decode(_ stored: [String: String]) -> [QuotaService: QuotaSummaryChoice] {
        var choices: [QuotaService: QuotaSummaryChoice] = [:]
        for (key, value) in stored {
            guard let service = QuotaService(rawValue: key) else { continue }
            if value == "off" {
                choices[service] = .off
            } else if value.hasPrefix("account:") {
                choices[service] = .account(String(value.dropFirst("account:".count)))
            }
        }
        return choices
    }

    func updateAccounts(_ services: [ServiceUsage]) {
        if self.services != services { self.services = services }
        let known = Set(display.accountOrder)
        let discovered = accounts.map(\.id).filter { !known.contains($0) }
        if !discovered.isEmpty { display.accountOrder.append(contentsOf: discovered) }
    }

    var orderedAccounts: [AccountUsage] {
        display.orderedAccounts(in: services)
    }

    func setVisible(_ visible: Bool, accountID: String) {
        display.setVisible(visible, accountID: accountID)
    }

    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        var current = orderedAccounts.map(\.id)
        // `destination` counts positions before removal, matching SwiftUI's `onMove`.
        let moving = source.filter(current.indices.contains).map { current[$0] }
        let insertion = destination - source.count(in: 0..<destination)
        current = current.indices.filter { !source.contains($0) }.map { current[$0] }
        current.insert(contentsOf: moving, at: min(max(0, insertion), current.count))
        // Preserve absent accounts' slots so reappearing accounts recover their saved position.
        let present = Set(current)
        var iterator = current.makeIterator()
        display.accountOrder = display.accountOrder.map { present.contains($0) ? iterator.next() ?? $0 : $0 }
    }
}
