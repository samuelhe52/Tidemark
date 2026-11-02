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
    case claudeCache, statusline, rollout
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
        guard age >= -5, usedPercent != nil else { return .unknown }
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

public enum QuotaReadIssue: String, Equatable, Sendable {
    case missing, unreadable, unrecognized
}

public struct ServiceObservation: Identifiable, Equatable, Sendable {
    public var id: QuotaService { service }
    public let service: QuotaService
    public let windows: [QuotaWindow]
    public let issue: QuotaReadIssue?

    public init(service: QuotaService, windows: [QuotaWindow] = [], issue: QuotaReadIssue? = nil) {
        self.service = service
        self.windows = windows
        self.issue = issue
    }
}
