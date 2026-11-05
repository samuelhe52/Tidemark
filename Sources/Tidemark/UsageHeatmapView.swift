//
//  UsageHeatmapView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/4.
//

import AppKit
import TidemarkData

/// Daily token usage, with one intensity scale shared by every 53-week span.
///
/// The dashboard rebuilds this view whenever today's totals change, so the shown span is owned by
/// the caller and passed back in through `onPageChange`.
final class UsageHeatmapView: NSStackView, HoverReconciling {
    /// A span is 53 weeks; page 0 ends with the current week.
    private static let spanDays = 371

    private let days: [UsageBucket]
    private let calendar = Calendar.current
    private let title = CompanionLabel("", size: 9, color: .secondaryLabelColor)
    private let readout = CompanionLabel("", size: 10, color: .secondaryLabelColor, monospacedDigits: true)
    private let older = NSButton()
    private let newer = NSButton()
    private let plot: HeatmapPlotView
    private let onPageChange: (Int) -> Void
    private var page: Int

    init(days: [UsageBucket], page: Int, onPageChange: @escaping (Int) -> Void) {
        self.days = days
        self.onPageChange = onPageChange
        self.page = 0
        plot = HeatmapPlotView(peak: days.map(\.totals.totalTokens).max() ?? 0)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        readout.lineBreakMode = .byTruncatingTail
        readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, symbol, text, action) in [
            (older, "chevron.left", String(localized: "Earlier usage"), #selector(showOlder)),
            (newer, "chevron.right", String(localized: "Later usage"), #selector(showNewer))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
            button.isBordered = false
            button.controlSize = .small
            button.toolTip = text
            button.target = self
            button.action = action
        }
        let header = NSStackView(views: [title, NSView(), older, newer])
        header.spacing = 4
        let legend = NSStackView()
        legend.spacing = 3
        legend.addArrangedSubview(CompanionLabel(String(localized: "Less"), size: 8, color: .tertiaryLabelColor))
        for level in 0...4 {
            let swatch = HeatmapSwatchView(level: level)
            swatch.widthAnchor.constraint(equalToConstant: 6).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 6).isActive = true
            legend.addArrangedSubview(swatch)
        }
        legend.addArrangedSubview(CompanionLabel(String(localized: "More"), size: 8, color: .tertiaryLabelColor))
        let footer = NSStackView(views: [NSView(), legend])
        for view in [header, readout, plot, footer] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        plot.hovered = { [weak self] day in
            guard let self else { return }
            readout.stringValue =
                day.map {
                    "\($0.interval.start.formatted(.dateTime.year().month(.abbreviated).day())) · \(HistoryText.summary($0.totals))"
                } ?? String(localized: "Daily token usage")
            readout.textColor = day == nil ? .secondaryLabelColor : .labelColor
        }
        self.page = min(max(0, page), lastPage)
        updateSpan()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func showOlder() { show(page: page + 1) }
    @objc private func showNewer() { show(page: page - 1) }

    private func show(page: Int) {
        self.page = min(max(0, page), lastPage)
        onPageChange(self.page)
        updateSpan()
    }

    /// The day after the current week's Sunday: where page 0 ends.
    private var currentWeekEnd: Date? {
        guard let last = days.last?.interval.start else { return nil }
        // Monday = 0, Sunday = 6, independent of the locale's first weekday setting.
        let row = (calendar.component(.weekday, from: last) + 5) % 7
        return calendar.date(byAdding: .day, value: 7 - row, to: last)
    }

    /// The page holding the first day of usage.
    private var lastPage: Int {
        guard let first = days.first?.interval.start, let weekEnd = currentWeekEnd,
            let span = calendar.dateComponents([.day], from: first, to: weekEnd).day, span > 0
        else { return 0 }
        return (span - 1) / Self.spanDays
    }

    func reconcileHover(at screenPoint: CGPoint) { plot.reconcileHover(at: screenPoint) }

    private func updateSpan() {
        guard let first = days.first?.interval.start, let last = days.last?.interval.start,
            let weekEnd = currentWeekEnd,
            let end = calendar.date(byAdding: .day, value: -page * Self.spanDays, to: weekEnd),
            let start = calendar.date(byAdding: .day, value: -Self.spanDays, to: end),
            let finalDay = calendar.date(byAdding: .day, value: -1, to: end)
        else { return }
        let visible = days.filter { $0.interval.start >= start && $0.interval.start < end }
        title.stringValue =
            "\(max(first, start).formatted(.dateTime.month(.abbreviated).day().year())) – \(min(last, finalDay).formatted(.dateTime.month(.abbreviated).day().year()))"
        older.isEnabled = first < start
        newer.isEnabled = page > 0
        readout.stringValue = String(localized: "Daily token usage")
        readout.textColor = .secondaryLabelColor
        plot.setSpan(start: start, days: visible, calendar: calendar)
    }
}

fileprivate final class HeatmapPlotView: NSView {
    var hovered: ((UsageBucket?) -> Void)?
    private let peak: Int
    private var days: [Int: UsageBucket] = [:]
    private var start = Date()
    private var calendar = Calendar.current
    private var selected: Int? {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
            hovered?(selected.flatMap { days[$0] })
        }
    }

    init(peak: Int) {
        self.peak = max(peak, 1)
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 65).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    func setSpan(start: Date, days: [UsageBucket], calendar: Calendar) {
        self.start = start
        self.calendar = calendar
        self.days = Dictionary(
            uniqueKeysWithValues: days.map {
                (calendar.dateComponents([.day], from: start, to: $0.interval.start).day ?? 0, $0)
            })
        selected = nil
        let total = days.reduce(UsageTotals()) { $0 + $1.totals }
        setAccessibilityLabel(String(localized: "Daily token usage heat map. \(HistoryText.summary(total))"))
        needsDisplay = true
    }

    static func color(level: Int) -> NSColor {
        level == 0 ? .quaternaryLabelColor : .controlAccentColor.withAlphaComponent(0.2 + Double(level) * 0.2)
    }

    private var pitch: CGFloat { max(0, (bounds.width - 20) / 53) }
    private func cell(_ index: Int) -> NSRect {
        NSRect(
            x: 20 + CGFloat(index / 7) * pitch, y: 15 + CGFloat(index % 7) * pitch,
            width: max(0, pitch - 1), height: max(0, pitch - 1))
    }

    func reconcileHover(at screenPoint: CGPoint) {
        guard pitch > 0, let point = visiblePoint(screenPoint), point.x >= 20, point.y >= 15,
            point.y < 15 + pitch * 7
        else {
            selected = nil
            return
        }
        // The gaps between cells belong to the cell before them, so the readout never flickers.
        let index = Int((point.x - 20) / pitch) * 7 + Int((point.y - 15) / pitch)
        selected = days[index] != nil ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor
        ]
        // Rows run Monday to Sunday; the symbols run Sunday to Saturday.
        let weekdays = calendar.shortWeekdaySymbols
        for row in [0, 2, 4] where weekdays.count == 7 {
            (weekdays[(row + 1) % 7] as NSString).draw(
                at: NSPoint(x: 0, y: 13 + CGFloat(row) * pitch), withAttributes: attributes)
        }
        var lastLabelX: CGFloat = -100
        for column in 0..<53 {
            guard let date = calendar.date(byAdding: .day, value: column * 7, to: start) else { continue }
            let day = calendar.component(.day, from: date)
            let x = cell(column * 7).minX
            if column == 0 || day <= 7, x - lastLabelX >= 20, x < bounds.width - 18 {
                (date.formatted(.dateTime.month(.abbreviated)) as NSString)
                    .draw(at: NSPoint(x: x, y: 0), withAttributes: attributes)
                lastLabelX = x
            }
        }
        for (index, day) in days {
            let tokens = day.totals.totalTokens
            let level = tokens <= 0 ? 0 : min(4, max(1, Int(ceil(sqrt(Double(tokens) / Double(peak)) * 4))))
            Self.color(level: level).setFill()
            let rect = cell(index)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            if selected == index {
                NSColor.labelColor.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), xRadius: 1, yRadius: 1)
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }
}

fileprivate final class HeatmapSwatchView: NSView {
    private let level: Int

    init(level: Int) {
        self.level = level
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        HeatmapPlotView.color(level: level).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
    }
}
