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
    /// The docked tab: how far it shows from the edge, and how long it runs along it.
    static let dockDepth: CGFloat = 8
    static let dockLength: CGFloat = 48

    let edge: DockEdge
    let screen: CGRect
    let frame: CGRect
    let orb: CGRect
    let dashboard: CGRect
    let summary: CGRect
    let strip: CGRect
    /// The orb's glass while hidden: a capsule centered on the screen edge, so only half shows.
    let dock: CGRect
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

        // The hover strip covers the visible half of the dock with a little to spare.
        let depth = Self.dockDepth
        let length = Self.dockLength
        let stripDepth = depth + 2
        let stripLength: CGFloat = 64
        switch edge {
        case .left, .right:
            let x = edge == .left ? screen.minX : screen.maxX
            dock = CGRect(x: x - depth, y: anchor.point.y - length / 2, width: depth * 2, height: length)
            strip = CGRect(
                x: edge == .left ? x : x - stripDepth, y: anchor.point.y - stripLength / 2, width: stripDepth,
                height: stripLength)
        case .top, .bottom:
            let y = edge == .bottom ? screen.minY : screen.maxY
            dock = CGRect(x: anchor.point.x - length / 2, y: y - depth, width: length, height: depth * 2)
            strip = CGRect(
                x: anchor.point.x - stripLength / 2, y: edge == .bottom ? y : y - stripDepth, width: stripLength,
                height: stripDepth)
        }
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
        // The strip holds the dock's visible half, so the frame reaches the orb's resting shape.
        frame = orb.union(dashboard).union(summary).union(strip)
            .insetBy(dx: -10, dy: -10).intersection(screen)
    }

    /// Converts a global rectangle into the coordinates of a view filling `container`.
    func local(_ rect: CGRect, in container: CGRect) -> CGRect {
        rect.offsetBy(dx: -container.minX, dy: -container.minY)
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
