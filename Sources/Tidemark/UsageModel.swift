//
//  UsageModel.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation
import TidemarkData

/// Loads quota usage and CC Switch history for the companion, and decides when to reload.
///
/// Passive files are reread every minute; the usage service rate-limits live requests on its own.
/// Nothing reloads while `isSuspended`.
@MainActor
final class UsageModel {
    private(set) var usage: [ServiceUsage] = []
    private(set) var refreshedAt: Date?
    private(set) var history: DashboardView.History
    var isRefreshing: Bool { usageLoad.isRunning }
    /// True while the Mac sleeps or the screen is locked.
    var isSuspended = false
    /// Runs when the dashboard should show new figures; the argument says whether to animate.
    var onChange: ((_ animated: Bool) -> Void)?

    private let settings: SettingsStore
    private let service: UsageService
    private let historyReader: UsageHistoryReader
    private let usageLoad = SingleFlight()
    private let historyLoad = SingleFlight()
    private let proxyOverride: ProxyOverride
    private var appliedLiveEnabled: Bool
    private var appliedProxyAddress: String
    private var lastRefresh = Date.distantPast
    private var timer: Timer?

    init(settings: SettingsStore) {
        self.settings = settings
        appliedLiveEnabled = settings.liveUsageEnabled
        appliedProxyAddress = settings.proxyAddress
        proxyOverride = ProxyOverride(settings.proxyAddress)
        let environment = UsageEnvironment.current(proxyOverride: proxyOverride)
        service = UsageService(environment: environment, liveEnabled: settings.liveUsageEnabled)
        historyReader = UsageHistoryReader(environment: environment)
        history = DashboardView.History(range: settings.historyRange, view: settings.historyView)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSuspended else { return }
                self.refresh(userInitiated: false)
            }
        }
        refresh(userInitiated: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        usageLoad.cancel()
        historyLoad.cancel()
    }

    /// Reloads usage and history. While a load runs, only a user's request queues another, which
    /// then also runs as the user's.
    func refresh(userInitiated: Bool) {
        refreshHistory()
        guard !usageLoad.isRunning else {
            if userInitiated { usageLoad.run({ [service] in await service.refresh(userInitiated: true) }, then: apply) }
            return
        }
        usageLoad.run({ [service] in await service.refresh(userInitiated: userInitiated) }, then: apply)
        // Shows the spinner.
        onChange?(false)
    }

    /// For the companion appearing: figures read in the last few seconds are fresh enough.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) >= 5 { refresh(userInitiated: false) }
    }

    /// Follows the Live Usage and proxy settings; changing either refreshes at once.
    func settingsChanged() {
        let proxy = settings.proxyAddress
        if proxy != appliedProxyAddress {
            appliedProxyAddress = proxy
            proxyOverride.address = proxy
            // Only live requests use the proxy. A Live Usage change refreshes below.
            if settings.liveUsageEnabled && appliedLiveEnabled { refresh(userInitiated: true) }
        }
        guard appliedLiveEnabled != settings.liveUsageEnabled else { return }
        let enabled = settings.liveUsageEnabled
        appliedLiveEnabled = enabled
        Task { [service] in
            await service.setLiveEnabled(enabled)
            self.refresh(userInitiated: true)
        }
    }

    private func apply(_ result: [ServiceUsage]) {
        usage = result
        settings.updateAccounts(result)
        refreshedAt = .now
        lastRefresh = .now
        onChange?(true)
    }

    // MARK: - History

    func setHistoryRange(_ range: UsageHistoryRange) {
        guard range != history.range else { return }
        settings.historyRange = range
        history.range = range
        history.issue = nil
        // The picker already shows the new range; the rows change once its figures arrive.
        refreshHistory()
    }

    func setHistoryView(_ view: DashboardView.HistoryView) {
        guard view != history.view else { return }
        settings.historyView = view
        history.view = view
        onChange?(true)
    }

    /// Reads CC Switch's database off the main actor; requests during a read coalesce into one rerun.
    private func refreshHistory() {
        let range = history.range
        historyLoad.run(
            { [historyReader] in
                await Task.detached(priority: .utility) { historyReader.read(range, now: Date()) }.value
            },
            then: { [weak self] result in
                guard let self, range == self.history.range else { return }
                switch result {
                case .success(let usage):
                    self.history.usage = usage
                    self.history.issue = nil
                case .failure(let issue):
                    // Keep the last good figures for this range beside the issue.
                    self.history.issue = issue
                }
                self.onChange?(true)
            })
    }
}
