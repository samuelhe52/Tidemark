//
//  CompanionLabel.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// Uses normal text compositing to preserve smooth glyph edges on the glass surface.
///
/// A native A/B probe reproduced harsh text with vibrant labels; forcing antialiasing
/// did not help. Control-text colors also avoid the vibrant label palette, whose
/// secondary tones are meant for special blending rather than normal compositing.
final class CompanionLabel: NSTextField {
    private static let secondaryText = controlTextColor(alpha: 0.7)
    private static let tertiaryText = controlTextColor(alpha: 0.6)

    /// A one-line label in the system font.
    convenience init(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
        monospacedDigits: Bool = false
    ) {
        self.init(labelWithString: text)
        font =
            monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        textColor = color
    }

    override var allowsVibrancy: Bool { false }

    override var textColor: NSColor? {
        get { super.textColor }
        set {
            if newValue == .labelColor {
                super.textColor = .controlTextColor
            } else if newValue == .secondaryLabelColor {
                super.textColor = Self.secondaryText
            } else if newValue == .tertiaryLabelColor {
                super.textColor = Self.tertiaryText
            } else {
                super.textColor = newValue
            }
        }
    }

    private static func controlTextColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            // Applying alpha before attachment can resolve a dynamic color in the wrong appearance.
            var color = NSColor.controlTextColor
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.controlTextColor.withAlphaComponent(alpha)
            }
            return color
        }
    }
}
