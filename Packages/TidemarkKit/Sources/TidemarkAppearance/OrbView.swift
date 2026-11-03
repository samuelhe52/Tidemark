//
//  OrbView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// A small glass sphere with a quiet highlight and a shaded lower rim.
///
/// Receives presentation values, never engine or usage objects. Idle breathing is a Core Animation
/// loop, so it costs the main thread nothing while it runs.
public final class OrbView: NSView {
    private let body = NSView()
    private let surface: GlassSurfaceView
    private let lighting = SphereLightingView()
    private let symbol = NSImageView()

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
        body.addSubview(surface)
        lighting.autoresizingMask = [.width, .height]
        surface.contentView.addSubview(lighting)
        symbol.imageScaling = .scaleNone
        symbol.autoresizingMask = [.width, .height]
        surface.contentView.addSubview(symbol)
        addSubview(body)
        updateSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func layout() {
        super.layout()
        body.frame = bounds
        surface.frame = body.bounds
        surface.cornerRadius = bounds.height / 2
        lighting.frame = surface.contentView.bounds
        symbol.frame = surface.contentView.bounds
        updateBreathing()
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
        guard idleMotion, bounds.width > 0 else { return }
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

/// The resting state: a thin accent-colored pill against the screen edge.
public final class EdgeGlowView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    public override func layout() {
        super.layout()
        needsDisplay = true
    }
}
