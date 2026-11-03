//
//  CompanionStageView.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkAppearance
import TidemarkEngine

/// The panel's content: the edge glow, the orb, the summary capsule and the dashboard.
///
/// Every transition animates only layer `transform` and `opacity`, so Core Animation composites it
/// in the render server. Window frames never change during a transition.
final class CompanionStageView: NSView {
    let glow = EdgeGlowView(frame: .zero)
    let orbHandle = OrbHandleView(frame: .zero)
    let summary = SummaryView(frame: .zero)
    let dashboard = DashboardView(frame: .zero)

    var pointerChanged: ((NSEvent) -> Void)?
    var stripClicked: ((NSEvent) -> Bool)?
    var hiddenStripActive: (() -> Bool)?
    private var trackingArea: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for view in [glow, dashboard, summary, orbHandle] as [NSView] {
            view.wantsLayer = true
            view.isHidden = view !== glow
            view.layer?.opacity = view === glow ? 1 : 0
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Places every element for `layout` inside a panel whose frame is `container`, without animation.
    func place(_ layout: CompanionLayout, in container: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = layout.local(layout.glow, in: container)
        orbHandle.frame = layout.local(layout.orb, in: container)
        summary.frame = layout.local(layout.summary, in: container)
        dashboard.frame = layout.local(layout.dashboard, in: container)
        for view in [glow, orbHandle, summary, dashboard] as [NSView] { view.layoutSubtreeIfNeeded() }
        // A hidden element keeps the resting pose that matches the current geometry.
        for element in Element.allCases where view(element).isHidden {
            view(element).layer?.move(to: restingPose(element, layout: layout, reduced: false), curve: nil)
        }
        CATransaction.commit()
    }

    /// Moves every element to its pose for `phase`. `completion` runs once all motion settles.
    func show(
        _ phase: CompanionPhase, layout: CompanionLayout, animated: Bool, completion: (() -> Void)? = nil
    ) {
        dashboard.cancelContentTransition()
        let reduced =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || ProcessInfo.processInfo.isLowPowerModeEnabled
        orbHandle.orb.idleMotion = phase != .hidden && phase != .dragging && !reduced
        let wasHidden = orbHandle.isHidden
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        for element in Element.allCases {
            let visible = element.isVisible(in: phase)
            let target = view(element)
            guard let layer = target.layer else { continue }
            let curve: MotionCurve?
            var delay: CFTimeInterval = 0
            if !animated {
                curve = nil
            } else if reduced {
                curve = MotionCurve(response: 0.3, bounce: 0)
            } else {
                switch (element, visible) {
                case (.orb, true): curve = .emerge
                case (.summary, true):
                    curve = .expand
                    if wasHidden { delay = 0.08 }
                case (.dashboard, true): curve = .expand
                case (.glow, true):
                    curve = .retract
                    delay = 0.12
                default: curve = .retract
                }
            }
            if visible {
                if target.isHidden {
                    // Start from the resting pose for the current geometry, then reveal.
                    layer.move(to: restingPose(element, layout: layout, reduced: reduced), curve: nil)
                    target.isHidden = false
                }
                layer.move(to: .identity, curve: curve, delay: delay)
            } else if !target.isHidden {
                layer.move(to: restingPose(element, layout: layout, reduced: reduced), curve: curve, delay: delay) {
                    [weak target] in
                    // A later move may have brought it back; hide only if it is still meant to be gone.
                    if let target, target.layer?.opacity == 0 { target.isHidden = true }
                }
            }
        }
        CATransaction.commit()
    }

    // MARK: - Poses

    private enum Element: CaseIterable {
        case glow, orb, summary, dashboard

        func isVisible(in phase: CompanionPhase) -> Bool {
            switch self {
            case .glow: phase == .hidden
            case .orb: phase != .hidden
            case .summary: phase == .revealed
            case .dashboard: phase == .expanded || phase == .pinned
            }
        }
    }

    private func view(_ element: Element) -> NSView {
        switch element {
        case .glow: glow
        case .orb: orbHandle
        case .summary: summary
        case .dashboard: dashboard
        }
    }

    /// Where an element waits while it is not shown.
    private func restingPose(_ element: Element, layout: CompanionLayout, reduced: Bool) -> LayerPose {
        guard !reduced, let layer = view(element).layer else {
            return LayerPose(opacity: 0, transform: CATransform3DIdentity)
        }
        switch element {
        case .glow:
            return LayerPose(opacity: 0, transform: CATransform3DIdentity)
        case .orb:
            // Tucked into the edge it came from, half size.
            let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            return .scaled(0.5, about: center, offset: layout.tuckOffset, opacity: 0, in: layer)
        case .summary:
            return .scaled(0.9, about: pivot(toward: layout.orb, in: layout.summary), opacity: 0, in: layer)
        case .dashboard:
            return .scaled(0.88, about: pivot(toward: layout.orb, in: layout.dashboard), opacity: 0, in: layer)
        }
    }

    /// Finds the point nearest the orb in the rectangle's local coordinates.
    private func pivot(toward orb: CGRect, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(orb.midX, rect.minX), rect.maxX) - rect.minX,
            y: min(max(orb.midY, rect.minY), rect.maxY) - rect.minY)
    }

    // MARK: - Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if hiddenStripActive?() == true { return frame.contains(point) ? self : nil }
        return super.hitTest(point)
    }
    override func mouseEntered(with event: NSEvent) { pointerChanged?(event) }
    override func mouseExited(with event: NSEvent) { pointerChanged?(event) }
    override func mouseMoved(with event: NSEvent) { pointerChanged?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if stripClicked?(event) != true { super.mouseDown(with: event) }
    }
}

/// The one-line summary shown beside the revealed orb.
final class SummaryView: NSView {
    private let surface = GlassSurfaceView(cornerRadius: 14, kind: .content)
    private let text = CompanionLabel(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .center
        surface.contentView.addSubview(text)
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var preferredSize: CGSize {
        let size = text.intrinsicContentSize
        return CGSize(width: ceil(size.width) + 28, height: 28)
    }

    func update(text value: String) {
        text.stringValue = value
        setAccessibilityLabel(value)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.cornerRadius = bounds.height / 2
        let height = text.intrinsicContentSize.height
        text.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}
