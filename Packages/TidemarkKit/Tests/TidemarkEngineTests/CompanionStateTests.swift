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
    @Test func dwellRequiresContinuousCompanionHover() {
        var state = CompanionState()
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        #expect(state.phase == .revealed)
        state.send(.pointer(inside: true, onCompanion: false), now: 0.4)
        state.send(.timePassed, now: 0.6)
        #expect(state.phase == .revealed)
        state.send(.pointer(inside: true, onCompanion: true), now: 1)
        state.send(.pointer(inside: true, onCompanion: true), now: 1.2)
        #expect(state.nextDeadline == 1.6)
        state.send(.timePassed, now: 1.59)
        #expect(state.phase == .revealed)
        state.send(.timePassed, now: 1.6)
        #expect(state.phase == .expanded)
    }

    @Test func leaveGraceCancelsOnReentryAndPinnedEscapeResumesIt() {
        var state = CompanionState()
        state.send(.companionClicked, now: 0)
        state.send(.pointer(inside: false, onCompanion: false), now: 1)
        #expect(state.nextDeadline == nil)
        state.send(.escape, now: 2)
        #expect(state.phase == .expanded)
        state.send(.pointer(inside: true, onCompanion: false), now: 2.2)
        state.send(.timePassed, now: 2.5)
        #expect(state.phase == .expanded)
        state.send(.pointer(inside: false, onCompanion: false), now: 3)
        state.send(.timePassed, now: 3.4)
        #expect(state.phase == .hidden)
    }

    @Test func menuAndDragSuppressTimersAndRestorePin() {
        var state = CompanionState()
        state.send(.pointer(inside: true, onCompanion: true), now: 0)
        state.send(.menuOpened, now: 0.1)
        state.send(.pointer(inside: false, onCompanion: false), now: 0.2)
        state.send(.timePassed, now: 2)
        #expect(state.phase == .revealed)
        state.send(.menuOpened, now: 2)
        state.send(.menuClosed, now: 2)
        #expect(state.nextDeadline == nil)
        state.send(.menuClosed, now: 2)
        #expect(state.nextDeadline == 2.4)
        state.send(.companionClicked, now: 2.1)
        state.send(.dragBegan, now: 2.2)
        state.send(.timePassed, now: 10)
        #expect(state.phase == .dragging)
        state.send(.dragEnded, now: 10)
        #expect(state.phase == .pinned)
        state.send(.companionClicked, now: 11)
        #expect(state.phase == .expanded)
        #expect(state.nextDeadline == 11.4)
    }

    @Test func placementRejectsSeamAndFallsBackToMainDisplay() throws {
        let left = DockDisplay(
            id: "main", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 30, width: 1000, height: 746))
        let right = DockDisplay(
            id: "other", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1000, y: 30, width: 1000, height: 746))
        let seam = try #require(DockGeometry.nearest(to: CGPoint(x: 1000, y: 400), displays: [left, right]))
        #expect(seam.placement.edge != .left && seam.placement.edge != .right)
        let fallback = try #require(
            DockGeometry.resolve(
                DockPlacement(displayID: "unplugged", edge: .left, along: 0.25), displays: [left]))
        #expect(fallback.placement.displayID == "main")
        #expect(fallback.point == CGPoint(x: 0, y: 216.5))
        let clamped = try #require(
            DockGeometry.resolve(
                DockPlacement(displayID: "main", edge: .top, along: 1), displays: [left]))
        #expect(clamped.point.x == 952)
    }
}
