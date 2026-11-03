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
    static let width: CGFloat = 300
    private static let padding: CGFloat = 14

    var onRefresh: (() -> Void)?
    var onLiveChanged: ((Bool) -> Void)?

    private let surface = GlassSurfaceView(cornerRadius: CompanionLayout.dashboardCornerRadius, kind: .content)
    private let root = NSStackView()
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let content = NSStackView()
    private let liveSwitch = NSSwitch()
    private let updatedLabel = DashboardView.label("", size: 11, color: .tertiaryLabelColor)
    private var scrollHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        buildChrome()
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

        for view in content.arrangedSubviews { view.removeFromSuperview() }
        if services.isEmpty {
            content.addArrangedSubview(
                Self.label(String(localized: "Reading usage…"), size: 12, color: .secondaryLabelColor))
        }
        for (index, service) in services.enumerated() {
            if index > 0 { content.addArrangedSubview(Self.separator()) }
            content.addArrangedSubview(section(service, now: now))
        }
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
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
        root.setCustomSpacing(12, after: header)
        let container = surface.contentView
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            root.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2)
        ])
    }

    @objc private func refreshPressed() { onRefresh?() }
    @objc private func liveToggled() { onLiveChanged?(liveSwitch.state == .on) }

    // MARK: - Content

    private func section(_ service: ServiceUsage, now: Date) -> NSView {
        let stack = Self.column(spacing: 10)
        let single = service.accounts.count == 1 ? service.accounts.first : nil
        let title = Self.label(QuotaText.serviceName(service.service), size: 13, weight: .semibold)
        let plan = Self.label(
            QuotaText.plan(single?.plan) ?? "", size: 11, color: .secondaryLabelColor)
        stack.addArrangedSubview(Self.row(title, plan))
        for account in service.accounts {
            let block = Self.column(spacing: 8)
            if single == nil { block.addArrangedSubview(accountHeader(account)) }
            for window in account.windows { block.addArrangedSubview(windowRow(window, now: now)) }
            if account.windows.isEmpty, account.issue == nil {
                block.addArrangedSubview(Self.caption(String(localized: "No reading yet")))
            }
            if let issue = account.issue {
                block.addArrangedSubview(Self.caption(QuotaText.issue(issue, service: service.service)))
            }
            Self.fill(block)
            stack.addArrangedSubview(block)
        }
        Self.fill(stack)
        return stack
    }

    private func accountHeader(_ account: AccountUsage) -> NSView {
        let name = Self.label(
            account.email ?? String(localized: "Signed-in account"), size: 12, weight: .medium,
            color: account.isActive ? .labelColor : .secondaryLabelColor)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = [QuotaText.plan(account.plan), account.isActive ? String(localized: "In use") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let trailing = Self.label(
            details, size: 11, color: account.isActive ? .controlAccentColor : .tertiaryLabelColor)
        return Self.row(name, trailing)
    }

    private func windowRow(_ window: QuotaWindow, now: Date) -> NSView {
        let remaining = window.remainingPercent(at: now)
        let name = Self.label(QuotaText.windowName(window), size: 13)
        let value = Self.label(
            remaining.map { String(localized: "\(QuotaText.percent($0)) left") } ?? "—", size: 13,
            weight: .medium, color: remaining == nil ? .secondaryLabelColor : .labelColor)
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let stack = Self.column(spacing: 4)
        stack.addArrangedSubview(Self.row(name, value))
        if let remaining {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.controlSize = .small
            bar.minValue = 0
            bar.maxValue = 100
            bar.doubleValue = remaining
            stack.addArrangedSubview(bar)
        }
        let status: String
        switch window.freshness(at: now) {
        case .expired: status = String(localized: "Reset passed, waiting for a new reading")
        case .stale:
            status =
                window.usedPercent.map { String(localized: "Last seen \(QuotaText.percent(100 - $0)) left") }
                ?? String(localized: "Reading too old to trust")
        case .unknown:
            status =
                window.usedPercent == nil
                ? String(localized: "No percentage reported") : String(localized: "Reading time is in the future")
        case .current, .aging:
            status =
                window.resetsAt.map { String(localized: "Resets in \(QuotaText.duration($0.timeIntervalSince(now)))") }
                ?? ""
        }
        let source = "\(QuotaText.source(window.source)) · \(QuotaText.age(window.observedAt, now: now))"
        stack.addArrangedSubview(
            Self.row(Self.caption(status), Self.label(source, size: 11, color: .tertiaryLabelColor)))
        Self.fill(stack)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel([name.stringValue, value.stringValue, status, source].joined(separator: ", "))
        return stack
    }

    // MARK: - Building blocks

    private static func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
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
