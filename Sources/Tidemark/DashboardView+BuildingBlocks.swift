//
//  DashboardView+BuildingBlocks.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// Labels, rows and stacks shared by every dashboard section.
extension DashboardView {
    static func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
        monospacedDigits: Bool = false
    ) -> NSTextField {
        let field = CompanionLabel(text, size: size, weight: weight, color: color, monospacedDigits: monospacedDigits)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Gives a composite row one tooltip and one accessibility label.
    static func describe(_ view: NSView, _ description: String) {
        view.toolTip = description
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(description)
    }

    static func caption(_ text: String) -> NSTextField {
        let field = label(text, size: 11, color: .secondaryLabelColor)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func row(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [leading, spacer, trailing])
        row.alignment = .firstBaseline
        row.spacing = 6
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    static func column(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// Stretches every arranged subview to the stack's width.
    static func fill(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// A sideways-scrolling container inside the vertical dashboard scroll view.
///
/// Decides the scroll axis once per trackpad gesture so vertical gestures (including their
/// zero-delta start and momentum events) go straight to `verticalParent`.
class HorizontalScrollView: NSScrollView {
    weak var verticalParent: NSScrollView?
    private var gestureIsVertical: Bool?
    private var pendingScrollStart: NSEvent?

    override func scrollWheel(with event: NSEvent) {
        let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            routeScrollWheel(event, vertically: vertical)
            return
        }

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            gestureIsVertical = nil
            pendingScrollStart = nil
        }
        if gestureIsVertical == nil {
            // A trackpad can begin with no movement. Wait for an axis, then deliver that
            // start to the same scroll view as the movement and eventual momentum events.
            if event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0 {
                if event.phase.contains(.began) { pendingScrollStart = event }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled)
                    || event.momentumPhase.contains(.ended)
                {
                    pendingScrollStart = nil
                }
                return
            }
            gestureIsVertical = vertical
            if let start = pendingScrollStart {
                pendingScrollStart = nil
                routeScrollWheel(start, vertically: vertical)
            }
        }
        routeScrollWheel(event, vertically: gestureIsVertical == true)
        // Keep the recipient after finger lift: momentum begins in a separate event.
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            gestureIsVertical = nil
            pendingScrollStart = nil
        }
    }

    private func routeScrollWheel(_ event: NSEvent, vertically: Bool) {
        if vertically {
            verticalParent?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
