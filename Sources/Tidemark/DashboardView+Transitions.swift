//
//  DashboardView+Transitions.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// Content transitions: rows move and crossfade when the dashboard's content changes.
extension DashboardView {
    struct ContentTransition {
        fileprivate let rows: [RowID: ContentRow]
        fileprivate let frames: [RowID: CGRect]
        fileprivate let surface: CGRect
        fileprivate let viewport: CGRect
        fileprivate let chrome: [(NSView, CGRect)]
    }

    func prepareContentTransition() -> ContentTransition? {
        guard window != nil, !isHidden else { return nil }
        let viewport = scrollView.contentView.screenFrame()
        let frames = rows.mapValues { $0.view.screenFrame() }
        return ContentTransition(
            rows: rows, frames: frames, surface: surface.screenFrame(), viewport: viewport,
            chrome: root.arrangedSubviews.filter { $0 !== scrollView }.map { ($0, $0.screenFrame()) })
    }

    func cancelContentTransition() {
        contentGeneration += 1
        contentTransitionIsActive = false
        for view in outgoingViews { view.removeFromSuperview() }
        outgoingViews = []
        let views: [NSView] = [surface] + rows.values.map(\.view) + root.arrangedSubviews
        for view in views {
            view.layer?.removeAnimation(forKey: ContentMotion.transformKey)
            view.layer?.removeAnimation(forKey: ContentMotion.opacityKey)
        }
    }

    func animateContent(from previous: ContentTransition, completion: @escaping () -> Void) {
        guard let window else {
            completion()
            return
        }
        contentGeneration += 1
        let generation = contentGeneration
        contentTransitionIsActive = true
        let reduced = ContentMotion.reducesMotion
        let duration = ContentMotion.duration(reduced: reduced)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.contentGeneration == generation else { return }
            self.contentTransitionIsActive = false
            for view in self.outgoingViews { view.removeFromSuperview() }
            self.outgoingViews = []
            completion()
        }
        if !reduced { surface.animateMove(from: previous.surface, duration: duration, scales: true) }
        for (view, frame) in previous.chrome where !reduced { view.animateMove(from: frame, duration: duration) }
        // The viewport travels top edge to top edge with the chrome, so rows start inside its clip
        // instead of above it when the panel shrinks; rows only make up the remaining distance.
        let viewport = scrollView.contentView.screenFrame(model: true)
        let shift = CGPoint(x: viewport.minX - previous.viewport.minX, y: viewport.maxY - previous.viewport.maxY)
        if !reduced {
            scrollView.animateMove(
                from: scrollView.screenFrame(model: true).offsetBy(dx: -shift.x, dy: -shift.y),
                duration: duration)
        }
        for (id, row) in rows {
            if let frame = previous.frames[id], !reduced {
                row.view.animateMove(from: frame.offsetBy(dx: shift.x, dy: shift.y), duration: duration)
            }
            let changed = previous.rows[id].map { $0.motionState != row.motionState } ?? true
            if changed, let rowLayer = row.view.layer {
                rowLayer.addContentFade(appearing: true, duration: duration)
                if !reduced, previous.frames[id] == nil {
                    let dy: CGFloat = row.view.superview?.isFlipped == true ? 6 : -6
                    rowLayer.addContentSlide(from: CGPoint(x: 0, y: dy), to: .zero, duration: duration)
                }
            }
        }
        for (id, row) in previous.rows {
            let changed = rows[id].map { $0.motionState != row.motionState } ?? true
            guard changed, let frame = previous.frames[id], rows[id]?.view !== row.view else { continue }
            let visible = frame.intersection(previous.viewport)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            // A replaced row travels with its successor so the two never separate into a ghost; a
            // removed row lifts away.
            let offset =
                rows[id].map { offset(from: frame, to: $0.view.screenFrame(model: true)) }
                ?? CGPoint(x: 0, y: isFlipped ? -6 : 6)
            // Retain the actual outgoing row. Native controls can overhang their alignment
            // rect, so clip the visible intersection instead of skipping the exit entirely.
            let overlay = OutgoingContentView(frame: convert(window.convertFromScreen(visible), from: nil))
            overlay.wantsLayer = true
            overlay.layer?.masksToBounds = true
            overlay.setAccessibilityElement(false)
            overlay.setAccessibilityChildren([])
            row.view.translatesAutoresizingMaskIntoConstraints = true
            row.view.frame = frame.offsetBy(dx: -visible.minX, dy: -visible.minY)
            overlay.addSubview(row.view)
            addSubview(overlay)
            overlay.layoutSubtreeIfNeeded()
            overlay.displayIfNeeded()
            outgoingViews.append(overlay)
            guard let outgoing = overlay.layer else { continue }
            outgoing.opacity = 0
            outgoing.addContentFade(appearing: false, duration: duration)
            if !reduced {
                outgoing.transform = CATransform3DMakeTranslation(offset.x, offset.y, 0)
                outgoing.addContentSlide(from: .zero, to: offset, duration: duration)
            }
        }
        CATransaction.commit()
    }

    /// How far this view's coordinates carry content from one screen rect's top-leading corner to another's.
    func offset(from old: CGRect, to new: CGRect) -> CGPoint {
        // Screen coordinates rise upward; flipped views measure downward.
        CGPoint(x: new.minX - old.minX, y: isFlipped ? old.maxY - new.maxY : new.maxY - old.maxY)
    }
}

/// Exiting content remains drawable until its fade completes, without intercepting input.
fileprivate final class OutgoingContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
