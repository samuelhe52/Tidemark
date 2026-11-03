//
//  CompanionPanel.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkAppearance

final class CompanionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Tidemark Companion"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the orb. A click opens or closes the dashboard; Option-click or right-click toggles the pin.
/// AppKit owns click/drag discrimination, so dragging never accidentally opens or pins.
final class OrbHandleView: NSView {
    let orb = OrbView(
        frame: NSRect(x: 0, y: 0, width: CompanionLayout.orbDiameter, height: CompanionLayout.orbDiameter))
    var clicked: (() -> Void)?
    var pinToggled: (() -> Void)?
    var dragChanged: ((CGPoint) -> Void)?
    var dragEnded: (() -> Void)?
    private var start: CGPoint?
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        orb.autoresizingMask = [.width, .height]
        addSubview(orb)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Tidemark"))
        updatePinAction()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var pinned: Bool {
        get { orb.pinned }
        set {
            orb.pinned = newValue
            updatePinAction()
        }
    }

    private func updatePinAction() {
        let name = pinned ? String(localized: "Unpin Dashboard") : String(localized: "Pin Dashboard")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.pinToggled?()
                return true
            }
        ])
    }

    override func layout() {
        super.layout()
        orb.frame = bounds
    }

    override func accessibilityPerformPress() -> Bool {
        clicked?()
        return true
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        start = Self.screenPoint(for: event)
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = Self.screenPoint(for: event)
        if hypot(point.x - start.x, point.y - start.y) >= 4 { dragging = true }
        if dragging { dragChanged?(point) }
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        if dragging {
            dragEnded?()
        } else if event.modifierFlags.contains(.option) {
            pinToggled?()
        } else {
            clicked?()
        }
        dragging = false
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {
        guard !dragging, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        pinToggled?()
    }
    private static func screenPoint(for event: NSEvent) -> CGPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}
