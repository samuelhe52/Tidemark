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

/// How one service is represented in the compact summary.
public enum QuotaSummaryChoice: Hashable, Sendable {
    case automatic
    case account(String)
    case off

    /// The stored form: nil for Automatic, which is stored as an absent key; `off`; or `account:<id>`.
    public var storedValue: String? {
        switch self {
        case .automatic: nil
        case .off: "off"
        case .account(let id): "account:\(id)"
        }
    }

    /// Nil for a value that is not a stored choice.
    public init?(storedValue: String) {
        if storedValue == "off" {
            self = .off
        } else if storedValue.hasPrefix("account:") {
            self = .account(String(storedValue.dropFirst("account:".count)))
        } else {
            return nil
        }
    }
}

/// One service's place in the compact summary; `account` is nil when the selected account is absent.
public struct QuotaSummaryEntry: Equatable, Sendable {
    public let service: QuotaService
    public let account: AccountUsage?
}

/// Stable account identities and presentation choices, independent of UI and credential stores.
public struct QuotaDisplayPreferences: Equatable, Sendable {
    public var hiddenAccountIDs: Set<String> = []
    public var accountOrder: [String] = []
    /// Services without an entry use Automatic.
    public var summaryChoices: [QuotaService: QuotaSummaryChoice] = [:]
    public var percentageStyle: QuotaPercentageStyle = .remaining
    public var resetTimeStyle: QuotaResetTimeStyle = .countdown

    public init() {}

    /// `summaryChoices` as stored: service raw values to `QuotaSummaryChoice.storedValue`. Unknown
    /// services and values are dropped.
    public var storedSummaryChoices: [String: String] {
        get {
            Dictionary(
                uniqueKeysWithValues: summaryChoices.compactMap { service, choice in
                    choice.storedValue.map { (service.rawValue, $0) }
                })
        }
        set {
            summaryChoices = Dictionary(
                uniqueKeysWithValues: newValue.compactMap { key, value in
                    guard let service = QuotaService(rawValue: key),
                        let choice = QuotaSummaryChoice(storedValue: value)
                    else { return nil }
                    return (service, choice)
                })
        }
    }

    /// Repairs stored preferences: drops duplicate order entries, keeping the first, and summary
    /// choices that select a hidden account.
    public mutating func normalize() {
        var seen: Set<String> = []
        accountOrder = accountOrder.filter { seen.insert($0).inserted }
        summaryChoices = summaryChoices.filter { _, choice in
            if case .account(let id) = choice { return !hiddenAccountIDs.contains(id) }
            return true
        }
    }

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
            for (service, choice) in summaryChoices where choice == .account(accountID) {
                summaryChoices[service] = nil
            }
        }
    }

    public func summaryChoice(for service: QuotaService) -> QuotaSummaryChoice {
        summaryChoices[service] ?? .automatic
    }

    /// One entry per service that is not Off, in the order services first appear among visible accounts.
    ///
    /// Automatic prefers the visible active account. A missing explicit selection stays missing rather than
    /// silently showing another account.
    public func summaryAccounts(in services: [ServiceUsage]) -> [QuotaSummaryEntry] {
        let visible = orderedAccounts(in: services, visibleOnly: true)
        var order: [QuotaService] = []
        for account in visible where !order.contains(account.service) { order.append(account.service) }
        for service in QuotaService.allCases where !order.contains(service) {
            if case .account = summaryChoice(for: service) { order.append(service) }
        }
        return order.compactMap { service in
            switch summaryChoice(for: service) {
            case .off:
                return nil
            case .account(let id):
                return QuotaSummaryEntry(service: service, account: visible.first { $0.id == id })
            case .automatic:
                let candidates = visible.filter { $0.service == service }
                guard let first = candidates.first else { return nil }
                return QuotaSummaryEntry(service: service, account: candidates.first(where: \.isActive) ?? first)
            }
        }
    }
}
