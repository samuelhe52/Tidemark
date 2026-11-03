//
//  DefaultsKey.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// Every UserDefaults key Tidemark writes. Renaming one drops the user's saved value.
enum DefaultsKey {
    static let liveUsageEnabled = "liveUsageEnabled"
    static let hoverToExpand = "hoverToExpand"
    static let expansionDelay = "expansionDelay"
    static let retractionDelay = "retractionDelay"
    static let hiddenAccountIDs = "hiddenDashboardAccountIDs"
    static let accountOrder = "dashboardAccountOrder"
    static let summaryChoices = "compactSummaryChoices"
    static let percentageStyle = "quotaPercentageStyle"
    static let resetTimeStyle = "quotaResetTimeStyle"
    static let dockPlacement = "dockPlacement"
    static let historyRange = "usageHistoryRange"
    static let historyView = "usageHistoryView"
    static let keyboardShortcut = "companionKeyboardShortcut"
    /// An unreleased single-account summary choice, removed at launch.
    static let legacySummaryAccountID = "summaryAccountID"
}

extension UserDefaults {
    /// A JSON-encoded value; nil when absent or unreadable.
    func decoded<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Stores `value` as JSON, or removes the key for nil.
    func setEncoded<Value: Encodable>(_ value: Value?, forKey key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}
