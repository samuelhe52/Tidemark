//
//  UsageChartView.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit

/// A chart whose hover follows the pointer position the controller reconciles.
///
/// Tracking areas cannot drive this: the dashboard's rebuild re-adds reused rows, and AppKit then
/// sends a view under the pointer neither `mouseMoved` nor `mouseExited`, leaving its hover stuck.
protocol HoverReconciling {
    func reconcileHover(at screenPoint: CGPoint)
}

extension NSView {
    /// A screen point in local coordinates, when it falls on the part of this view that is showing.
    func visiblePoint(_ screenPoint: CGPoint) -> NSPoint? {
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        // An unclipped view's visible rect can extend past its bounds.
        return bounds.intersection(visibleRect).contains(point) ? point : nil
    }
}

/// Token usage over time as bars. Hovering a bar shows its figures in the readout line; otherwise
/// the readout names the busiest bar.
final class UsageChartView: NSStackView, HoverReconciling {
    struct Bar: Hashable {
        let value: Int
        let label: String
        let detail: String
    }

    private let bars: [Bar]
    private let readout = CompanionLabel("", size: 10, color: .secondaryLabelColor, monospacedDigits: true)
    private let idleText: String
    private let plot: BarPlotView

    init(bars: [Bar], leading: String, trailing: String, range: String) {
        self.bars = bars
        let peak = bars.indices.max { bars[$0].value < bars[$1].value }
        idleText =
            peak.flatMap {
                bars[$0].value > 0 ? String(localized: "Busiest \(bars[$0].label) · \(bars[$0].detail)") : nil
            }
            ?? ""
        plot = BarPlotView(values: bars.map(\.value))
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4

        readout.lineBreakMode = .byTruncatingTail
        readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readout.stringValue = idleText

        plot.hovered = { [weak self] index in self?.show(index) }
        plot.setAccessibilityElement(true)
        plot.setAccessibilityRole(.image)
        plot.setAccessibilityLabel(String(localized: "Token usage over \(range.lowercased()). \(idleText)"))

        let axis = NSStackView(views: [Self.axisLabel(leading), NSView(), Self.axisLabel(trailing)])
        axis.distribution = .fill
        for view in [readout, plot, axis] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        setCustomSpacing(2, after: plot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reconcileHover(at screenPoint: CGPoint) { plot.reconcileHover(at: screenPoint) }

    private func show(_ index: Int?) {
        guard let index, bars.indices.contains(index) else {
            readout.stringValue = idleText
            readout.textColor = .secondaryLabelColor
            return
        }
        readout.stringValue = "\(bars[index].label) · \(bars[index].detail)"
        readout.textColor = .labelColor
    }

    private static func axisLabel(_ text: String) -> NSTextField {
        CompanionLabel(text, size: 9, color: .tertiaryLabelColor)
    }
}

/// The bars themselves; reports the bar under the pointer.
fileprivate final class BarPlotView: NSView {
    var hovered: ((Int?) -> Void)?
    private let values: [Int]
    private var hoveredIndex: Int? {
        didSet {
            guard hoveredIndex != oldValue else { return }
            needsDisplay = true
            hovered?(hoveredIndex)
        }
    }

    init(values: [Int]) {
        self.values = values
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 56).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { false }

    func reconcileHover(at screenPoint: CGPoint) {
        guard !values.isEmpty, bounds.width > 0, let point = visiblePoint(screenPoint) else {
            hoveredIndex = nil
            return
        }
        hoveredIndex = min(values.count - 1, max(0, Int(point.x / (bounds.width / CGFloat(values.count)))))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let count = CGFloat(values.count)
        let gap: CGFloat = values.count > 40 ? 1 : 2
        let width = max(1, (bounds.width - gap * (count - 1)) / count)
        let peak = CGFloat(max(values.max() ?? 0, 1))
        let radius = min(2, width / 2)
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * (width + gap)
            if value == 0 {
                NSColor.quaternaryLabelColor.setFill()
                NSRect(x: x, y: 0, width: width, height: 1).fill()
                continue
            }
            let height = max(2, bounds.height * CGFloat(value) / peak)
            let dimmed = hoveredIndex != nil && hoveredIndex != index
            NSColor.controlAccentColor.withAlphaComponent(dimmed ? 0.35 : 0.9).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: width, height: height), xRadius: radius, yRadius: radius
            )
            .fill()
        }
    }
}
