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
    /// Runs after a setting that changes behavior or display; not for state the companion saves itself.
    var onChange: (() -> Void)?

    var liveUsageEnabled: Bool {
        didSet { save(liveUsageEnabled, DefaultsKey.liveUsageEnabled) }
    }
    /// A valid proxy for live usage requests, or empty to use the shell's and the system's.
    var proxyAddress: String {
        didSet { save(proxyAddress, DefaultsKey.proxyAddress) }
    }
    var hoverToExpand: Bool {
        didSet { save(hoverToExpand, DefaultsKey.hoverToExpand) }
    }
    var expansionDelay: Double {
        didSet { save(expansionDelay, DefaultsKey.expansionDelay) }
    }
    var retractionDelay: Double {
        didSet { save(retractionDelay, DefaultsKey.retractionDelay) }
    }
    var display: QuotaDisplayPreferences {
        didSet {
            defaults.set(display.hiddenAccountIDs.sorted(), forKey: DefaultsKey.hiddenAccountIDs)
            defaults.set(display.accountOrder, forKey: DefaultsKey.accountOrder)
            defaults.set(display.storedSummaryChoices, forKey: DefaultsKey.summaryChoices)
            defaults.set(display.percentageStyle.rawValue, forKey: DefaultsKey.percentageStyle)
            save(display.resetTimeStyle.rawValue, DefaultsKey.resetTimeStyle)
        }
    }

    var requestLogColumns: RequestLogColumns {
        didSet {
            defaults.set(requestLogColumns.order.map(\.rawValue), forKey: DefaultsKey.requestLogColumnOrder)
            defaults.set(requestLogColumns.hidden.map(\.rawValue), forKey: DefaultsKey.requestLogHiddenColumns)
            onChange?()
        }
    }

    /// Shows "Claude Opus 5.5" as "Opus 5.5" wherever a model's display name appears.
    var shortClaudeModelNames: Bool {
        didSet { save(shortClaudeModelNames, DefaultsKey.shortClaudeModelNames) }
    }

    var historyChartStyle: DashboardView.HistoryChartStyle {
        didSet { save(historyChartStyle.rawValue, DefaultsKey.historyChartStyle) }
    }

    // The companion's own state: saved, but never reported through `onChange`.

    /// Nil until the companion is first placed.
    @ObservationIgnored var dockPlacement: DockPlacement? {
        didSet { defaults.setEncoded(dockPlacement, forKey: DefaultsKey.dockPlacement) }
    }
    @ObservationIgnored var historyRange: UsageHistoryRange {
        didSet { defaults.set(historyRange.rawValue, forKey: DefaultsKey.historyRange) }
    }
    @ObservationIgnored var historyView: DashboardView.HistoryView {
        didSet { defaults.set(historyView.rawValue, forKey: DefaultsKey.historyView) }
    }

    private var services: [ServiceUsage] = []
    var accounts: [AccountUsage] { services.flatMap(\.accounts) }

    var behavior: CompanionBehavior {
        CompanionBehavior(
            hoverToExpand: hoverToExpand, expansionDelay: expansionDelay, retractionDelay: retractionDelay)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requestLogColumns = RequestLogColumns(
            storedOrder: defaults.stringArray(forKey: DefaultsKey.requestLogColumnOrder),
            storedHidden: defaults.stringArray(forKey: DefaultsKey.requestLogHiddenColumns))
        liveUsageEnabled = defaults.bool(forKey: DefaultsKey.liveUsageEnabled)
        shortClaudeModelNames = defaults.bool(forKey: DefaultsKey.shortClaudeModelNames)
        let proxy = defaults.string(forKey: DefaultsKey.proxyAddress)?.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyAddress = proxy.flatMap { ProxyOverride.isValid($0) ? $0 : nil } ?? ""
        hoverToExpand = defaults.object(forKey: DefaultsKey.hoverToExpand) as? Bool ?? true
        let normalized = CompanionBehavior(
            expansionDelay: defaults.object(forKey: DefaultsKey.expansionDelay) as? Double ?? 0.6,
            retractionDelay: defaults.object(forKey: DefaultsKey.retractionDelay) as? Double ?? 0.4)
        expansionDelay = normalized.expansionDelay
        retractionDelay = normalized.retractionDelay
        var display = QuotaDisplayPreferences()
        display.hiddenAccountIDs = Set(defaults.stringArray(forKey: DefaultsKey.hiddenAccountIDs) ?? [])
        display.accountOrder = defaults.stringArray(forKey: DefaultsKey.accountOrder) ?? []
        // The earlier single-account choice was never released; its service is unknown until usage loads.
        defaults.removeObject(forKey: DefaultsKey.legacySummaryAccountID)
        display.storedSummaryChoices =
            defaults.dictionary(forKey: DefaultsKey.summaryChoices) as? [String: String] ?? [:]
        display.percentageStyle =
            defaults.string(forKey: DefaultsKey.percentageStyle)
            .flatMap(QuotaPercentageStyle.init(rawValue:)) ?? .remaining
        display.resetTimeStyle =
            defaults.string(forKey: DefaultsKey.resetTimeStyle)
            .flatMap(QuotaResetTimeStyle.init(rawValue:)) ?? .countdown
        display.normalize()
        self.display = display
        dockPlacement = defaults.decoded(DockPlacement.self, forKey: DefaultsKey.dockPlacement)
        historyRange = defaults.string(forKey: DefaultsKey.historyRange).flatMap(UsageHistoryRange.init) ?? .today
        historyChartStyle =
            defaults.string(forKey: DefaultsKey.historyChartStyle)
            .flatMap(DashboardView.HistoryChartStyle.init) ?? .heatmap
        historyView =
            defaults.string(forKey: DefaultsKey.historyView).flatMap(DashboardView.HistoryView.init) ?? .chart
    }

    /// Saves a behavior or display setting and reports the change.
    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
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
