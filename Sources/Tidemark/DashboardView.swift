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
    var onLiveChanged: ((Bool) -> Void)?
    var onVisibilityChanged: (() -> Void)?

    private static let hiddenAccountsKey = "hiddenDashboardAccountIDs"
    private let defaults: UserDefaults
    private var hiddenAccountIDs: Set<String>

    private let surface = GlassSurfaceView(cornerRadius: CompanionLayout.dashboardCornerRadius, kind: .content)
    private let root = NSStackView()
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let content = NSStackView()
    private let liveSwitch = NSSwitch()
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
        let status: String
        let description: String

        var state: [String] { [name, remaining.map { String($0) } ?? "unknown", status, description] }
        var motionState: [String] { [name, remaining.map { String($0) } ?? "unknown"] }
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, defaults: .standard)
    }

    init(frame frameRect: NSRect, defaults: UserDefaults) {
        self.defaults = defaults
        hiddenAccountIDs = Set(defaults.stringArray(forKey: Self.hiddenAccountsKey) ?? [])
        super.init(frame: frameRect)
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
        if !reduced { move(surface, from: previous.surface, duration: duration) }
        for (view, frame) in previous.chrome where !reduced { move(view, from: frame, duration: duration) }
        for (id, row) in rows {
            if let frame = previous.frames[id], !reduced { move(row.view, from: frame, duration: duration) }
            let changed = previous.rows[id].map { $0.motionState != row.motionState } ?? true
            if changed, let rowLayer = row.view.layer {
                fade(rowLayer, from: 0, to: 1, duration: duration)
                if !reduced, previous.frames[id] == nil {
                    let dy: CGFloat = row.view.superview?.isFlipped == true ? 6 : -6
                    slide(rowLayer, from: dy, to: 0, duration: duration)
                }
            }
        }
        for (id, row) in previous.rows {
            let changed = rows[id].map { $0.motionState != row.motionState } ?? true
            guard changed, let frame = previous.frames[id], rows[id]?.view !== row.view else { continue }
            let visible = frame.intersection(previous.viewport)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
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
            fade(outgoing, from: 1, to: 0, duration: duration)
            if !reduced {
                let dy: CGFloat = isFlipped ? -6 : 6
                outgoing.transform = CATransform3DMakeTranslation(0, dy, 0)
                slide(outgoing, from: 0, to: dy, duration: duration)
            }
        }
        CATransaction.commit()
    }

    private func screenFrame(_ view: NSView) -> CGRect {
        guard let window, let parent = view.superview else { return .zero }
        let rect = view.layer?.presentation()?.frame ?? view.frame
        return window.convertToScreen(parent.convert(rect, to: nil))
    }

    private func move(_ view: NSView, from previous: CGRect, duration: CFTimeInterval) {
        guard let window, let parent = view.superview, let layer = view.layer else { return }
        let target = view.frame
        let old = parent.convert(window.convertFromScreen(previous), from: nil)
        guard target.width > 0, target.height > 0, old != target else { return }
        let anchor = layer.anchorPoint
        let dx = old.minX + old.width * anchor.x - target.minX - target.width * anchor.x
        let dy = old.minY + old.height * anchor.y - target.minY - target.height * anchor.y
        let transform = CATransform3DScale(
            CATransform3DMakeTranslation(dx, dy, 0), old.width / target.width, old.height / target.height, 1)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: transform)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "content.transform")
    }

    private func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "content.opacity")
    }

    private func slide(_ layer: CALayer, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, from, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, to, 0))
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

    func update(_ services: [ServiceUsage], liveEnabled: Bool, refreshing: Bool, refreshedAt: Date?, now: Date) {
        refreshButton.isHidden = refreshing
        spinner.isHidden = !refreshing
        if refreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        liveSwitch.state = liveEnabled ? .on : .off
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
        for (index, service) in services.enumerated() {
            if index > 0 {
                append(.separator(service.service.rawValue), state: [], previous: previous) { Self.separator() }
            }
            appendSection(service, now: now, previous: previous)
        }
    }

    // MARK: - Chrome

    private func buildChrome() {
        let title = Self.label(String(localized: "Tidemark"), size: 13, weight: .semibold)
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "Refresh usage"))
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.toolTip = String(localized: "Refresh usage")
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        let header = NSStackView(views: [title, NSView(), spinner, refreshButton])
        header.distribution = .fill
        header.alignment = .centerY

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

        liveSwitch.controlSize = .mini
        liveSwitch.target = self
        liveSwitch.action = #selector(liveToggled)
        liveSwitch.setAccessibilityLabel(String(localized: "Live usage"))
        let liveLabel = Self.label(String(localized: "Live usage"), size: 11, color: .secondaryLabelColor)
        liveLabel.toolTip = String(
            localized: "Ask Anthropic and OpenAI with the agents' own sign-ins. Tidemark never renews them.")
        let footer = NSStackView(views: [liveSwitch, liveLabel, NSView(), updatedLabel])
        footer.alignment = .centerY
        footer.spacing = 6

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, Self.separator(), scrollView, Self.separator(), footer] as [NSView] {
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
    @objc private func liveToggled() { onLiveChanged?(liveSwitch.state == .on) }

    @objc private func hideAccount(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        hiddenAccountIDs.insert(id)
        saveVisibility()
    }

    @objc private func showAccounts(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        hiddenAccountIDs.subtract(ids)
        saveVisibility()
    }

    private func saveVisibility() {
        defaults.set(hiddenAccountIDs.sorted(), forKey: Self.hiddenAccountsKey)
        onVisibilityChanged?()
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

    private func appendSection(_ service: ServiceUsage, now: Date, previous: [RowID: ContentRow]) {
        let single = service.accounts.count == 1 ? service.accounts.first : nil
        let singleVisible = single.flatMap { hiddenAccountIDs.contains($0.id) ? nil : $0 }
        let name = QuotaText.serviceName(service.service)
        let planName = QuotaText.plan(singleVisible?.plan) ?? ""
        append(
            .service(service.service.rawValue),
            state: [name, planName, singleVisible?.id ?? "", singleVisible?.email ?? ""], previous: previous
        ) {
            let title = Self.label(name, size: 13, weight: .semibold)
            let plan = Self.label(planName, size: 11, color: .secondaryLabelColor)
            return Self.row(title, singleVisible.map { accountControls($0, detail: plan) } ?? plan)
        }
        for account in service.accounts where !hiddenAccountIDs.contains(account.id) {
            if single == nil {
                append(
                    .account(account.id), state: [account.email ?? "", account.plan ?? "", String(account.isActive)],
                    previous: previous
                ) { accountHeader(account) }
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
        let hidden = service.accounts.filter { hiddenAccountIDs.contains($0.id) }
        if !hidden.isEmpty {
            append(
                .hidden(service.service.rawValue), state: hidden.flatMap { [$0.id, $0.email ?? ""] }, previous: previous
            ) { hiddenAccountsMenu(hidden) }
        }
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
        return Self.row(name, accountControls(account, detail: trailing))
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
            let name = account.email ?? String(localized: "Signed-in account")
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
                window.usedPercent.map { String(localized: "Last seen \(QuotaText.percent(100 - $0)) left") }
                ?? String(localized: "Reading too old to trust")
        case .unknown:
            status = String(localized: "Unknown · \(QuotaText.age(window.observedAt, now: now))")
            detail =
                window.usedPercent == nil
                ? String(localized: "No percentage reported") : String(localized: "Reading time is in the future")
        case .current, .aging:
            status =
                window.resetsAt.map { String(localized: "Resets in \(QuotaText.duration($0.timeIntervalSince(now)))") }
                ?? ""
            detail = status
        }
        let source = "\(QuotaText.source(window.source)) · \(QuotaText.age(window.observedAt, now: now))"
        let value =
            remaining.map { String(localized: "\(QuotaText.percent($0)) left") }
            ?? String(localized: "Unknown")
        let description = [name, value, status, detail == status ? "" : detail, source]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return WindowPresentation(name: name, remaining: remaining, status: status, description: description)
    }

    private func windowTile(_ presentation: WindowPresentation) -> NSView {
        let name = Self.label(presentation.name, size: 11, weight: .medium)
        let ring = QuotaRingView(remaining: presentation.remaining)
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

/// Scroll content starts at the top.
fileprivate final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Exiting content remains drawable until its fade completes, without intercepting input.
fileprivate final class OutgoingContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
