//
//  CompanionPanel.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import SwiftUI

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

/// AppKit owns click/drag discrimination, so dragging never accidentally pins the companion.
struct CompanionInteraction: NSViewRepresentable {
    let clicked: () -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: () -> Void

    func makeNSView(context: Context) -> InteractionView { InteractionView() }
    func updateNSView(_ view: InteractionView, context: Context) {
        view.clicked = clicked
        view.dragChanged = dragChanged
        view.dragEnded = dragEnded
    }

    final class InteractionView: NSView {
        var clicked: (() -> Void)?
        var dragChanged: ((CGPoint) -> Void)?
        var dragEnded: (() -> Void)?
        private var start: CGPoint?
        private var dragging = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        private static func screenPoint(for event: NSEvent) -> CGPoint {
            event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            if dragging { dragEnded?() } else { clicked?() }
            dragging = false
        }
    }
}

/// A native tracking area makes entering the hidden strip independent of global monitor latency.
final class CompanionHostingView<Content: View>: NSHostingView<Content> {
    var pointerChanged: ((NSEvent) -> Void)?
    var stripClicked: ((NSEvent) -> Bool)?
    var hiddenStripActive: (() -> Bool)?
    private var companionTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let companionTrackingArea { removeTrackingArea(companionTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        companionTrackingArea = area
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if hiddenStripActive?() == true { return self }
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
