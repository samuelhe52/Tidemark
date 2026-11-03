//
//  RowScrollPreservation.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

/// Computes the origin adjustment for a fixed-height row list inside an outer scroller.
public enum RowScrollPreservation {
    /// viewportTop is relative to the first row, not the section heading. Content above
    /// the rows must stay still. Prefer the top row, then the next surviving row; if
    /// the entire suffix vanished, use the nearest surviving preceding row.
    /// O(oldIDs.count + newIDs.count) time and O(newIDs.count) temporary storage.
    public static func adjustment(
        oldIDs: [String], newIDs: [String], viewportTop: Double, rowHeight: Double
    ) -> Double {
        guard rowHeight > 0, viewportTop.isFinite, viewportTop >= 0,
            viewportTop < Double(oldIDs.count) * rowHeight
        else { return 0 }
        let top = Int(viewportTop / rowHeight)
        let positions = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
        for index in top..<oldIDs.count {
            if let updated = positions[oldIDs[index]] {
                return Double(updated - index) * rowHeight
            }
        }
        for index in (0..<top).reversed() {
            if let updated = positions[oldIDs[index]] {
                return Double(updated - index) * rowHeight
            }
        }
        // No surviving row can be anchored; let the clip view constrain the old origin.
        return 0
    }
}
