//
//  CompanionMotion.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import QuartzCore

/// A spring described the way designers tune it: how long it feels and how much it bounces.
public struct MotionCurve: Equatable, Sendable {
    public let response: CFTimeInterval
    public let bounce: CGFloat

    public init(response: CFTimeInterval, bounce: CGFloat) {
        self.response = response
        self.bounce = bounce
    }

    /// The orb leaves the edge with a slight overshoot.
    public static let emerge = MotionCurve(response: 0.42, bounce: 0.22)
    /// The dashboard opens from the orb, almost critically damped.
    public static let expand = MotionCurve(response: 0.36, bounce: 0.1)
    /// Everything returns to the edge quickly and without bounce.
    public static let retract = MotionCurve(response: 0.26, bounce: 0)
    /// A released orb springs to its resting spot beside the edge.
    public static let settle = MotionCurve(response: 0.38, bounce: 0.18)
}

/// The two animatable properties of a companion layer. Both are composited by the render server.
public struct LayerPose: Equatable {
    public var opacity: Float
    public var transform: CATransform3D

    public static let identity = LayerPose(opacity: 1, transform: CATransform3DIdentity)

    public init(opacity: Float, transform: CATransform3D) {
        self.opacity = opacity
        self.transform = transform
    }

    /// A pose scaled about `pivot` (in the layer's bounds) and then moved by `offset`.
    public static func scaled(
        _ scale: CGFloat, about pivot: CGPoint, offset: CGVector = .zero, opacity: Float, in layer: CALayer
    ) -> LayerPose {
        // Transforms apply about the anchor point; shift the pivot onto it, scale, then shift back.
        let anchor = CGPoint(
            x: layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width,
            y: layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height)
        let dx = pivot.x - anchor.x
        let dy = pivot.y - anchor.y
        var transform = CATransform3DMakeTranslation(dx + offset.dx, dy + offset.dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -dx, -dy, 0)
        return LayerPose(opacity: opacity, transform: transform)
    }

    public static func == (lhs: LayerPose, rhs: LayerPose) -> Bool {
        lhs.opacity == rhs.opacity && CATransform3DEqualToTransform(lhs.transform, rhs.transform)
    }
}

extension CALayer {
    /// Moves the layer to `pose`, continuing from whatever is on screen now.
    ///
    /// Starting from the presentation layer makes a reversal mid-flight continue smoothly instead of
    /// jumping. `curve == nil` applies the pose at once. The completion also runs when a later move
    /// replaces this one, so callers must re-check their state.
    public func move(
        to pose: LayerPose, curve: MotionCurve?, delay: CFTimeInterval = 0, completion: (() -> Void)? = nil
    ) {
        let current = presentation() ?? self
        let fromOpacity = current.opacity
        let fromTransform = current.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        opacity = pose.opacity
        transform = pose.transform
        guard let curve else {
            removeAnimation(forKey: "pose.opacity")
            removeAnimation(forKey: "pose.transform")
            CATransaction.commit()
            return
        }
        let begin = delay > 0 ? convertTime(CACurrentMediaTime(), from: nil) + delay : 0
        if !CATransform3DEqualToTransform(fromTransform, pose.transform) {
            let spring = CASpringAnimation(perceptualDuration: curve.response, bounce: curve.bounce)
            spring.keyPath = "transform"
            spring.fromValue = NSValue(caTransform3D: fromTransform)
            spring.toValue = NSValue(caTransform3D: pose.transform)
            spring.duration = spring.settlingDuration
            spring.beginTime = begin
            spring.fillMode = .backwards
            add(spring, forKey: "pose.transform")
        } else {
            removeAnimation(forKey: "pose.transform")
        }
        if fromOpacity != pose.opacity {
            // Opacity never springs: overshooting a fade reads as a flicker.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = pose.opacity
            fade.duration = min(curve.response * 0.55, 0.22)
            fade.timingFunction = CAMediaTimingFunction(name: pose.opacity > fromOpacity ? .easeOut : .easeIn)
            fade.beginTime = begin
            fade.fillMode = .backwards
            add(fade, forKey: "pose.opacity")
        } else {
            removeAnimation(forKey: "pose.opacity")
        }
        CATransaction.commit()
    }
}
