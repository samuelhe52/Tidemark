//
//  QuotaObservation.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

public enum QuotaService: String, CaseIterable, Codable, Sendable {
    case claude, codex
}

public enum QuotaSource: String, Codable, Sendable {
    case claudeCache, statusline, rollout, live
}

public enum QuotaFreshness: Equatable, Sendable {
    case current, aging, stale, expired, unknown
}

public struct QuotaWindow: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let duration: TimeInterval?
    public let observedAt: Date
    public let source: QuotaSource

    public init(
        id: String, usedPercent: Double?, resetsAt: Date?, duration: TimeInterval?,
        observedAt: Date, source: QuotaSource
    ) {
        self.id = id
        self.usedPercent = usedPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        self.resetsAt = resetsAt
        self.duration = duration
        self.observedAt = observedAt
        self.source = source
    }

    public func freshness(at now: Date) -> QuotaFreshness {
        let age = now.timeIntervalSince(observedAt)
        guard age >= 0, usedPercent != nil else { return .unknown }
        if let resetsAt, now >= resetsAt { return .expired }
        if age >= 1800 { return .stale }
        return age >= 120 ? .aging : .current
    }

    public func remainingPercent(at now: Date) -> Double? {
        switch freshness(at: now) {
        case .current, .aging: usedPercent.map { 100 - $0 }
        case .stale, .expired, .unknown: nil
        }
    }
}

extension QuotaWindow {
    public static let fiveHourID = "five_hour"
    public static let sevenDayID = "seven_day"
    public static let thirtyDayID = "30_day"

    /// Window IDs with a fixed length. Any other length is `window_<seconds>`.
    static let namedDurations: [String: TimeInterval] = [
        fiveHourID: 18000, sevenDayID: 604_800, thirtyDayID: 2_592_000
    ]

    /// Claude models with their own weekly window, lowercased as the vendor reports them. Adding a
    /// model here is enough for Tidemark to read and name its window.
    static let claudeModels = ["opus", "sonnet", "fable"]

    static func weeklyID(model: String) -> String { "\(sevenDayID)_\(model)" }

    /// The model a model-scoped weekly window covers, lowercased; nil for any other window.
    public var weeklyModel: String? {
        let prefix = "\(Self.sevenDayID)_"
        guard id.hasPrefix(prefix) else { return nil }
        let model = String(id.dropFirst(prefix.count))
        return Self.claudeModels.contains(model) ? model : nil
    }
}

extension QuotaWindow {
    /// Shortest stretch of a window that says anything about its pace; earlier readings swing wildly.
    static let minimumPaceElapsed: TimeInterval = 3600

    /// Whether this is a weekly window, overall or for one model.
    public var isWeekly: Bool { id == Self.sevenDayID || weeklyModel != nil }

    /// When the window runs out if usage continues at its average pace since the window opened.
    ///
    /// Nil unless the reading is current, the window has a known length and reset, enough of it has
    /// elapsed to judge, something was used, and the projected moment falls before the reset.
    /// The pace is measured at the observation, so an aging reading does not skew it.
    public func projectedExhaustion(at now: Date) -> Date? {
        switch freshness(at: now) {
        case .current, .aging: break
        case .stale, .expired, .unknown: return nil
        }
        guard let usedPercent, usedPercent > 0, usedPercent < 100, let resetsAt, let duration, duration > 0 else {
            return nil
        }
        let elapsed = observedAt.timeIntervalSince(resetsAt.addingTimeInterval(-duration))
        guard elapsed >= Self.minimumPaceElapsed else { return nil }
        let exhaustion = observedAt.addingTimeInterval(elapsed * (100 - usedPercent) / usedPercent)
        return exhaustion > now && exhaustion < resetsAt ? exhaustion : nil
    }
}

public enum QuotaReadIssue: String, Equatable, Codable, Sendable {
    /// Passive file states.
    case missing, unreadable, unrecognized
    /// Live is on, but the agent has no usable sign-in.
    case signedOut
    /// The sign-in expired or its managed renewal was rejected.
    case credentialExpired
    /// The account changed during renewal, or another Tidemark process is renewing it.
    case credentialChanged
    /// Renewal succeeded but its rotated credentials could not be saved.
    case credentialSaveFailed
    /// The Keychain read was denied or cancelled, or the service answered 401/403.
    case accessDenied
    /// The service answered 429, or Tidemark is backing off after it.
    case rateLimited
    /// Network error, server error, or an unreadable answer.
    case requestFailed
    /// An account without a recorded reading while live queries are disabled.
    case notObserved
}

/// One account's newest observation. Windows always come from a single observation.
public struct AccountUsage: Identifiable, Equatable, Sendable {
    /// Managed Codex accounts use `codex:managed:<localId>`; workspace IDs alone are not unique users.
    public let id: String
    public let service: QuotaService
    public let email: String?
    /// The vendor's plan string as reported, such as `pro` or `plus`.
    public let plan: String?
    /// The account the agent is signed in with right now.
    public let isActive: Bool
    public let windows: [QuotaWindow]
    /// Why current data is missing or not live; nil when nothing went wrong.
    public let issue: QuotaReadIssue?

    public init(
        id: String, service: QuotaService, email: String?, plan: String?, isActive: Bool,
        windows: [QuotaWindow], issue: QuotaReadIssue?
    ) {
        self.id = id
        self.service = service
        self.email = email
        self.plan = plan
        self.isActive = isActive
        self.windows = windows
        self.issue = issue
    }
}

public struct ServiceUsage: Identifiable, Equatable, Sendable {
    public var id: QuotaService { service }
    public let service: QuotaService
    /// Never empty: the active account (or a placeholder) first, then the others by email.
    public let accounts: [AccountUsage]

    public init(service: QuotaService, accounts: [AccountUsage]) {
        self.service = service
        self.accounts = accounts
    }
}
