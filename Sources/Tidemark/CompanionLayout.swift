//
//  CompanionLayout.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkEngine

/// All rectangles are in global Cocoa coordinates until converted for SwiftUI.
struct CompanionLayout {
    let frame: CGRect
    let orb: CGRect
    let dashboard: CGRect
    let summary: CGRect
    let strip: CGRect
    let glow: CGRect
    let corridor: CGRect

    init(anchor: DockAnchor, dragPoint: CGPoint? = nil) {
        let screen = anchor.visibleFrame
        var center = anchor.point
        switch anchor.placement.edge {
        case .left: center.x += 38
        case .right: center.x -= 38
        case .top: center.y -= 38
        case .bottom: center.y += 38
        }
        if let dragPoint { center = dragPoint }
        orb = CGRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64)
        var card = CGRect(
            x: center.x - 172, y: center.y - 180, width: min(344, screen.width - 16),
            height: min(440, screen.height - 16))
        switch anchor.placement.edge {
        case .left: card.origin.x = orb.maxX + 18
        case .right: card.origin.x = orb.minX - 18 - card.width
        case .top: card.origin.y = orb.minY - 18 - card.height
        case .bottom: card.origin.y = orb.maxY + 18
        }
        card.origin.x = min(max(screen.minX + 8, card.minX), screen.maxX - card.width - 8)
        card.origin.y = min(max(screen.minY + 8, card.minY), screen.maxY - card.height - 8)
        dashboard = card
        var line = card
        line.size.height = 40
        line.origin.y = center.y - 20
        if anchor.placement.edge == .top { line.origin.y = orb.minY - 54 }
        if anchor.placement.edge == .bottom { line.origin.y = orb.maxY + 14 }
        summary = line
        let pill: CGRect
        let hover: CGRect
        switch anchor.placement.edge {
        case .left, .right:
            let x = anchor.placement.edge == .left ? screen.minX : screen.maxX - 4
            pill = CGRect(x: x, y: anchor.point.y - 22, width: 4, height: 44)
            hover = CGRect(
                x: anchor.placement.edge == .left ? x : x - 4,
                y: anchor.point.y - 32, width: 8, height: 64)
        case .top, .bottom:
            let y = anchor.placement.edge == .bottom ? screen.minY : screen.maxY - 4
            pill = CGRect(x: anchor.point.x - 22, y: y, width: 44, height: 4)
            hover = CGRect(
                x: anchor.point.x - 32,
                y: anchor.placement.edge == .bottom ? y : y - 4, width: 64, height: 8)
        }
        glow = pill
        strip = hover
        let bridge: CGRect
        switch anchor.placement.edge {
        case .left, .right:
            bridge = CGRect(
                x: min(orb.midX, card.midX), y: center.y - 22,
                width: abs(orb.midX - card.midX), height: 44)
        case .top, .bottom:
            bridge = CGRect(
                x: center.x - 22, y: min(orb.midY, card.midY),
                width: 44, height: abs(orb.midY - card.midY))
        }
        corridor = bridge
        frame = orb.union(card).union(line).union(hover).insetBy(dx: -10, dy: -10).intersection(screen)
    }

    func localCenter(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX - frame.minX, y: frame.maxY - rect.midY)
    }

    func onOrb(_ point: CGPoint) -> Bool {
        let dx = (point.x - orb.midX) / 32
        let dy = (point.y - orb.midY) / 32
        return dx * dx + dy * dy <= 1
    }

    func contains(_ point: CGPoint, phase: CompanionPhase) -> Bool {
        if strip.contains(point) { return true }
        guard phase != .hidden else { return false }
        if onOrb(point) { return true }
        if phase == .expanded || phase == .pinned {
            return CGPath(roundedRect: dashboard, cornerWidth: 22, cornerHeight: 22, transform: nil).contains(point)
                || corridor.contains(point)
        }
        return false
    }
}
