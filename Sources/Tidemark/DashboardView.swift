//
//  DashboardView.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkAppearance
import TidemarkData

/// The shared quota dashboard: system material, system type and standard controls.
final class DashboardView: NSView {
    static let width: CGFloat = 340
    private static let padding: CGFloat = 16

    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onHistoryRangeChanged: ((UsageHistoryRange) -> Void)?
    var onHistoryViewChanged: ((HistoryView) -> Void)?

    /// How the history section breaks down the range.
    enum HistoryView: String, CaseIterable {
        case chart, harness, model
    }

    /// CC Switch history for the dashboard: the chosen range and the newest reading for it.
    struct History {
        var range: UsageHistoryRange
        var view: HistoryView
        /// Nil until the first read for `range` finishes.
        var usage: UsageHistory?
        var issue: UsageHistoryIssue?
    }

    private let settings: SettingsStore
    private var preferences: QuotaDisplayPreferences { settings.display }

    private let surface = GlassSurfaceView(cornerRadius: CompanionLayout.dashboardCornerRadius, kind: .content)
    private let root = NSStackView()
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let content = NSStackView()
    private let updatedLabel = DashboardView.label("", size: 11, color: .tertiaryLabelColor)
    private var scrollHeight: NSLayoutConstraint!
    private var rows: [RowID: ContentRow] = [:]
    private var outgoingViews: [NSView] = []
    private var contentGeneration = 0
    private(set) var contentTransitionIsActive = false

    fileprivate enum RowID: Hashable {
        case loading
        case separator(String)
        case service(String)
        case account(String)
        case windows(String, [String])
        case status(String)
        case hidden(String)
        case historyHeader
        case historyTotal
        case historyChart
        case historyGroup(String)
        case historyStatus
    }

    fileprivate struct ContentRow {
        let view: NSView
        let state: [String]
        let motionState: [String]
    }

    struct ContentTransition {
        fileprivate let rows: [RowID: ContentRow]
        fileprivate let frames: [RowID: CGRect]
        fileprivate let surface: CGRect
        fileprivate let viewport: CGRect
        fileprivate let chrome: [(NSView, CGRect)]
    }

    private struct WindowPresentation {
        let name: String
        let remaining: Double?
        let percentageStyle: QuotaPercentageStyle
        let status: String
        let description: String

        var state: [String] {
            [name, remaining.map { String($0) } ?? "unknown", percentageStyle.rawValue, status, description]
        }
        var motionState: [String] { [name, remaining.map { String($0) } ?? "unknown", percentageStyle.rawValue] }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        buildChrome()
    }

    // MARK: - Content transitions

    func prepareContentTransition() -> ContentTransition? {
        guard window != nil, !isHidden else { return nil }
        let viewport = screenFrame(scrollView.contentView)
        let frames = rows.mapValues { screenFrame($0.view) }
        return ContentTransition(
            rows: rows, frames: frames, surface: screenFrame(surface), viewport: viewport,
            chrome: root.arrangedSubviews.filter { $0 !== scrollView }.map { ($0, screenFrame($0)) })
    }

    func cancelContentTransition() {
        contentGeneration += 1
        contentTransitionIsActive = false
        for view in outgoingViews { view.removeFromSuperview() }
        outgoingViews = []
        let views: [NSView] = [surface] + rows.values.map(\.view) + root.arrangedSubviews.filter { $0 !== scrollView }
        for view in views {
            view.layer?.removeAnimation(forKey: "content.transform")
            view.layer?.removeAnimation(forKey: "content.opacity")
        }
    }

    func animateContent(from previous: ContentTransition, completion: @escaping () -> Void) {
        guard let window else {
            completion()
            return
        }
        contentGeneration += 1
        let generation = contentGeneration
        contentTransitionIsActive = true
        let reduced =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || ProcessInfo.processInfo.isLowPowerModeEnabled
        let duration: CFTimeInterval = reduced ? 0.12 : 0.24

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.contentGeneration == generation else { return }
            self.contentTransitionIsActive = false
            for view in self.outgoingViews { view.removeFromSuperview() }
            self.outgoingViews = []
            completion()
        }
        if !reduced { move(surface, from: previous.surface, duration: duration, scales: true) }
        for (view, frame) in previous.chrome where !reduced { move(view, from: frame, duration: duration) }
        for (id, row) in rows {
            if let frame = previous.frames[id], !reduced { move(row.view, from: frame, duration: duration) }
            let changed = previous.rows[id].map { $0.motionState != row.motionState } ?? true
            if changed, let rowLayer = row.view.layer {
                fade(rowLayer, appearing: true, duration: duration)
                if !reduced, previous.frames[id] == nil {
                    let dy: CGFloat = row.view.superview?.isFlipped == true ? 6 : -6
                    slide(rowLayer, from: CGPoint(x: 0, y: dy), to: .zero, duration: duration)
                }
            }
        }
        for (id, row) in previous.rows {
            let changed = rows[id].map { $0.motionState != row.motionState } ?? true
            guard changed, let frame = previous.frames[id], rows[id]?.view !== row.view else { continue }
            let visible = frame.intersection(previous.viewport)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            // A replaced row travels with its successor so the two never separate into a ghost; a
            // removed row lifts away.
            let offset =
                rows[id].map { offset(from: frame, to: screenFrame($0.view, model: true)) }
                ?? CGPoint(x: 0, y: isFlipped ? -6 : 6)
            // Retain the actual outgoing row. Native controls can overhang their alignment
            // rect, so clip the visible intersection instead of skipping the exit entirely.
            let overlay = OutgoingContentView(frame: convert(window.convertFromScreen(visible), from: nil))
            overlay.wantsLayer = true
            overlay.layer?.masksToBounds = true
            overlay.setAccessibilityElement(false)
            overlay.setAccessibilityChildren([])
            row.view.translatesAutoresizingMaskIntoConstraints = true
            row.view.frame = frame.offsetBy(dx: -visible.minX, dy: -visible.minY)
            overlay.addSubview(row.view)
            addSubview(overlay)
            overlay.layoutSubtreeIfNeeded()
            overlay.displayIfNeeded()
            outgoingViews.append(overlay)
            guard let outgoing = overlay.layer else { continue }
            outgoing.opacity = 0
            fade(outgoing, appearing: false, duration: duration)
            if !reduced {
                outgoing.transform = CATransform3DMakeTranslation(offset.x, offset.y, 0)
                slide(outgoing, from: .zero, to: offset, duration: duration)
            }
        }
        CATransaction.commit()
    }

    private func screenFrame(_ view: NSView, model: Bool = false) -> CGRect {
        guard let window, let parent = view.superview else { return .zero }
        let rect = model ? view.frame : view.layer?.presentation()?.frame ?? view.frame
        return window.convertToScreen(parent.convert(rect, to: nil))
    }

    /// How far this view's coordinates carry content from one screen rect's top-leading corner to another's.
    private func offset(from old: CGRect, to new: CGRect) -> CGPoint {
        // Screen coordinates rise upward; flipped views measure downward.
        CGPoint(x: new.minX - old.minX, y: isFlipped ? old.maxY - new.maxY : new.maxY - old.maxY)
    }

    /// Animates `view` from its old screen rect to its current frame.
    ///
    /// Rows only translate, top edge to top edge, so their text never stretches; the glass surface also scales.
    private func move(_ view: NSView, from previous: CGRect, duration: CFTimeInterval, scales: Bool = false) {
        guard let window, let parent = view.superview, let layer = view.layer else { return }
        let target = view.frame
        let old = parent.convert(window.convertFromScreen(previous), from: nil)
        guard target.width > 0, target.height > 0, old != target else { return }
        let transform: CATransform3D
        if scales {
            let anchor = layer.anchorPoint
            let dx = old.minX + old.width * anchor.x - target.minX - target.width * anchor.x
            let dy = old.minY + old.height * anchor.y - target.minY - target.height * anchor.y
            transform = CATransform3DScale(
                CATransform3DMakeTranslation(dx, dy, 0), old.width / target.width, old.height / target.height, 1)
        } else {
            let dy = parent.isFlipped ? old.minY - target.minY : old.maxY - target.maxY
            guard old.minX != target.minX || dy != 0 else { return }
            transform = CATransform3DMakeTranslation(old.minX - target.minX, dy, 0)
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: transform)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "content.transform")
    }

    /// Staggered so outgoing and incoming text are barely visible together; a plain crossfade shows
    /// both at half strength halfway through.
    private func fade(_ layer: CALayer, appearing: Bool, duration: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = appearing ? [0, 0, 1] : [1, 0, 0]
        animation.keyTimes = appearing ? [0, 0.4, 1] : [0, 0.6, 1]
        animation.duration = duration
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        layer.add(animation, forKey: "content.opacity")
    }

    private func slide(_ layer: CALayer, from: CGPoint, to: CGPoint, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(from.x, from.y, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(to.x, to.y, 0))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "content.transform")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    /// The size the dashboard wants, never taller than `maxHeight`; longer content scrolls.
    func preferredSize(maxHeight: CGFloat) -> CGSize {
        content.layoutSubtreeIfNeeded()
        let contentHeight = content.fittingSize.height
        scrollHeight.constant = 0
        let chrome = root.fittingSize.height + Self.padding * 2
        scrollHeight.constant = max(0, min(contentHeight, maxHeight - chrome))
        return CGSize(width: Self.width, height: chrome + scrollHeight.constant)
    }

    func update(
        _ services: [ServiceUsage], history: History, refreshing: Bool, refreshedAt: Date?, now: Date
    ) {
        refreshButton.isHidden = refreshing
        spinner.isHidden = !refreshing
        if refreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updatedLabel.stringValue =
            refreshedAt.map { String(localized: "Updated \(QuotaText.age($0, now: now))") } ?? ""

        let previous = rows
        rows = [:]
        for view in content.arrangedSubviews { view.removeFromSuperview() }
        if services.isEmpty {
            let text = String(localized: "Reading usage…")
            append(.loading, state: [text], previous: previous) {
                Self.label(text, size: 12, color: .secondaryLabelColor)
            }
        }
        // Split into consecutive provider runs to honor a global account order, including interleaving.
        var sections: [ServiceUsage] = []
        for account in preferences.orderedAccounts(in: services, visibleOnly: true) {
            if let last = sections.last, last.service == account.service {
                sections[sections.count - 1] = ServiceUsage(service: last.service, accounts: last.accounts + [account])
            } else {
                sections.append(ServiceUsage(service: account.service, accounts: [account]))
            }
        }
        for (index, service) in sections.enumerated() {
            let sectionID = service.accounts.first?.id ?? service.service.rawValue
            if index > 0 {
                append(.separator(sectionID), state: [], previous: previous) { Self.separator() }
            }
            let accountCount = services.first { $0.service == service.service }?.accounts.count ?? 0
            appendSection(
                service, sectionID: sectionID, multipleAccounts: accountCount > 1, now: now, previous: previous)
        }
        let hidden = preferences.orderedAccounts(in: services).filter { preferences.hiddenAccountIDs.contains($0.id) }
        if !hidden.isEmpty {
            append(.hidden("all"), state: hidden.flatMap { [$0.id, $0.email ?? ""] }, previous: previous) {
                hiddenAccountsMenu(hidden)
            }
        }
        // Local history does not wait for quota requests.
        append(.separator("history"), state: [], previous: previous) { Self.separator() }
        appendHistory(history, now: now, previous: previous)
    }

    // MARK: - Chrome

    private func buildChrome() {
        let title = Self.label(String(localized: "Tidemark"), size: 13, weight: .semibold)
        for (button, symbol, help, action) in [
            (refreshButton, "arrow.clockwise", String(localized: "Refresh usage"), #selector(refreshPressed)),
            (settingsButton, "gearshape", String(localized: "Settings"), #selector(settingsPressed))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = help
            button.target = self
            button.action = action
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        let header = NSStackView(views: [title, NSView(), updatedLabel, spinner, refreshButton, settingsButton])
        header.distribution = .fill
        header.alignment = .centerY
        header.setCustomSpacing(4, after: refreshButton)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight.isActive = true

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, Self.separator(), scrollView] as [NSView] {
            root.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        // Keep content outside the material so resizing the glass never scales or fades its text.
        let container = self
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            root.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2)
        ])
    }

    @objc private func refreshPressed() { onRefresh?() }
    @objc private func settingsPressed() { onOpenSettings?() }

    @objc private func hideAccount(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        settings.setVisible(false, accountID: id)
    }

    @objc private func showAccounts(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        var display = settings.display
        for id in ids { display.setVisible(true, accountID: id) }
        settings.display = display
    }

    @objc private func historyViewChosen(_ sender: NSSegmentedControl) {
        guard HistoryView.allCases.indices.contains(sender.selectedSegment) else { return }
        onHistoryViewChanged?(HistoryView.allCases[sender.selectedSegment])
    }

    @objc private func historyRangeChosen(_ sender: NSPopUpButton) {
        guard let range = sender.selectedItem?.representedObject as? String,
            let value = UsageHistoryRange(rawValue: range)
        else { return }
        onHistoryRangeChanged?(value)
    }

    // MARK: - Content

    private func append(
        _ id: RowID, state: [String], motionState: [String]? = nil,
        previous: [RowID: ContentRow], makeView: () -> NSView
    ) {
        let view = previous[id].flatMap { $0.state == state ? $0.view : nil } ?? makeView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        rows[id] = ContentRow(view: view, state: state, motionState: motionState ?? state)
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func appendSection(
        _ service: ServiceUsage, sectionID: String, multipleAccounts: Bool, now: Date, previous: [RowID: ContentRow]
    ) {
        let single = multipleAccounts ? nil : service.accounts.first
        let singleVisible = single
        let name = QuotaText.serviceName(service.service)
        let planName = QuotaText.plan(singleVisible?.plan) ?? ""
        append(
            .service(sectionID),
            state: [name, planName, singleVisible?.id ?? "", singleVisible?.email ?? ""], previous: previous
        ) {
            let title = Self.label(name, size: 13, weight: .semibold)
            let plan = Self.label(planName, size: 11, color: .secondaryLabelColor)
            let row = Self.row(title, singleVisible.map { accountControls($0, detail: plan) } ?? plan)
            if singleVisible != nil { row.alignment = .centerY }
            return row
        }
        if let single, !single.windows.isEmpty, let header = rows[.service(sectionID)]?.view {
            content.setCustomSpacing(6, after: header)
        }
        for account in service.accounts {
            if single == nil {
                append(
                    .account(account.id), state: [account.email ?? "", account.plan ?? "", String(account.isActive)],
                    previous: previous
                ) { accountHeader(account) }
                if !account.windows.isEmpty, let header = rows[.account(account.id)]?.view {
                    content.setCustomSpacing(6, after: header)
                }
            }
            for start in stride(from: 0, to: account.windows.count, by: 2) {
                let windows = account.windows[start..<min(start + 2, account.windows.count)]
                let presentations = windows.map { windowPresentation($0, now: now) }
                append(
                    .windows(account.id, windows.map(\.id)), state: presentations.flatMap(\.state),
                    motionState: presentations.flatMap(\.motionState), previous: previous
                ) {
                    let row = NSStackView(views: presentations.map(windowTile))
                    row.distribution = .fillEqually
                    row.alignment = .top
                    row.spacing = 8
                    if windows.count == 1 { row.addArrangedSubview(NSView()) }
                    return row
                }
            }
            if account.windows.isEmpty, account.issue == nil {
                let text = String(localized: "No reading yet")
                append(.status(account.id), state: [text], previous: previous) { Self.caption(text) }
            }
            if let issue = account.issue {
                let text = QuotaText.issue(issue, service: service.service)
                append(.status(account.id), state: [text], previous: previous) { Self.caption(text) }
            }
        }
    }

    // MARK: - History

    private func appendHistory(_ history: History, now: Date, previous: [RowID: ContentRow]) {
        let rangeName = HistoryText.range(history.range)
        // The header outlives selection changes: rebuilding it would crossfade the control being clicked.
        append(.historyHeader, state: [], previous: previous) {
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
                    state: bars.flatMap { [$0.label, $0.detail, String($0.value)] } + [axis.0, axis.1, rangeName],
                    motionState: [usage.range.rawValue], previous: previous
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
            append(.historyStatus, state: [status], previous: previous) { Self.caption(status) }
        }
    }

    /// The largest groups by tokens; past six, the smallest fold into one "Other" row.
    private static func groupRows(_ groups: [UsageGroup], view: HistoryView) -> [(
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

    private lazy var historyViewPicker: NSSegmentedControl = {
        let views = HistoryView.allCases
        let control = NSSegmentedControl()
        control.segmentCount = views.count
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.segmentStyle = .separated
        for (index, view) in views.enumerated() {
            let name = HistoryText.view(view)
            control.setImage(
                NSImage(systemSymbolName: HistoryText.symbol(view), accessibilityDescription: name)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)),
                forSegment: index)
            control.setToolTip(name, forSegment: index)
            control.setWidth(24, forSegment: index)
        }
        control.target = self
        control.action = #selector(historyViewChosen(_:))
        control.setAccessibilityLabel(String(localized: "Usage breakdown"))
        return control
    }()

    private lazy var historyRangePicker: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.controlSize = .small
        for range in UsageHistoryRange.allCases {
            button.addItem(withTitle: HistoryText.range(range))
            button.lastItem?.representedObject = range.rawValue
        }
        button.target = self
        button.action = #selector(historyRangeChosen(_:))
        button.setAccessibilityLabel(String(localized: "Usage range"))
        return button
    }()

    private func historyTotal(tokens: String, cost: String, note: String, description: String) -> NSView {
        let amount = Self.label(tokens, size: 20, weight: .semibold)
        amount.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        let estimate = Self.label(cost, size: 13, weight: .medium, color: .secondaryLabelColor)
        estimate.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let stack = Self.column(spacing: 2)
        stack.addArrangedSubview(Self.row(amount, estimate))
        stack.addArrangedSubview(Self.caption(note))
        Self.fill(stack)
        stack.toolTip = description
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(description)
        return stack
    }

    private func historyGroup(name: String, value: String, share: Double, description: String) -> NSView {
        let title = Self.label(name, size: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = name
        let figures = Self.label(value, size: 11, color: .secondaryLabelColor)
        figures.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let stack = Self.column(spacing: 4)
        stack.addArrangedSubview(Self.row(title, figures))
        stack.addArrangedSubview(ShareBarView(share: share))
        Self.fill(stack)
        stack.toolTip = description
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(description)
        return stack
    }

    private func accountHeader(_ account: AccountUsage) -> NSView {
        let name = Self.label(
            account.email ?? String(localized: "Signed-in account"), size: 11,
            weight: account.isActive ? .medium : .regular)
        name.toolTip = account.email
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = [QuotaText.plan(account.plan), account.isActive ? String(localized: "In use") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let trailing = Self.label(
            details, size: 10, color: account.isActive ? .controlAccentColor : .secondaryLabelColor)
        let row = Self.row(name, accountControls(account, detail: trailing))
        row.alignment = .centerY
        return row
    }

    private func accountControls(_ account: AccountUsage, detail: NSView) -> NSView {
        let description = String(localized: "Hide account")
        let button = NSButton(
            image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: description)!,
            target: self, action: #selector(hideAccount(_:)))
        button.image = button.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        button.identifier = NSUserInterfaceItemIdentifier(account.id)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = description
        let name = account.email ?? String(localized: "Signed-in account")
        button.setAccessibilityLabel(String(localized: "Hide account \(name)"))
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let controls = NSStackView(views: [detail, button])
        controls.alignment = .centerY
        controls.spacing = 6
        return controls
    }

    private func hiddenAccountsMenu(_ accounts: [AccountUsage]) -> NSView {
        let title = String(localized: "Show hidden accounts (\(accounts.count))")
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .controlTextColor
        button.setAccessibilityLabel(title)
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for account in accounts {
            let name =
                "\(QuotaText.shortServiceName(account.service)) · \(account.email ?? String(localized: "Signed-in account"))"
            let item = menu.addItem(
                withTitle: String(localized: "Show \(name)"), action: #selector(showAccounts(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [account.id]
        }
        if accounts.count > 1 {
            menu.addItem(.separator())
            let item = menu.addItem(
                withTitle: String(localized: "Show all accounts"), action: #selector(showAccounts(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = accounts.map(\.id)
        }
        button.menu = menu
        return button
    }

    private func windowPresentation(_ window: QuotaWindow, now: Date) -> WindowPresentation {
        let remaining = window.remainingPercent(at: now)
        let name = QuotaText.windowName(window)
        let status: String
        let detail: String
        switch window.freshness(at: now) {
        case .expired:
            status = String(localized: "Reset passed · \(QuotaText.age(window.observedAt, now: now))")
            detail = String(localized: "Reset passed, waiting for a new reading")
        case .stale:
            status =
                String(localized: "Stale · \(QuotaText.age(window.observedAt, now: now))")
            detail =
                window.usedPercent.map {
                    String(
                        localized:
                            "Last seen \(QuotaText.percentageDescription(100 - $0, style: preferences.percentageStyle))"
                    )
                }
                ?? String(localized: "Reading too old to trust")
        case .unknown:
            status = String(localized: "Unknown · \(QuotaText.age(window.observedAt, now: now))")
            detail =
                window.usedPercent == nil
                ? String(localized: "No percentage reported") : String(localized: "Reading time is in the future")
        case .current, .aging:
            status =
                window.resetsAt.map { QuotaText.resetTime($0, style: preferences.resetTimeStyle, now: now) }
                ?? ""
            detail = status
        }
        let source = "\(QuotaText.source(window.source)) · \(QuotaText.age(window.observedAt, now: now))"
        let value =
            remaining.map { QuotaText.percentageDescription($0, style: preferences.percentageStyle) }
            ?? String(localized: "Unknown")
        let description = [name, value, status, detail == status ? "" : detail, source]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return WindowPresentation(
            name: name, remaining: remaining, percentageStyle: preferences.percentageStyle, status: status,
            description: description)
    }

    private func windowTile(_ presentation: WindowPresentation) -> NSView {
        let name = Self.label(presentation.name, size: 11, weight: .medium)
        let ring = QuotaRingView(remaining: presentation.remaining, style: presentation.percentageStyle)
        let text = Self.column(spacing: 3)
        text.addArrangedSubview(name)
        let caption = CompanionLabel(wrappingLabelWithString: presentation.status)
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        text.addArrangedSubview(caption)
        for label in [name, caption] {
            label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        let stack = NSStackView(views: [ring, text])
        stack.alignment = .centerY
        stack.spacing = 8
        text.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -52).isActive = true
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.toolTip = presentation.description
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(presentation.description)
        return stack
    }

    // MARK: - Building blocks

    private static func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
    ) -> NSTextField {
        let field = CompanionLabel(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func caption(_ text: String) -> NSTextField {
        let field = label(text, size: 11, color: .secondaryLabelColor)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func row(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [leading, spacer, trailing])
        row.alignment = .firstBaseline
        row.spacing = 6
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private static func column(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// Stretches every arranged subview to the stack's width.
    private static func fill(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
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

/// Scroll content starts at the top.
fileprivate final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Exiting content remains drawable until its fade completes, without intercepting input.
fileprivate final class OutgoingContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
