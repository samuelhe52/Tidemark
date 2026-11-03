//
//  ContentMotion.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// Shared timing for content transitions inside the summary and dashboard.
enum ContentMotion {
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static func duration(reduced: Bool) -> CFTimeInterval { reduced ? 0.12 : 0.24 }

    static let transformKey = "content.transform"
    static let opacityKey = "content.opacity"
}

extension NSView {
    /// This view's rect in screen coordinates: where it appears now, or with `model`, where it will rest.
    func screenFrame(model: Bool = false) -> CGRect {
        guard let window, let superview else { return .zero }
        let rect = model ? frame : layer?.presentation()?.frame ?? frame
        return window.convertToScreen(superview.convert(rect, to: nil))
    }

    /// Animates this view from its old screen rect to its current frame.
    ///
    /// Rows only translate, top edge to top edge, so their text never stretches; glass surfaces also scale.
    func animateMove(from previous: CGRect, duration: CFTimeInterval, scales: Bool = false) {
        guard let window, let superview, let layer else { return }
        let target = frame
        let old = superview.convert(window.convertFromScreen(previous), from: nil)
        guard target.width > 0, target.height > 0, old != target else { return }
        let transform: CATransform3D
        if scales {
            let anchor = layer.anchorPoint
            let dx = old.minX + old.width * anchor.x - target.minX - target.width * anchor.x
            let dy = old.minY + old.height * anchor.y - target.minY - target.height * anchor.y
            transform = CATransform3DScale(
                CATransform3DMakeTranslation(dx, dy, 0), old.width / target.width, old.height / target.height, 1)
        } else {
            let dy = superview.isFlipped ? old.minY - target.minY : old.maxY - target.maxY
            guard old.minX != target.minX || dy != 0 else { return }
            transform = CATransform3DMakeTranslation(old.minX - target.minX, dy, 0)
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: transform)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: ContentMotion.transformKey)
    }
}

extension CALayer {
    /// Staggered so outgoing and incoming text are barely visible together; a plain crossfade shows
    /// both at half strength halfway through.
    func addContentFade(appearing: Bool, duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = appearing ? [0, 0, 1] : [1, 0, 0]
        animation.keyTimes = appearing ? [0, 0.4, 1] : [0, 0.6, 1]
        animation.duration = duration
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        add(animation, forKey: ContentMotion.opacityKey)
    }

    func addContentSlide(from: CGPoint, to: CGPoint, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(from.x, from.y, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(to.x, to.y, 0))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(animation, forKey: ContentMotion.transformKey)
    }
}
