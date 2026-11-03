//
//  QuotaDisplayPreferences.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

public enum QuotaPercentageStyle: String, Codable, CaseIterable, Sendable {
    case remaining, used

    public func value(remaining: Double?) -> Double? {
        remaining.map { self == .remaining ? $0 : 100 - $0 }
    }
}

public enum QuotaResetTimeStyle: String, Codable, CaseIterable, Sendable {
    case countdown, clock
}

/// Stable account identities and presentation choices, independent of UI and credential stores.
public struct QuotaDisplayPreferences: Equatable, Sendable {
    public var hiddenAccountIDs: Set<String> = []
    public var accountOrder: [String] = []
    public var summaryAccountID: String?
    public var percentageStyle: QuotaPercentageStyle = .remaining
    public var resetTimeStyle: QuotaResetTimeStyle = .countdown

    public init() {}

    public func orderedAccounts(in services: [ServiceUsage], visibleOnly: Bool = false) -> [AccountUsage] {
        let accounts = services.flatMap(\.accounts)
        // Ignore obsolete IDs and duplicate order entries; append newly discovered accounts stably.
        let indices = Dictionary(accountOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return accounts.enumerated()
            .filter { !visibleOnly || !hiddenAccountIDs.contains($0.element.id) }
            .sorted {
                let lhs = indices[$0.element.id] ?? Int.max
                let rhs = indices[$1.element.id] ?? Int.max
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
    }

    public mutating func setVisible(_ visible: Bool, accountID: String) {
        if visible {
            hiddenAccountIDs.remove(accountID)
        } else {
            hiddenAccountIDs.insert(accountID)
            if summaryAccountID == accountID { summaryAccountID = nil }
        }
    }

    /// Automatic keeps one visible account per service, preferring the active account.
    ///
    /// A missing explicit selection stays missing rather than silently showing another account.
    public func summaryAccounts(in services: [ServiceUsage]) -> [AccountUsage] {
        let visible = orderedAccounts(in: services, visibleOnly: true)
        if let summaryAccountID { return visible.filter { $0.id == summaryAccountID } }
        var seen: Set<QuotaService> = []
        return visible.compactMap { account in
            guard seen.insert(account.service).inserted else { return nil }
            return visible.first { $0.service == account.service && $0.isActive } ?? account
        }
    }
}
