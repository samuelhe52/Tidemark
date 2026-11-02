//
//  CompanionState.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Foundation

public enum CompanionPhase: Equatable {
    case hidden, revealed, expanded, pinned, dragging
}

public enum CompanionEvent {
    case pointer(inside: Bool, onCompanion: Bool)
    case companionClicked, escape, timePassed
    case menuOpened, menuClosed, dragBegan, dragEnded, reset
}

/// A deterministic state machine.
///
/// The host schedules `nextDeadline` on a monotonic clock.
public struct CompanionState {
    public private(set) var phase: CompanionPhase = .hidden
    public private(set) var nextDeadline: TimeInterval?
    public private(set) var pointerInside = false
    public private(set) var pointerOnCompanion = false
    private var menuDepth = 0
    private var menuOpen: Bool { menuDepth > 0 }
    private var dragWasPinned = false
    private var deadlineKind: DeadlineKind?
    private enum DeadlineKind { case dwell, leave }

    public init() {}

    public mutating func send(_ event: CompanionEvent, now: TimeInterval) {
        switch event {
        case .pointer(let inside, let onCompanion):
            pointerInside = inside
            pointerOnCompanion = onCompanion
            if phase == .hidden, inside { phase = .revealed }
            reconcile(now: now)
        case .companionClicked:
            switch phase {
            case .hidden, .revealed, .expanded: phase = .pinned
            case .pinned: phase = .expanded
            case .dragging: return
            }
            cancelDeadline()
            reconcile(now: now)
        case .escape:
            if phase == .pinned { phase = .expanded }
            reconcile(now: now)
        case .timePassed:
            guard let deadline = nextDeadline, now >= deadline else { return }
            let kind = deadlineKind
            cancelDeadline()
            if kind == .dwell, pointerOnCompanion, !menuOpen, phase == .revealed {
                phase = .expanded
            } else if kind == .leave, !pointerInside, !menuOpen,
                phase == .revealed || phase == .expanded
            {
                phase = .hidden
            }
        case .menuOpened:
            menuDepth += 1
            cancelDeadline()
        case .menuClosed:
            menuDepth = max(0, menuDepth - 1)
            reconcile(now: now)
        case .dragBegan:
            dragWasPinned = phase == .pinned
            phase = .dragging
            cancelDeadline()
        case .dragEnded:
            guard phase == .dragging else { return }
            phase = dragWasPinned ? .pinned : .revealed
            reconcile(now: now)
        case .reset:
            self = CompanionState()
        }
    }

    private mutating func reconcile(now: TimeInterval) {
        guard !menuOpen, phase == .revealed || phase == .expanded else {
            cancelDeadline()
            return
        }
        if !pointerInside {
            schedule(.leave, after: 0.4, now: now)
        } else if phase == .revealed, pointerOnCompanion {
            schedule(.dwell, after: 0.6, now: now)
        } else {
            cancelDeadline()
        }
    }

    private mutating func schedule(_ kind: DeadlineKind, after delay: TimeInterval, now: TimeInterval) {
        guard deadlineKind != kind else { return }
        deadlineKind = kind
        nextDeadline = now + delay
    }

    private mutating func cancelDeadline() {
        nextDeadline = nil
        deadlineKind = nil
    }
}
