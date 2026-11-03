//
//  OrbView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// Provisional orb: a glass disc carrying one symbol.
///
/// Receives presentation values, never engine or usage objects. Idle breathing is a Core Animation
/// loop, so it costs the main thread nothing while it runs.
public final class OrbView: NSView {
    private let body = NSView()
    private let surface: GlassSurfaceView
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
        symbol.imageScaling = .scaleNone
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
        symbol.frame = surface.contentView.bounds
        updateBreathing()
    }

    private func updateSymbol() {
        let name = pinned ? "pin.fill" : "water.waves"
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    private func updateBreathing() {
        guard let layer = body.layer else { return }
        layer.removeAnimation(forKey: "idle")
        guard idleMotion, bounds.width > 0 else { return }
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let breath = CABasicAnimation(keyPath: "transform")
        breath.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        breath.toValue = NSValue(
            caTransform3D: LayerPose.scaled(1.035, about: center, opacity: 1, in: layer).transform)
        breath.duration = 2.25
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breath, forKey: "idle")
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
