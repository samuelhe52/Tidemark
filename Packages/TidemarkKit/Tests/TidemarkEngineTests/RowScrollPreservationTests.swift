//
//  RowScrollPreservationTests.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import Testing
import TidemarkEngine

@MainActor
struct RowScrollPreservationTests {
    @Test func refreshKeepsContentAboveRowsStill() {
        for top in [-300.0, -24, -0.5] {
            #expect(
                RowScrollPreservation.adjustment(
                    oldIDs: ["a", "b"], newIDs: ["new", "a", "b"], viewportTop: top, rowHeight: 24) == 0)
        }
        #expect(
            RowScrollPreservation.adjustment(
                oldIDs: ["a", "b"], newIDs: ["new", "a", "b"], viewportTop: 0, rowHeight: 24) == 24)
    }

    @Test func anchorsByIdentityAcrossInsertionsRemovalsAndReplacement() {
        let old = ["a", "b", "c", "d"]
        // Top is 7 points into c; only changes above c affect its position.
        #expect(
            RowScrollPreservation.adjustment(
                oldIDs: old, newIDs: ["new", "a", "inside", "b", "c", "d", "tail"],
                viewportTop: 55, rowHeight: 24) == 48)
        #expect(
            RowScrollPreservation.adjustment(
                oldIDs: old, newIDs: ["c", "d"], viewportTop: 55, rowHeight: 24) == -48)
        // When c disappears, keep the next surviving row d at its previous screen position.
        #expect(
            RowScrollPreservation.adjustment(
                oldIDs: old, newIDs: ["a", "b", "d"], viewportTop: 55, rowHeight: 24) == -24)
        #expect(
            RowScrollPreservation.adjustment(
                oldIDs: old, newIDs: old, viewportTop: 55, rowHeight: 24) == 0)
        #expect(
            RowScrollPreservation.adjustment(
                oldIDs: old, newIDs: [], viewportTop: 55, rowHeight: 24) == 0)
    }
}
