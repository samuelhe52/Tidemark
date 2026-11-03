//
//  CompanionStageView.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkAppearance
import TidemarkEngine

/// The panel's content: the orb, the summary capsule and the dashboard.
///
/// The summary and dashboard animate only layer `transform` and `opacity`, so Core Animation composites
/// them in the render server. The orb never hides: while hidden its glass docks as a tab on the screen
/// edge and morphs back into the sphere. Window frames never change during a transition.
final class CompanionStageView: NSView {
    let orbHandle = OrbHandleView(frame: .zero)
    let summary = SummaryView(frame: .zero)
    let dashboard: DashboardView

    var pointerChanged: ((NSEvent) -> Void)?
    var stripClicked: ((NSEvent) -> Bool)?
    var hiddenStripActive: (() -> Bool)?
    private var trackingArea: NSTrackingArea?
    init(settings: SettingsStore) {
        dashboard = DashboardView(settings: settings)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [dashboard, summary, orbHandle] as [NSView] {
            view.wantsLayer = true
            addSubview(view)
        }
        for element in Element.allCases {
            view(element).isHidden = true
            view(element).layer?.opacity = 0
        }
        orbHandle.orb.setDocked(true, curve: nil) {}
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Places every element for `layout` inside a panel whose frame is `container`, without animation.
    func place(_ layout: CompanionLayout, in container: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbHandle.frame = layout.local(layout.orb, in: container)
        // Relative to the orb, so an in-flight morph survives the panel changing size.
        orbHandle.orb.dockedFrame = layout.dock.offsetBy(dx: -layout.orb.minX, dy: -layout.orb.minY)
        summary.frame = layout.local(layout.summary, in: container)
        dashboard.frame = layout.local(layout.dashboard, in: container)
        for view in [orbHandle, summary, dashboard] as [NSView] { view.layoutSubtreeIfNeeded() }
        // A hidden element keeps the resting pose that matches the current geometry.
        for element in Element.allCases where view(element).isHidden {
            view(element).layer?.move(to: restingPose(element, layout: layout, reduced: false), curve: nil)
        }
        CATransaction.commit()
    }

    // MARK: - Content transitions

    /// What the summary or dashboard showed before new content, so it can animate to the new layout.
    struct ContentTransition {
        fileprivate var dashboard: DashboardView.ContentTransition?
        fileprivate var summary: SummaryView.ContentTransition?
    }

    var contentTransitionIsActive: Bool { dashboard.contentTransitionIsActive || summary.contentTransitionIsActive }

    /// Captures whichever element `phase` shows; nil when nothing visible would change.
    func prepareContentTransition(for phase: CompanionPhase, summaryText: String) -> ContentTransition? {
        let transition = ContentTransition(
            dashboard: phase == .expanded || phase == .pinned ? dashboard.prepareContentTransition() : nil,
            summary: phase == .revealed ? summary.prepareContentTransition(to: summaryText) : nil)
        return transition.dashboard == nil && transition.summary == nil ? nil : transition
    }

    func cancelContentTransition() {
        dashboard.cancelContentTransition()
        summary.cancelContentTransition()
    }

    /// Runs after `place`. `completion` runs only if the transition finishes uncancelled.
    func animateContent(from previous: ContentTransition, completion: @escaping () -> Void) {
        if let previous = previous.dashboard { dashboard.animateContent(from: previous, completion: completion) }
        if let previous = previous.summary { summary.animateContent(from: previous, completion: completion) }
    }

    /// Moves every element to its pose for `phase`. `completion` runs once all motion settles.
    func show(
        _ phase: CompanionPhase, layout: CompanionLayout, animated: Bool, completion: (() -> Void)? = nil
    ) {
        cancelContentTransition()
        let reduced = ContentMotion.reducesMotion
        let orb = orbHandle.orb
        let wasDocked = orb.docked
        let docked = phase == .hidden
        // Both the morph and the other elements' motion must settle before `completion`.
        var pending = 2
        let settle = {
            pending -= 1
            if pending == 0 { completion?() }
        }
        if docked == wasDocked {
            settle()
        } else {
            // Content collapses into the orb before the orb melts into the edge.
            let curve: MotionCurve? = !animated || reduced ? nil : docked ? .retract : .emerge
            orb.setDocked(docked, curve: curve, delay: docked ? 0.1 : 0, completion: settle)
        }
        orb.idleMotion = !docked && phase != .dragging && !reduced
        CATransaction.begin()
        CATransaction.setCompletionBlock(settle)
        for element in Element.allCases {
            let visible = element.isVisible(in: phase)
            let target = view(element)
            guard let layer = target.layer else { continue }
            let curve: MotionCurve?
            var delay: CFTimeInterval = 0
            if !animated {
                curve = nil
            } else if reduced {
                curve = .reduced
            } else if visible {
                curve = .expand
                if element == .summary, wasDocked { delay = 0.08 }
            } else {
                curve = .retract
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

    /// True while a released orb is still springing toward its resting frame.
    var orbSettling: Bool { orbHandle.layer?.animation(forKey: Self.settleKey) != nil }

    /// Springs the orb from `origin` to `target`, both global, after `place` has put it at `target`.
    ///
    /// The motion is an additive translation, so the orb's frame and pose stay where `place` left them.
    /// `completion` also runs when the settle is cancelled; read `orbSettling` to tell them apart.
    func settleOrb(from origin: CGRect, to target: CGRect, completion: @escaping () -> Void) {
        let offset = CGSize(width: origin.minX - target.minX, height: origin.minY - target.minY)
        guard let layer = orbHandle.layer, offset != .zero, !ContentMotion.reducesMotion else { return completion() }
        let curve = MotionCurve.settle
        let spring = CASpringAnimation(perceptualDuration: curve.response, bounce: curve.bounce)
        spring.keyPath = "transform.translation"
        spring.isAdditive = true
        spring.fromValue = NSValue(size: offset)
        spring.toValue = NSValue(size: .zero)
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(spring, forKey: Self.settleKey)
        CATransaction.commit()
    }

    func cancelOrbSettle() { orbHandle.layer?.removeAnimation(forKey: Self.settleKey) }

    private static let settleKey = "orb.settle"

    // MARK: - Poses

    private enum Element: CaseIterable {
        case summary, dashboard

        func isVisible(in phase: CompanionPhase) -> Bool {
            switch self {
            case .summary: phase == .revealed
            case .dashboard: phase == .expanded || phase == .pinned
            }
        }
    }

    private func view(_ element: Element) -> NSView {
        switch element {
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
    private let text = SummaryView.label("")
    private var outgoingText: CompanionLabel?
    private var contentGeneration = 0
    private(set) var contentTransitionIsActive = false

    struct ContentTransition {
        fileprivate let frame: CGRect
        fileprivate let text: String
    }

    private static func label(_ value: String) -> CompanionLabel {
        let label = CompanionLabel(value, size: 12, weight: .medium)
        label.alignment = .center
        label.wantsLayer = true
        return label
    }

    func prepareContentTransition(to value: String) -> ContentTransition? {
        guard window != nil, !isHidden, value != text.stringValue || contentTransitionIsActive else { return nil }
        return ContentTransition(frame: surface.screenFrame(), text: text.stringValue)
    }

    func cancelContentTransition() {
        contentGeneration += 1
        contentTransitionIsActive = false
        outgoingText?.removeFromSuperview()
        outgoingText = nil
        surface.layer?.removeAnimation(forKey: ContentMotion.transformKey)
        text.layer?.removeAnimation(forKey: ContentMotion.opacityKey)
    }

    /// Resizes the glass while crossfading labels at their natural size, so neither text stretches.
    func animateContent(from previous: ContentTransition, completion: @escaping () -> Void) {
        guard let window else { return completion() }
        contentGeneration += 1
        let generation = contentGeneration
        contentTransitionIsActive = true
        let reduced = ContentMotion.reducesMotion
        let duration = ContentMotion.duration(reduced: reduced)
        let old = convert(window.convertFromScreen(previous.frame), from: nil)
        let outgoing = Self.label(previous.text)
        outgoing.setAccessibilityElement(false)
        let height = outgoing.intrinsicContentSize.height
        outgoing.frame = CGRect(x: old.minX, y: old.midY - height / 2, width: old.width, height: height)
        addSubview(outgoing)
        outgoingText = outgoing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.contentGeneration == generation else { return }
            self.cancelContentTransition()
            completion()
        }
        if !reduced { surface.animateMove(from: previous.frame, duration: duration, scales: true) }
        text.layer?.addContentFade(appearing: true, duration: duration)
        outgoing.layer?.opacity = 0
        outgoing.layer?.addContentFade(appearing: false, duration: duration)
        CATransaction.commit()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        surface.wantsLayer = true
        // A sibling of the glass, not its child, so the resize never scales the text.
        addSubview(surface)
        addSubview(text)
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
