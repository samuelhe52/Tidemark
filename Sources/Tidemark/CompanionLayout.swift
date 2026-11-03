//
//  CompanionLayout.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkEngine

/// All rectangles are in global Cocoa coordinates.
struct CompanionLayout {
    static let orbDiameter: CGFloat = 44
    static let dashboardCornerRadius: CGFloat = 18

    let edge: DockEdge
    let screen: CGRect
    let frame: CGRect
    let orb: CGRect
    let dashboard: CGRect
    let summary: CGRect
    let strip: CGRect
    let glow: CGRect
    let corridor: CGRect

    /// The tallest dashboard that fits beside the orb. On the top and bottom edges the orb takes
    /// `orbDiameter + 12` from the edge and the gap another 12; taller would be clamped onto the orb.
    static func dashboardMaxHeight(for anchor: DockAnchor) -> CGFloat {
        let height = anchor.visibleFrame.height - 16
        switch anchor.placement.edge {
        case .left, .right: return height
        case .top, .bottom: return height - (orbDiameter + 12 + 12)
        }
    }

    init(anchor: DockAnchor, dragPoint: CGPoint? = nil, summarySize: CGSize, dashboardSize: CGSize) {
        let screen = anchor.visibleFrame
        let edge = anchor.placement.edge
        self.edge = edge
        self.screen = screen
        let radius = Self.orbDiameter / 2
        var center = anchor.point
        let inset = radius + 12
        switch edge {
        case .left: center.x += inset
        case .right: center.x -= inset
        case .top: center.y -= inset
        case .bottom: center.y += inset
        }
        if let dragPoint { center = dragPoint }
        let orb = CGRect(
            x: center.x - radius, y: center.y - radius, width: Self.orbDiameter, height: Self.orbDiameter)
        self.orb = orb

        let gap: CGFloat = 12
        func clamped(_ rect: CGRect) -> CGRect {
            var rect = rect
            rect.size.width = min(rect.width, screen.width - 16)
            rect.size.height = min(rect.height, screen.height - 16)
            rect.origin.x = min(max(screen.minX + 8, rect.minX), screen.maxX - rect.width - 8)
            rect.origin.y = min(max(screen.minY + 8, rect.minY), screen.maxY - rect.height - 8)
            return rect
        }
        func beside(_ size: CGSize, centeredOn alongCenter: CGPoint) -> CGRect {
            var rect = CGRect(
                x: alongCenter.x - size.width / 2, y: alongCenter.y - size.height / 2,
                width: size.width, height: size.height)
            switch edge {
            case .left: rect.origin.x = orb.maxX + gap
            case .right: rect.origin.x = orb.minX - gap - size.width
            case .top: rect.origin.y = orb.minY - gap - size.height
            case .bottom: rect.origin.y = orb.maxY + gap
            }
            return clamped(rect)
        }
        let dashboard = beside(dashboardSize, centeredOn: center)
        self.dashboard = dashboard
        let summary = beside(summarySize, centeredOn: center)
        self.summary = summary

        let pill: CGRect
        let hover: CGRect
        switch edge {
        case .left, .right:
            let x = edge == .left ? screen.minX : screen.maxX - 4
            pill = CGRect(x: x, y: anchor.point.y - 22, width: 4, height: 44)
            hover = CGRect(x: edge == .left ? x : x - 4, y: anchor.point.y - 32, width: 8, height: 64)
        case .top, .bottom:
            let y = edge == .bottom ? screen.minY : screen.maxY - 4
            pill = CGRect(x: anchor.point.x - 22, y: y, width: 44, height: 4)
            hover = CGRect(x: anchor.point.x - 32, y: edge == .bottom ? y : y - 4, width: 64, height: 8)
        }
        glow = pill
        strip = hover
        switch edge {
        case .left, .right:
            corridor = CGRect(
                x: min(orb.midX, dashboard.midX), y: center.y - 22,
                width: abs(orb.midX - dashboard.midX), height: 44)
        case .top, .bottom:
            corridor = CGRect(
                x: center.x - 22, y: min(orb.midY, dashboard.midY),
                width: 44, height: abs(orb.midY - dashboard.midY))
        }
        // The orb's tucked pose sits on the edge, so the frame must reach it.
        frame = orb.union(dashboard).union(summary).union(hover).union(pill)
            .insetBy(dx: -10, dy: -10).intersection(screen)
    }

    /// Converts a global rectangle into the coordinates of a view filling `container`.
    func local(_ rect: CGRect, in container: CGRect) -> CGRect {
        rect.offsetBy(dx: -container.minX, dy: -container.minY)
    }

    /// The vector that carries the orb's center onto the screen edge.
    var tuckOffset: CGVector {
        switch edge {
        case .left: CGVector(dx: screen.minX - orb.midX, dy: 0)
        case .right: CGVector(dx: screen.maxX - orb.midX, dy: 0)
        case .top: CGVector(dx: 0, dy: screen.maxY - orb.midY)
        case .bottom: CGVector(dx: 0, dy: screen.minY - orb.midY)
        }
    }

    func onOrb(_ point: CGPoint) -> Bool {
        let radius = Self.orbDiameter / 2
        let dx = (point.x - orb.midX) / radius
        let dy = (point.y - orb.midY) / radius
        return dx * dx + dy * dy <= 1
    }

    func contains(_ point: CGPoint, phase: CompanionPhase) -> Bool {
        if strip.contains(point) { return true }
        guard phase != .hidden else { return false }
        if onOrb(point) { return true }
        if phase == .expanded || phase == .pinned {
            let radius = Self.dashboardCornerRadius
            return CGPath(roundedRect: dashboard, cornerWidth: radius, cornerHeight: radius, transform: nil)
                .contains(point) || corridor.contains(point)
        }
        return false
    }
}
