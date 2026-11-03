//
//  CompanionStateTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import CoreGraphics
import Foundation
import Testing
import TidemarkEngine

@MainActor
struct CompanionStateTests {
    @Test func clickOnlyRevealsOnHoverButExpandsOnlyOnClick() {
        var state = CompanionState(behavior: CompanionBehavior(hoverToExpand: false))
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        #expect(state.phase == .revealed)
        #expect(state.nextDeadline == nil)
        state.send(.timePassed, now: 10)
        #expect(state.phase == .revealed)
        state.send(.companionClicked, now: 11)
        #expect(state.phase == .expanded)
        state.send(.pointer(inside: false, onCompanion: false), now: 12)
        #expect(state.nextDeadline == 12.4)
        state.send(.timePassed, now: 12.4)
        #expect(state.phase == .hidden)
        state.send(.reset, now: 13)
        #expect(!state.behavior.hoverToExpand)
        state.send(.pointer(inside: true, onCompanion: true), now: 14)
        #expect(state.phase == .revealed)
    }

    @Test func customDelaysAndChangesReplacePendingDeadlines() {
        var state = CompanionState(behavior: CompanionBehavior(expansionDelay: 1.5, retractionDelay: 1))
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        #expect(state.nextDeadline == 1.5)
        state.send(.timePassed, now: 1)
        #expect(state.phase == .revealed)
        state.configure(CompanionBehavior(expansionDelay: 0.5, retractionDelay: 2), now: 1)
        state.send(.timePassed, now: 1.5)
        #expect(state.phase == .expanded)
        state.send(.pointer(inside: false, onCompanion: false), now: 2)
        #expect(state.nextDeadline == 4)
        state.send(.timePassed, now: 3)
        #expect(state.phase == .expanded)
        state.send(.timePassed, now: 4)
        #expect(state.phase == .hidden)
    }

    @Test func clickOnlyChangeCancelsHoverButPreservesPinnedAndMenuProtection() {
        var state = CompanionState()
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        state.send(.timePassed, now: 0.6)
        #expect(state.phase == .expanded)
        state.configure(CompanionBehavior(hoverToExpand: false), now: 0.75)
        #expect(state.phase == .revealed)
        #expect(state.nextDeadline == nil)
        state.send(.pinToggled, now: 1)
        state.configure(CompanionBehavior(hoverToExpand: false, retractionDelay: 0), now: 2)
        #expect(state.phase == .pinned)
        state.send(.menuOpened, now: 3)
        state.send(.escape, now: 3)
        state.send(.pointer(inside: false, onCompanion: false), now: 3)
        #expect(state.nextDeadline == nil)
        state.send(.menuClosed, now: 4)
        state.send(.timePassed, now: 4)
        #expect(state.phase == .hidden)
    }

    @Test func clickClosesWithoutDwellReopeningAndPinIsSeparate() {
        var state = CompanionState()
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        state.send(.companionClicked, now: 0.1)
        #expect(state.phase == .expanded)
        state.send(.companionClicked, now: 1)
        #expect(state.phase == .revealed)
        #expect(state.nextDeadline == nil)
        state.send(.pointer(inside: true, onCompanion: false), now: 2)
        state.send(.pointer(inside: true, onCompanion: true), now: 3)
        #expect(state.nextDeadline == 3.6)
        state.send(.pinToggled, now: 3.1)
        #expect(state.phase == .pinned)
        state.send(.pointer(inside: false, onCompanion: false), now: 4)
        #expect(state.nextDeadline == nil)
        state.send(.pinToggled, now: 5)
        #expect(state.phase == .expanded)
        #expect(state.nextDeadline == 5.4)
        state.send(.pointer(inside: true, onCompanion: true), now: 6)
        state.send(.pinToggled, now: 7)
        state.send(.companionClicked, now: 8)
        #expect(state.phase == .revealed)
    }

    @Test func dismissWaitsForPointerExitBeforeRevealingAgain() {
        var state = CompanionState()
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        state.send(.dismiss, now: 1)
        state.send(.pointer(inside: true, onCompanion: true), now: 2)
        #expect(state.phase == .hidden)
        state.send(.pointer(inside: false, onCompanion: false), now: 3)
        state.send(.pointer(inside: true, onCompanion: true), now: 4)
        #expect(state.phase == .revealed)
        state.send(.companionClicked, now: 5)
        state.send(.dismiss, now: 6)
        #expect(state.phase == .hidden)
    }

    @Test func timingIsBoundedAndNonfiniteValuesUseDefaults() {
        let invalid = CompanionBehavior(expansionDelay: .nan, retractionDelay: .infinity)
        #expect(invalid.expansionDelay == 0.6)
        #expect(invalid.retractionDelay == 0.4)
        let bounded = CompanionBehavior(expansionDelay: -1, retractionDelay: 100)
        #expect(bounded.expansionDelay == 0)
        #expect(bounded.retractionDelay == 3)
    }
}
