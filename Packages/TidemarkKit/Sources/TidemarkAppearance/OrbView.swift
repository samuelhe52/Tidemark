//
//  OrbView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import SwiftUI

/// A small glass sphere with a quiet highlight and a shaded lower rim.
///
/// Receives presentation values, never engine or usage objects. Idle breathing is a Core Animation
/// loop, so it costs the main thread nothing while it runs. While docked, the same glass reshapes into
/// a plain glass tab against the screen edge.
public final class OrbView: NSView {
    private let body = NSView()
    private let surface: GlassSurfaceView
    private let lighting = SphereLightingView()
    private let symbol = NSImageView()
    /// The body frame the last `applyShape` targeted. Every step of a morph resizes the body, which
    /// asks this view for layout; comparing targets keeps `layout()` from snapping the morph to its end.
    private var shapeTarget: CGRect?
    /// The body size the breathing loop's pivot was computed for.
    private var breathingSize: CGSize?
    /// The shape the glass shows or is morphing toward. It trails `docked` while a delayed morph waits.
    private var shapeDocked = false
    private var morphGeneration = 0
    /// The completion of a delayed morph that has not started yet.
    private var pendingCompletion: (() -> Void)?
    public private(set) var docked = false

    /// Where the glass rests while docked, in this view's coordinates; usually outside its bounds.
    public var dockedFrame: CGRect = .zero {
        didSet { if dockedFrame != oldValue { needsLayout = true } }
    }

    public var pinned = false {
        didSet { if pinned != oldValue { updateSymbol() } }
    }

    /// Off for Reduce Motion, Low Power Mode, and whenever the orb is not on screen.
    public var idleMotion = false {
        didSet { if idleMotion != oldValue { updateBreathing() } }
    }

    public override init(frame frameRect: NSRect) {
        surface = GlassSurfaceView(cornerRadius: frameRect.height / 2, kind: .glass)
        super.init(frame: frameRect)
        wantsLayer = true
        body.wantsLayer = true
        // Autoresizing, not `layout()`, sizes the body's subviews, so they follow an animated frame.
        body.autoresizesSubviews = true
        surface.autoresizingMask = [.width, .height]
        body.addSubview(surface)
        for view in [lighting, symbol] as [NSView] {
            view.autoresizingMask = [.width, .height]
            surface.contentView.addSubview(view)
        }
        symbol.imageScaling = .scaleNone
        addSubview(body)
        updateSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func layout() {
        super.layout()
        // Only a geometry change re-applies the shape; an in-flight morph also lands here every frame.
        if shapeTarget != currentTarget { applyShape() }
        // The system clamps the orb's radius into a capsule for the thin tab, so one radius serves both.
        surface.cornerRadius = bounds.height / 2
        if idleMotion, body.bounds.size != breathingSize { updateBreathing() }
    }

    /// Reshapes the glass into the docked tab or back into the sphere, continuing from what is on
    /// screen. `curve == nil` changes it at once. `completion` also runs when a later call replaces
    /// this one.
    public func setDocked(
        _ docked: Bool, curve: MotionCurve?, delay: TimeInterval = 0, completion: @escaping () -> Void
    ) {
        self.docked = docked
        morphGeneration += 1
        // A replaced morph that never started reports back too, like one replaced in flight.
        if let replaced = pendingCompletion {
            pendingCompletion = nil
            replaced()
        }
        guard let curve, delay > 0 else {
            morph(curve: curve, completion: completion)
            return
        }
        // Wait here rather than with `Animation.delay`: a delayed SwiftUI animation that replaces one in
        // flight first jumps to the old target. Waiting lets the current morph run on, then turn around.
        let generation = morphGeneration
        pendingCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.morphGeneration, let completion = self.pendingCompletion else { return }
            self.pendingCompletion = nil
            self.morph(curve: curve, completion: completion)
        }
    }

    private func morph(curve: MotionCurve?, completion: @escaping () -> Void) {
        shapeDocked = docked
        guard let curve else {
            applyShape()
            completion()
            return
        }
        // Opacity never springs: overshooting a fade reads as a flicker.
        NSAnimationContext.animate(.easeInOut(duration: min(curve.response * 0.55, 0.22))) { applyLighting() }
        NSAnimationContext.animate(
            .spring(duration: curve.response, bounce: curve.bounce), changes: { applyShape(lighting: false) },
            completion: completion)
    }

    private var currentTarget: CGRect { shapeDocked ? dockedFrame : bounds }

    private func applyShape(lighting: Bool = true) {
        let target = currentTarget
        shapeTarget = target
        if body.frame != target { body.frame = target }
        if lighting { applyLighting() }
    }

    /// The sphere's lighting would read as a misplaced highlight on the flat tab, so it fades out.
    private func applyLighting() {
        lighting.alphaValue = shapeDocked ? 0 : 1
    }

    private func updateSymbol() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        symbol.isHidden = !pinned
        symbol.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.contentTintColor = .secondaryLabelColor
    }

    private func updateBreathing() {
        guard let layer = body.layer else { return }
        layer.removeAnimation(forKey: "idle")
        breathingSize = nil
        guard idleMotion, body.bounds.width > 0 else { return }
        // The pivot is the body's own center, so the loop is rebuilt whenever the body changes size.
        breathingSize = body.bounds.size
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let breath = CABasicAnimation(keyPath: "transform")
        breath.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        breath.toValue = NSValue(
            caTransform3D: LayerPose.scaled(1.015, about: center, opacity: 1, in: layer).transform)
        breath.duration = 3.5
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breath, forKey: "idle")
    }
}

/// Static lighting sits above the native glass; it needs no frame-by-frame drawing.
fileprivate final class SphereLightingView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let sphere = bounds.insetBy(dx: 0.75, dy: 0.75)
        let outline = NSBezierPath(ovalIn: sphere)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()

        // Light from above-left, with just a trace of cool color at the base.
        NSGradient(colors: [
            .white.withAlphaComponent(0.32), .white.withAlphaComponent(0.02),
            .black.withAlphaComponent(0.12)
        ])?.draw(in: sphere, angle: -55)
        let pool = NSRect(
            x: sphere.minX + sphere.width * 0.1, y: sphere.minY - sphere.height * 0.35,
            width: sphere.width * 0.95, height: sphere.height * 0.8)
        NSGradient(starting: NSColor.controlAccentColor.withAlphaComponent(0.18), ending: .clear)?
            .draw(in: NSBezierPath(ovalIn: pool), relativeCenterPosition: .zero)

        let reflection = NSRect(
            x: sphere.minX + sphere.width * 0.2, y: sphere.minY + sphere.height * 0.59,
            width: sphere.width * 0.4, height: sphere.height * 0.25)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.55), ending: .clear)?
            .draw(in: NSBezierPath(ovalIn: reflection), relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: .white.withAlphaComponent(0.65), ending: .white.withAlphaComponent(0.08))?
            .draw(in: rim(of: sphere), angle: -65)
    }

    private func rim(of rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: rect)
        path.appendOval(in: rect.insetBy(dx: 0.75, dy: 0.75))
        path.windingRule = .evenOdd
        return path
    }
}
