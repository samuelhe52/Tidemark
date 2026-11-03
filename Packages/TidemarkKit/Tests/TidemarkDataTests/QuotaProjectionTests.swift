//
//  QuotaProjectionTests.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/4.
//

import Foundation
import Testing

@testable import TidemarkData

struct QuotaProjectionTests {
    private let day: TimeInterval = 86400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A weekly window that opened at `start`, observed `elapsed` seconds later.
    private func weekly(used: Double?, elapsed: TimeInterval, observedAge: TimeInterval = 0) -> (QuotaWindow, Date) {
        let observedAt = start.addingTimeInterval(elapsed)
        let window = QuotaWindow(
            id: QuotaWindow.sevenDayID, usedPercent: used, resetsAt: start.addingTimeInterval(7 * day),
            duration: 7 * day, observedAt: observedAt, source: .live)
        return (window, observedAt.addingTimeInterval(observedAge))
    }

    @Test func projectsFromAveragePaceSinceTheWindowOpened() throws {
        let (window, now) = weekly(used: 50, elapsed: 2 * day)
        #expect(try #require(window.projectedExhaustion(at: now)) == start.addingTimeInterval(4 * day))
    }

    @Test func paceIsMeasuredAtTheObservationNotAtNow() throws {
        let (window, now) = weekly(used: 50, elapsed: 2 * day, observedAge: 600)
        #expect(try #require(window.projectedExhaustion(at: now)) == start.addingTimeInterval(4 * day))
    }

    @Test func staysQuietWhenTheQuotaLastsUntilTheReset() {
        #expect(weekly(used: 20, elapsed: 3 * day).0.projectedExhaustion(at: start.addingTimeInterval(3 * day)) == nil)
    }

    @Test func staysQuietWithoutEnoughHistoryOrUsage() {
        for (used, elapsed) in [(90.0, 600.0), (0.0, 3 * day), (100.0, 3 * day)] {
            let (window, now) = weekly(used: used, elapsed: elapsed)
            #expect(window.projectedExhaustion(at: now) == nil)
        }
        let (unreported, now) = weekly(used: nil, elapsed: day)
        #expect(unreported.projectedExhaustion(at: now) == nil)
    }

    @Test func staysQuietForUntrustworthyReadings() {
        let (window, observed) = weekly(used: 80, elapsed: day)
        #expect(window.projectedExhaustion(at: observed.addingTimeInterval(3600)) == nil)
        #expect(window.projectedExhaustion(at: start.addingTimeInterval(8 * day)) == nil)
    }

    @Test func onlyWeeklyWindowsAreWeekly() {
        let five = QuotaWindow(
            id: QuotaWindow.fiveHourID, usedPercent: 1, resetsAt: nil, duration: nil, observedAt: start, source: .live)
        let opus = QuotaWindow(
            id: "seven_day_opus", usedPercent: 1, resetsAt: nil, duration: nil, observedAt: start, source: .live)
        #expect(!five.isWeekly)
        #expect(opus.isWeekly)
        #expect(weekly(used: 1, elapsed: day).0.isWeekly)
    }
}
