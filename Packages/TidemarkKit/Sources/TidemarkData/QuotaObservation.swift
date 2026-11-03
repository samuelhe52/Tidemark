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

public enum QuotaReadIssue: String, Equatable, Codable, Sendable {
    /// Passive file states.
    case missing, unreadable, unrecognized
    /// Live is on, but the agent has no usable sign-in.
    case signedOut
    /// The agent's access token expired. Tidemark never renews it; the agent does.
    case credentialExpired
    /// The Keychain read was denied or cancelled, or the service answered 401/403.
    case accessDenied
    /// The service answered 429, or Tidemark is backing off after it.
    case rateLimited
    /// Network error, server error, or an unreadable answer.
    case requestFailed
    /// A CC Switch account that Tidemark has never seen while it was the agent's account.
    case notObserved
}

/// One account's newest observation. Windows always come from a single observation.
public struct AccountUsage: Identifiable, Equatable, Sendable {
    /// `claude:<accountUuid>`, `codex:<chatgpt_account_id>`, or `<service>:local` when unknown.
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
