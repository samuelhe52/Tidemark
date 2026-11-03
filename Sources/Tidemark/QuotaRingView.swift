//
//  QuotaRingView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// A compact quota-remaining gauge.
///
/// Unknown readings have no progress stroke.
final class QuotaRingView: NSView {
    private let remaining: Double?

    init(remaining: Double?) {
        self.remaining = remaining
        super.init(frame: .zero)

        let value = CompanionLabel(labelWithString: remaining.map(QuotaText.percent) ?? "—")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.textColor = remaining == nil ? .secondaryLabelColor : .labelColor
        let unit = CompanionLabel(
            labelWithString: remaining == nil ? String(localized: "unknown") : String(localized: "left"))
        unit.font = .systemFont(ofSize: 8)
        unit.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [value, unit])
        labels.orientation = .vertical
        labels.alignment = .centerX
        labels.spacing = 0
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            labels.centerXAnchor.constraint(equalTo: centerXAnchor),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2.5
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        track.stroke()

        guard let remaining, remaining > 0 else { return }
        let progress = NSBezierPath()
        progress.lineWidth = 2.5
        progress.lineCapStyle = .round
        if remaining >= 100 {
            progress.appendOval(in: rect)
        } else {
            progress.appendArc(
                withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
                startAngle: 90, endAngle: 90 - 360 * remaining / 100, clockwise: true)
        }
        NSColor.controlAccentColor.setStroke()
        progress.stroke()
    }
}
