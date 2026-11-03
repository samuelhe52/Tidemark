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
    /// The heat map span being viewed; outlives the heat map, which is rebuilt as today's usage grows.
    var heatmapPage = 0

    /// How the history section breaks down the range.
    enum HistoryView: String, CaseIterable {
        case chart, harness, model
    }

    enum HistoryChartStyle: String, CaseIterable {
        case heatmap, bars
    }

    /// CC Switch history for the dashboard: the chosen range and the newest reading for it.
    struct History {
        var range: UsageHistoryRange
        var view: HistoryView
        /// Nil until the first read for `range` finishes.
        var usage: UsageHistory?
        var issue: UsageHistoryIssue?
    }

    private lazy var requestLogs = RequestLogView(settings: settings)
    private var lastLogsRefresh: Date?
    private var rebuildingContent = false
    let settings: SettingsStore
    private var preferences: QuotaDisplayPreferences { settings.display }

    // Internal rather than private: the extensions in DashboardView+*.swift share these.
    let surface = GlassSurfaceView(cornerRadius: CompanionLayout.dashboardCornerRadius, kind: .content)
    let root = NSStackView()
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let spinner = NSProgressIndicator()
    let scrollView = NSScrollView()
    private let content = NSStackView()
    private let updatedLabel = DashboardView.label("", size: 11, color: .tertiaryLabelColor)
    private var scrollHeight: NSLayoutConstraint!
    var rows: [RowID: ContentRow] = [:]
    var outgoingViews: [NSView] = []
    var contentGeneration = 0
    var contentTransitionIsActive = false

    enum RowID: Hashable {
        case loading
        case separator(String)
        case service(String)
        case account(String)
        case windows(String, [String])
        case status(String)
        case hidden(String)
        case requestLogs
        case historyHeader
        case historyTotal
        case historyChart
        case historyGroup(String)
        case historyStatus
    }

    /// A row and the inputs it was built from: an equal `state` reuses the view, and a changed
    /// `motionState` fades the row during a content transition.
    struct ContentRow {
        let view: NSView
        let state: AnyHashable
        let motionState: AnyHashable
    }

    /// Everything a window tile shows; the tile is rebuilt only when this changes.
    private struct WindowPresentation: Hashable {
        let name: String
        let remaining: Double?
        let percentageStyle: QuotaPercentageStyle
        let status: String
        let description: String

        /// What changes the tile visibly enough to fade it: not the countdown or the description.
        struct Motion: Hashable {
            let name: String
            let remaining: Double?
            let percentageStyle: QuotaPercentageStyle
        }

        var motion: Motion { Motion(name: name, remaining: remaining, percentageStyle: percentageStyle) }
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        surface.frame = bounds
        logViewportChanged()
    }

    /// The size the dashboard wants, never taller than `maxHeight`; longer content scrolls.
    func preferredSize(maxHeight: CGFloat) -> CGSize {
        content.layoutSubtreeIfNeeded()
        // The panel ends where the last view above the logs ends, measured from the laid-out
        // frames in the flipped document; the logs are reached by scrolling.
        let contentHeight: CGFloat
        if let separator = rows[.separator("requestLogs")]?.view,
            let index = content.arrangedSubviews.firstIndex(of: separator), index > 0,
            let document = content.superview
        {
            let above = content.arrangedSubviews[index - 1]
            contentHeight = max(0, document.convert(above.bounds, from: above).maxY)
        } else {
            contentHeight = content.fittingSize.height
        }
        scrollHeight.constant = 0
        let chrome = root.fittingSize.height + Self.padding * 2
        scrollHeight.constant = max(0, min(contentHeight, maxHeight - chrome))
        return CGSize(width: Self.width, height: chrome + scrollHeight.constant)
    }

    func update(
        _ services: [ServiceUsage], history: History, refreshing: Bool, refreshedAt: Date?, now: Date
    ) {
        rebuildingContent = true
        defer {
            rebuildingContent = false
            logViewportChanged()
        }
        refreshButton.isHidden = refreshing
        spinner.isHidden = !refreshing
        if refreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updatedLabel.stringValue =
            refreshedAt.map { String(localized: "Updated \(QuotaText.age($0, now: now))") } ?? ""

        let scrollOrigin = scrollView.contentView.bounds.origin
        let previous = rows
        rows = [:]
        for view in content.arrangedSubviews { view.removeFromSuperview() }
        if services.isEmpty {
            let text = String(localized: "Reading usage…")
            append(.loading, state: text, previous: previous) {
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
                append(.separator(sectionID), state: sectionID, previous: previous) { Self.separator() }
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
        append(.separator("history"), state: "history", previous: previous) { Self.separator() }
        appendHistory(history, now: now, previous: previous)
        append(.separator("requestLogs"), state: "requestLogs", previous: previous) { Self.separator() }
        append(.requestLogs, state: "persistent", previous: previous) { requestLogs }
        requestLogs.updateColumns()
        content.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: scrollOrigin)
        if refreshedAt != lastLogsRefresh {
            lastLogsRefresh = refreshedAt
            requestLogs.refresh()
        }
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
        // No scroller, even when a mouse makes the system show legacy scrollers; wheel and
        // trackpad scrolling still work.
        scrollView.hasVerticalScroller = false
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(logViewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
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

    @objc private func logViewportChanged() {
        // A queued callback leaves a drawable frame with the new outer offset and the old
        // header position. Only defer during our synchronous stack rebuild, never while scrolling.
        guard !rebuildingContent else { return }
        requestLogs.viewportChanged(scrollView)
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

    // MARK: - Content

    func append(
        _ id: RowID, state: AnyHashable, motionState: AnyHashable? = nil,
        spacingAfter: CGFloat? = nil,
        previous: [RowID: ContentRow], makeView: () -> NSView
    ) {
        let view = previous[id].flatMap { $0.state == state ? $0.view : nil } ?? makeView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        rows[id] = ContentRow(view: view, state: state, motionState: motionState ?? state)
        content.addArrangedSubview(view)
        content.setCustomSpacing(spacingAfter ?? content.spacing, after: view)
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
            state: [name, planName, singleVisible?.id ?? "", singleVisible?.email ?? ""],
            spacingAfter: multipleAccounts || single?.windows.isEmpty == false ? 6 : nil,
            previous: previous
        ) {
            let title = Self.label(name, size: 13, weight: .semibold)
            let plan = Self.label(planName, size: 11, color: .secondaryLabelColor)
            let row = Self.row(title, singleVisible.map { accountControls($0, detail: plan) } ?? plan)
            if singleVisible != nil { row.alignment = .centerY }
            return row
        }
        for account in service.accounts {
            if single == nil {
                append(
                    .account(account.id), state: [account.email ?? "", account.plan ?? "", String(account.isActive)],
                    spacingAfter: account.windows.isEmpty ? nil : 6,
                    previous: previous
                ) { accountHeader(account) }
            }
            for start in stride(from: 0, to: account.windows.count, by: 2) {
                let windows = account.windows[start..<min(start + 2, account.windows.count)]
                let presentations = windows.map { windowPresentation($0, now: now) }
                append(
                    .windows(account.id, windows.map(\.id)), state: presentations,
                    motionState: presentations.map(\.motion), previous: previous
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
                append(.status(account.id), state: text, previous: previous) { Self.caption(text) }
            }
            if let issue = account.issue {
                let text = QuotaText.issue(issue, service: service.service)
                append(.status(account.id), state: text, previous: previous) { Self.caption(text) }
            }
        }
    }

    lazy var historyViewPicker: NSSegmentedControl = {
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

    lazy var historyRangePicker: NSPopUpButton = {
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

    private func accountHeader(_ account: AccountUsage) -> NSView {
        let name = Self.label(QuotaText.accountName(account), size: 11, weight: account.isActive ? .medium : .regular)
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
        let name = QuotaText.accountName(account)
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
                "\(QuotaText.shortServiceName(account.service)) · \(QuotaText.accountName(account))"
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
        Self.describe(stack, presentation.description)
        return stack
    }
}


/// Scroll content starts at the top.
fileprivate final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    /// Pinning changes descendant geometry in the synchronous bounds-change handler.
    ///
    /// Do not let responsive scrolling present cached document content ahead of that handler.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}
