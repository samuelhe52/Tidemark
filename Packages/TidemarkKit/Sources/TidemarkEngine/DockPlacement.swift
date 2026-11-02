//
//  DockPlacement.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import CoreGraphics
import Foundation

public enum DockEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom
}

public struct DockPlacement: Codable, Equatable {
    public var displayID: String
    public var edge: DockEdge
    public var along: Double

    public init(displayID: String, edge: DockEdge = .right, along: Double = 0.5) {
        self.displayID = displayID
        self.edge = edge
        self.along = along.isFinite ? min(1, max(0, along)) : 0.5
    }
}

public struct DockDisplay {
    public let id: String
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct DockAnchor {
    public let placement: DockPlacement
    public let point: CGPoint
    public let visibleFrame: CGRect
}

/// Geometry only; the host supplies Cocoa-coordinate display rectangles and stable display IDs.
public enum DockGeometry {
    public static func resolve(_ placement: DockPlacement, displays: [DockDisplay]) -> DockAnchor? {
        guard let display = displays.first(where: { $0.id == placement.displayID }) ?? displays.first else {
            return nil
        }
        let target = point(on: display.visibleFrame, edge: placement.edge, along: placement.along)
        let sameEdge = candidates(display: display, edge: placement.edge, displays: displays, near: target)
        return closest(in: sameEdge, to: target) ?? nearest(to: target, displays: displays)
    }

    public static func nearest(to point: CGPoint, displays: [DockDisplay]) -> DockAnchor? {
        let anchors = displays.flatMap { display in
            DockEdge.allCases.flatMap { candidates(display: display, edge: $0, displays: displays, near: point) }
        }
        return closest(in: anchors, to: point)
    }

    private static func closest(in anchors: [DockAnchor], to point: CGPoint) -> DockAnchor? {
        anchors.min { squaredDistance($0.point, point) < squaredDistance($1.point, point) }
    }

    private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    private static func point(on frame: CGRect, edge: DockEdge, along: Double) -> CGPoint {
        let fraction = along.isFinite ? min(1, max(0, along)) : 0.5
        switch edge {
        case .left: return CGPoint(x: frame.minX, y: frame.minY + frame.height * fraction)
        case .right: return CGPoint(x: frame.maxX, y: frame.minY + frame.height * fraction)
        case .top: return CGPoint(x: frame.minX + frame.width * fraction, y: frame.maxY)
        case .bottom: return CGPoint(x: frame.minX + frame.width * fraction, y: frame.minY)
        }
    }

    private static func candidates(
        display: DockDisplay, edge: DockEdge, displays: [DockDisplay], near target: CGPoint
    ) -> [DockAnchor] {
        let vertical = edge == .left || edge == .right
        let frame = display.visibleFrame
        let low = vertical ? frame.minY : frame.minX
        let length = vertical ? frame.height : frame.width
        let margin = min(48, length / 2)
        var segments = [(low + margin, low + length - margin)]
        for other in displays where other.id != display.id {
            let a = display.frame
            let b = other.frame
            let isSeam: Bool
            switch edge {
            case .left: isSeam = abs(a.minX - b.maxX) < 1
            case .right: isSeam = abs(a.maxX - b.minX) < 1
            case .top: isSeam = abs(a.maxY - b.minY) < 1
            case .bottom: isSeam = abs(a.minY - b.maxY) < 1
            }
            guard isSeam else { continue }
            let cutLow = (vertical ? b.minY : b.minX) - 48
            let cutHigh = (vertical ? b.maxY : b.maxX) + 48
            segments = segments.flatMap { start, end -> [(CGFloat, CGFloat)] in
                guard cutLow < end, cutHigh > start else { return [(start, end)] }
                var result: [(CGFloat, CGFloat)] = []
                if cutLow > start { result.append((start, cutLow)) }
                if cutHigh < end { result.append((cutHigh, end)) }
                return result
            }
        }
        return segments.map { start, end in
            let coordinate = min(end, max(start, vertical ? target.y : target.x))
            let along = length > 0 ? (coordinate - low) / length : 0.5
            let placement = DockPlacement(displayID: display.id, edge: edge, along: along)
            return DockAnchor(
                placement: placement, point: point(on: frame, edge: edge, along: along), visibleFrame: frame)
        }
    }
}
