//
//  CompanionBehavior.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

/// Interaction preferences; the host owns persistence and schedules the engine's deadlines.
public struct CompanionBehavior: Equatable, Sendable {
    public var hoverToExpand: Bool
    public let expansionDelay: TimeInterval
    public let retractionDelay: TimeInterval

    public init(
        hoverToExpand: Bool = true, expansionDelay: TimeInterval = 0.6,
        retractionDelay: TimeInterval = 0.4
    ) {
        self.hoverToExpand = hoverToExpand
        self.expansionDelay = expansionDelay.isFinite ? min(3, max(0, expansionDelay)) : 0.6
        self.retractionDelay = retractionDelay.isFinite ? min(3, max(0, retractionDelay)) : 0.4
    }
}
