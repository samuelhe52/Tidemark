//
//  DashboardView+History.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkData

/// The CC Switch usage history section.
extension DashboardView {
    @objc func historyViewChosen(_ sender: NSSegmentedControl) {
        guard HistoryView.allCases.indices.contains(sender.selectedSegment) else { return }
        onHistoryViewChanged?(HistoryView.allCases[sender.selectedSegment])
    }

    @objc func historyRangeChosen(_ sender: NSPopUpButton) {
        guard let range = sender.selectedItem?.representedObject as? String,
            let value = UsageHistoryRange(rawValue: range)
        else { return }
        onHistoryRangeChanged?(value)
    }

    func appendHistory(_ history: History, now: Date, previous: [RowID: ContentRow]) {
        let rangeName = HistoryText.range(history.range)
        // The header outlives selection changes: rebuilding it would crossfade the control being clicked.
        append(.historyHeader, state: 0, previous: previous) {
            let controls = NSStackView(views: [historyViewPicker, historyRangePicker])
            controls.spacing = 4
            controls.alignment = .centerY
            return Self.row(Self.label(String(localized: "Usage"), size: 13, weight: .semibold), controls)
        }
        historyViewPicker.selectedSegment = HistoryView.allCases.firstIndex(of: history.view) ?? 0
        historyRangePicker.selectItem(at: UsageHistoryRange.allCases.firstIndex(of: history.range) ?? 0)
        // Figures for another range never stand in for the chosen one.
        let usage = history.usage.flatMap { $0.range == history.range ? $0 : nil }
        if let usage, !usage.apps.isEmpty {
            let total = usage.total
            let tokens = String(localized: "\(HistoryText.tokens(total.totalTokens)) tokens")
            let cost = HistoryText.cost(total.costUSD)
            let note = [
                String(localized: "API-equivalent estimate"),
                usage.latestRecordAt.map { String(localized: "last request \(QuotaText.age($0, now: now))") }
            ].compactMap { $0 }.joined(separator: " · ")
            let description = String(
                localized:
                    "\(rangeName): \(tokens), about \(cost) at API prices, not a bill. \(HistoryText.breakdown(total))")
            // Reuse state covers every input of the view, including its tooltip.
            append(
                .historyTotal, state: [tokens, cost, note, description], motionState: [tokens, cost],
                previous: previous
            ) {
                historyTotal(tokens: tokens, cost: cost, note: note, description: description)
            }
            switch history.view {
            case .chart:
                let bars = usage.buckets.map { bucket in
                    UsageChartView.Bar(
                        value: bucket.totals.totalTokens,
                        label: HistoryText.bucket(bucket.interval.start, unit: usage.range.bucketUnit),
                        detail: HistoryText.summary(bucket.totals))
                }
                let axis = (bars.first?.label ?? "", bars.last?.label ?? "")
                append(
                    .historyChart,
                    state: [bars as AnyHashable, rangeName], motionState: usage.range, previous: previous
                ) {
                    UsageChartView(bars: bars, leading: axis.0, trailing: axis.1, range: rangeName)
                }
            case .harness, .model:
                let groups = history.view == .harness ? usage.apps : usage.models
                for row in Self.groupRows(groups, view: history.view) {
                    let value = HistoryText.summary(row.totals, requests: false)
                    let share = total.totalTokens > 0 ? Double(row.totals.totalTokens) / Double(total.totalTokens) : 0
                    let description = "\(row.name): \(value). \(HistoryText.breakdown(row.totals))"
                    append(
                        .historyGroup("\(history.view.rawValue):\(row.key)"),
                        state: [row.name, value, String(share), description], previous: previous
                    ) {
                        historyGroup(name: row.name, value: value, share: share, description: description)
                    }
                }
            }
        }
        let status: String? =
            if let issue = history.issue {
                HistoryText.issue(issue)
            } else if let usage {
                usage.apps.isEmpty ? String(localized: "No usage in \(rangeName.lowercased())") : nil
            } else {
                String(localized: "Reading CC Switch history…")
            }
        if let status {
            append(.historyStatus, state: status, previous: previous) { Self.caption(status) }
        }
    }

    /// The largest groups by tokens; past six, the smallest fold into one "Other" row.
    static func groupRows(_ groups: [UsageGroup], view: HistoryView) -> [(
        key: String, name: String, totals: UsageTotals
    )] {
        let limit = 6
        let named = groups.count > limit ? Array(groups.prefix(limit - 1)) : groups
        var rows = named.map { group in
            (
                key: group.key,
                name: view == .harness ? HistoryText.appName(group.key) : HistoryText.modelName(group.key),
                totals: group.totals
            )
        }
        let rest = groups.dropFirst(named.count)
        if !rest.isEmpty {
            let name =
                view == .harness
                ? String(localized: "\(rest.count) other harnesses") : String(localized: "\(rest.count) other models")
            rows.append((key: "\u{0}other", name: name, totals: rest.reduce(UsageTotals()) { $0 + $1.totals }))
        }
        return rows
    }

    func historyTotal(tokens: String, cost: String, note: String, description: String) -> NSView {
        let amount = Self.label(tokens, size: 20, weight: .semibold, monospacedDigits: true)
        let estimate = Self.label(
            cost, size: 13, weight: .medium, color: .secondaryLabelColor, monospacedDigits: true)
        let stack = Self.column(spacing: 2)
        stack.addArrangedSubview(Self.row(amount, estimate))
        stack.addArrangedSubview(Self.caption(note))
        Self.fill(stack)
        Self.describe(stack, description)
        return stack
    }

    func historyGroup(name: String, value: String, share: Double, description: String) -> NSView {
        let title = Self.label(name, size: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = name
        let figures = Self.label(value, size: 11, color: .secondaryLabelColor, monospacedDigits: true)
        let stack = Self.column(spacing: 4)
        stack.addArrangedSubview(Self.row(title, figures))
        stack.addArrangedSubview(ShareBarView(share: share))
        Self.fill(stack)
        Self.describe(stack, description)
        return stack
    }
}

/// A thin track filled to an app's share of the range's tokens.
fileprivate final class ShareBarView: NSView {
    private let share: Double
    private let fill = CALayer()

    init(share: Double) {
        self.share = min(max(share, 0), 1)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 1.5
        layer?.masksToBounds = true
        fill.cornerRadius = 1.5
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: 3).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            fill.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * share, height: bounds.height)
        CATransaction.commit()
    }
}
