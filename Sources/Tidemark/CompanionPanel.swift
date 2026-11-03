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

/// Holds the orb. AppKit owns click/drag discrimination, so dragging never accidentally pins.
final class OrbHandleView: NSView {
    let orb = OrbView(
        frame: NSRect(x: 0, y: 0, width: CompanionLayout.orbDiameter, height: CompanionLayout.orbDiameter))
    var clicked: (() -> Void)?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var pinned: Bool {
        get { orb.pinned }
        set {
            orb.pinned = newValue
            setAccessibilityLabel(newValue ? String(localized: "Unpin Tidemark") : String(localized: "Pin Tidemark"))
        }
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
        if dragging { dragEnded?() } else { clicked?() }
        dragging = false
    }
    private static func screenPoint(for event: NSEvent) -> CGPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}
