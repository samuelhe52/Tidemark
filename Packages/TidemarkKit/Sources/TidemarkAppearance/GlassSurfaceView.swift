//
//  GlassSurfaceView.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// A floating surface in a system material. Add subviews to `contentView`.
///
/// On macOS 26 and later this is Liquid Glass; earlier systems get the popover material.
public final class GlassSurfaceView: NSView {
    public enum Kind {
        /// Untinted regular glass, for shapes that carry no text.
        case glass
        /// Regular glass tinted toward the window background, so text stays legible over a bright
        /// wallpaper. Untinted glass stays clear there while labels follow the system appearance.
        case content
    }

    /// How strongly `.content` glass leans toward the window background: 0 is clear glass, 1 opaque.
    public static let contentTintStrength: CGFloat = 0.6

    public let contentView = NSView()
    private let material: NSView
    private var maskRadius: CGFloat = 0

    public var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { applyCornerRadius() } }
    }

    public init(cornerRadius: CGFloat, kind: Kind) {
        self.cornerRadius = cornerRadius
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            if kind == .content {
                // A system color with alpha stays dynamic, so the tint follows light and dark mode.
                glass.tintColor = .windowBackgroundColor.withAlphaComponent(Self.contentTintStrength)
            }
            glass.contentView = contentView
            material = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(contentView)
            material = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        material.autoresizingMask = [.width, .height]
        contentView.autoresizingMask = [.width, .height]
        addSubview(material)
        applyCornerRadius()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func layout() {
        super.layout()
        material.frame = bounds
        if material is NSVisualEffectView {
            contentView.frame = material.bounds
            applyCornerRadius()
        }
    }

    private func applyCornerRadius() {
        if #available(macOS 26, *), let glass = material as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let effect = material as? NSVisualEffectView {
            // Glass clamps an oversized radius into a capsule; the mask does the same.
            let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
            if effect.maskImage == nil || maskRadius != radius {
                maskRadius = radius
                effect.maskImage = Self.mask(radius: radius)
            }
        }
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
