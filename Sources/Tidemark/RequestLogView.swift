//
//  RequestLogView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkData
import TidemarkEngine

/// Persistent section. The outer dashboard owns vertical scrolling; this scroll view owns x only.
final class RequestLogView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    override var isFlipped: Bool { true }
    private let settings: SettingsStore
    private let reader = RequestLogReader(environment: .current)
    private let table = NSTableView()
    /// Owns the native header, so AppKit draws it, animates header drags, and scrolls rows under
    /// it with the system's scroll-edge material. It scrolls sideways for the user; its vertical
    /// offset only follows the dashboard so the header can stick (see `layoutBody`).
    private let horizontal = RequestLogHorizontalScrollView()
    private let clip = RequestLogLockedClipView()
    private let status = NSButton()
    private let columnsButton = NSButton()
    private var height: NSLayoutConstraint!
    private var entries: [RequestLogEntry] = []
    // Retain the paging boundary even when deduplication removes its row during refresh.
    private var bottomCursor: RequestLogCursor?
    private var started = false
    private var busy = false
    private var complete = false
    private var failed = false
    private var applying = false
    private var appliedColumns: RequestLogColumns?
    private var appliedShortClaude: Bool?
    private weak var dashboardScroll: NSScrollView?
    private var refreshPending = false
    private var task: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(frame: .zero)
        let title = DashboardView.label(String(localized: "Request Logs"), size: 13, weight: .semibold)
        let columnsHelp = String(localized: "Request log columns")
        columnsButton.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: columnsHelp)
        columnsButton.isBordered = false
        columnsButton.bezelStyle = .accessoryBarAction
        columnsButton.contentTintColor = .secondaryLabelColor
        columnsButton.toolTip = columnsHelp
        columnsButton.target = self
        columnsButton.action = #selector(showColumns)
        let heading = NSStackView(views: [title, NSView(), columnsButton])
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        let nativeHeader = RequestLogHeaderView()
        nativeHeader.makeMenu = { [weak self] in self?.columnMenu() }
        table.headerView = nativeHeader
        // No scrollers at all; trackpad and Shift-wheel still scroll sideways.
        horizontal.contentView = clip
        horizontal.drawsBackground = false
        horizontal.hasHorizontalScroller = false
        horizontal.hasVerticalScroller = false
        horizontal.verticalScrollElasticity = .none
        horizontal.automaticallyAdjustsContentInsets = false
        horizontal.documentView = table
        addSubview(horizontal)
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: Self.cellSpacing, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.allowsColumnReordering = true
        // Columns fit their content (`fitColumns`), so manual resizing would only be undone.
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .none
        status.isBordered = false
        status.font = .systemFont(ofSize: 11)
        status.contentTintColor = .secondaryLabelColor
        status.target = self
        status.action = #selector(retry)
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor),
            heading.heightAnchor.constraint(equalToConstant: 28),
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24)
        ])
        height = heightAnchor.constraint(equalToConstant: 120)
        height.isActive = true
        updateColumns()
        updateHeight()
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        if fittedWidth != bounds.width { fitColumns() }
        layoutBody()
    }

    private var headerHeight: CGFloat { table.headerView?.frame.height ?? 0 }
    private var rowsHeight: CGFloat { CGFloat(entries.count) * 24 }

    /// Sticks the header to the dashboard's viewport top while the rows pass under it.
    ///
    /// The inner scroll view starts at the header's pinned position and its rows, which start
    /// below the header (see `RequestLogHorizontalScrollView.tile`), are scrolled down by the same
    /// distance, so they stay where an unpinned table would put them. Rows above the header fall
    /// outside the scroll view and are clipped by it.
    private func layoutBody() {
        let top = Self.headingHeight
        let bottom = top + headerHeight + rowsHeight
        let pinned = min(max(top, viewportTop), bottom - headerHeight)
        // Resizing can constrain the content clip, so publish its new lock first. Finish
        // tiling before scrolling it: no later layout pass may use the previous clip height.
        clip.lockedY = pinned - top
        let frame = NSRect(x: 0, y: pinned, width: bounds.width, height: bottom - pinned)
        if horizontal.frame != frame {
            horizontal.frame = frame
            horizontal.tile()
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.lockedY))
        horizontal.reflectScrolledClipView(clip)
    }

    /// The dashboard viewport's top edge in this view's coordinates.
    private var viewportTop: CGFloat = -.greatestFiniteMagnitude

    func updateColumns() {
        guard appliedColumns != settings.requestLogColumns || appliedShortClaude != settings.shortClaudeModelNames
        else { return }
        applying = true
        appliedColumns = settings.requestLogColumns
        appliedShortClaude = settings.shortClaudeModelNames
        let x = horizontal.contentView.bounds.origin.x
        for column in table.tableColumns { table.removeTableColumn(column) }
        for id in ["time"] + settings.requestLogColumns.visible.map(\.rawValue) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = RequestLogColumn(rawValue: id).map(RequestLogText.title) ?? String(localized: "Time")
            column.headerCell = RequestLogHeaderCell(textCell: column.title)
            column.minWidth = 0
            table.addTableColumn(column)
        }
        fitColumns()
        table.headerView?.menu = columnMenu()
        table.reloadData()
        clip.scroll(to: NSPoint(x: x, y: clip.lockedY))
        horizontal.reflectScrolledClipView(clip)
        applying = false
    }

    /// Called after layout and outer clip changes. No reads occur during construction/update.
    func viewportChanged(_ outer: NSScrollView) {
        dashboardScroll = outer
        horizontal.verticalParent = outer
        let viewport = convert(outer.contentView.bounds, from: outer.contentView)
        let visible = window != nil && !isHiddenOrHasHiddenAncestor && viewport.intersects(bounds)
        if visible && !started { load() }
        if visible && started && !busy && !failed && !complete && viewport.maxY >= bounds.maxY - 24 * 10 { load() }
        viewportTop = viewport.minY
        layoutBody()
    }

    func refresh() {
        guard started else { return }
        if busy {
            refreshPending = true
            return
        }
        load(reconciling: bottomCursor != nil)
    }

    private func load(reconciling: Bool = false) {
        guard !busy else { return }
        started = true
        busy = true
        failed = false
        updateStatus()
        let bottom = bottomCursor
        task = Task { [weak self, reader] in
            let result = await Task.detached(priority: .utility) { () -> Result<RequestLogPage, Error> in
                Result {
                    if reconciling, let bottom {
                        return RequestLogPage(entries: try reader.loadedSpan(through: bottom), isComplete: false)
                    }
                    return try reader.page(after: bottom)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure:
                self.failed = true
            case .success(let page):
                let outer = self.dashboardScroll
                let point = outer?.contentView.bounds.origin
                // Sample at application time: the user may have scrolled while SQLite was busy.
                let viewportTop = outer.map {
                    self.table.convert($0.contentView.bounds, from: $0.contentView).minY
                }
                let oldIDs = self.entries.map(\.id)
                if reconciling {
                    // The snapshot is authoritative by request_id: replace changed rows and drop
                    // absent IDs, rather than keeping stale values from the previous snapshot.
                    self.entries = page.entries
                } else {
                    let oldIDs = Set(oldIDs)
                    self.entries.append(contentsOf: page.entries.filter { !oldIDs.contains($0.id) })
                    self.bottomCursor = page.entries.last?.cursor ?? self.bottomCursor
                    self.complete = page.isComplete
                }
                let adjustment =
                    reconciling
                    ? RowScrollPreservation.adjustment(
                        oldIDs: oldIDs, newIDs: self.entries.map(\.id),
                        viewportTop: Double(viewportTop ?? -1), rowHeight: 24) : 0
                self.table.reloadData()
                self.fitColumns()
                self.updateHeight()
                self.superview?.layoutSubtreeIfNeeded()
                if reconciling, let outer, let point {
                    outer.contentView.scroll(to: NSPoint(x: point.x, y: point.y + CGFloat(adjustment)))
                    outer.reflectScrolledClipView(outer.contentView)
                }
            }
            self.busy = false
            self.updateStatus()
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
            if let outer = self.dashboardScroll { self.viewportChanged(outer) }
        }
    }

    private static let cellSpacing: CGFloat = 12
    private static let headingHeight: CGFloat = 28
    private static let statusHeight: CGFloat = 28
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Heading, header, rows and status line, with room for a few rows before the first page.
    private func updateHeight() {
        let rows = max(rowsHeight, 3 * 24)
        height.constant = Self.headingHeight + headerHeight + rows + Self.statusHeight
    }
    /// The section width the columns were last fitted to.
    private var fittedWidth: CGFloat = -1

    /// Sizes every column to its widest loaded value or its title, then shares any width left
    /// in the section evenly, so a narrow table spans the panel and a wide one scrolls sideways.
    private func fitColumns() {
        let columns = table.tableColumns
        guard !columns.isEmpty else { return }
        applying = true
        defer { applying = false }
        let fitted = columns.map { column -> CGFloat in
            let kind = RequestLogColumn(rawValue: column.identifier.rawValue)
            var widest = Self.width(column.title, font: Self.headerFont)
            for entry in entries {
                let text = kind.map { value($0, entry) } ?? RequestLogText.time(entry)
                widest = max(widest, Self.width(text, font: Self.valueFont))
            }
            // A column's width excludes the intercell spacing the table adds around its cells.
            return ceil(widest) + 1
        }
        fittedWidth = bounds.width
        // Whole points only, with the remainder on the last column, so a fitting table is exactly
        // as wide as the section and never scrolls by a fraction.
        let spacing = Self.cellSpacing * CGFloat(columns.count)
        let spare = max(0, floor(bounds.width) - spacing - fitted.reduce(0, +))
        let share = floor(spare / CGFloat(columns.count))
        for (index, (column, width)) in zip(columns, fitted).enumerated() {
            let remainder = index == columns.count - 1 ? spare - share * CGFloat(columns.count) : 0
            column.width = width + share + remainder
        }
        table.tile()
        table.frame.size.width = table.rect(ofColumn: columns.count - 1).maxX
        resizeBody()
    }

    private func value(_ column: RequestLogColumn, _ entry: RequestLogEntry) -> String {
        RequestLogText.value(column, entry, shortClaude: settings.shortClaudeModelNames)
    }

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func resizeBody() {
        table.frame.size.height = rowsHeight
        layoutBody()
    }

    private func updateStatus() {
        status.isEnabled = failed
        status.title =
            failed
            ? String(localized: "Couldn’t read CC Switch logs. Retry")
            : busy
                ? String(localized: "Loading request logs…")
                : complete
                    ? String(localized: "End of request logs")
                    : started
                        ? String(localized: "Scroll for more") : String(localized: "Scroll here to load request logs")
    }
    @objc private func retry() { refresh() }
    private func columnMenu() -> NSMenu {
        let menu = NSMenu()
        for column in settings.requestLogColumns.order {
            let item = menu.addItem(
                withTitle: RequestLogText.title(column), action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = settings.requestLogColumns.hidden.contains(column) ? .off : .on
        }
        menu.addItem(.separator())
        let reset = menu.addItem(
            withTitle: String(localized: "Reset to Default"), action: #selector(resetColumns), keyEquivalent: "")
        reset.target = self
        return menu
    }
    @objc private func showColumns() {
        columnMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: columnsButton.bounds.maxY), in: columnsButton)
    }
    @objc private func resetColumns() {
        settings.requestLogColumns.reset()
        updateColumns()
    }
    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let column = RequestLogColumn(rawValue: id) else { return }
        settings.requestLogColumns.setVisible(settings.requestLogColumns.hidden.contains(column), column)
        updateColumns()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool
    { columnIndex != 0 && newColumnIndex != 0 }
    func tableViewColumnDidMove(_ notification: Notification) {
        guard !applying, let info = notification.userInfo,
            let index = info["NSNewColumn"] as? Int, index > 0,
            let column = RequestLogColumn(rawValue: table.tableColumns[index].identifier.rawValue)
        else { return }
        var preferences = settings.requestLogColumns
        preferences.move(column, toVisibleIndex: index - 1)
        appliedColumns = preferences
        settings.requestLogColumns = preferences
        table.headerView?.menu = columnMenu()
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = RequestLogRowView()
        view.striped = row % 2 == 1
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let entry = entries[row]
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.identifier = tableColumn.identifier
        cell.textField?.font = Self.valueFont
        cell.textField?.lineBreakMode = .byClipping
        cell.textField?.stringValue =
            RequestLogColumn(rawValue: tableColumn.identifier.rawValue).map { value($0, entry) }
            ?? RequestLogText.time(entry)
        // The full date for times, the raw ID behind a display name, else the value itself.
        cell.toolTip =
            switch tableColumn.identifier.rawValue {
            case "time": RequestLogText.time(entry, full: true)
            case "model": entry.model.isEmpty ? nil : entry.model
            default: cell.textField?.stringValue
            }
        return cell
    }
}

fileprivate final class RequestLogHorizontalScrollView: NSScrollView {
    weak var verticalParent: NSScrollView?
    private var gestureIsVertical: Bool?
    private var pendingScrollStart: NSEvent?

    /// Rows start below the header instead of scrolling under it, so no row text shows behind
    /// the titles and the system scroll-edge effect has nothing to cover.
    override func tile() {
        super.tile()
        guard let header = (documentView as? NSTableView)?.headerView?.superview else { return }
        let height = header.frame.height
        contentView.frame = NSRect(
            x: 0, y: isFlipped ? height : 0, width: bounds.width, height: max(0, bounds.height - height))
    }

    override func scrollWheel(with event: NSEvent) {
        let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            routeScrollWheel(event, vertically: vertical)
            return
        }

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            gestureIsVertical = nil
            pendingScrollStart = nil
        }
        if gestureIsVertical == nil {
            // A trackpad can begin with no movement. Wait for an axis, then deliver that
            // start to the same scroll view as the movement and eventual momentum events.
            if event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0 {
                if event.phase.contains(.began) { pendingScrollStart = event }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled)
                    || event.momentumPhase.contains(.ended)
                {
                    pendingScrollStart = nil
                }
                return
            }
            gestureIsVertical = vertical
            if let start = pendingScrollStart {
                pendingScrollStart = nil
                routeScrollWheel(start, vertically: vertical)
            }
        }
        routeScrollWheel(event, vertically: gestureIsVertical == true)
        // Keep the recipient after finger lift: momentum begins in a separate event.
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            gestureIsVertical = nil
            pendingScrollStart = nil
        }
    }

    private func routeScrollWheel(_ event: NSEvent, vertically: Bool) {
        if vertically {
            verticalParent?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

fileprivate final class RequestLogHeaderView: NSTableHeaderView {
    var makeMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
}

/// A smaller title aligned with the cell text below. Only the interior is custom: when a cell
/// skips the system header drawing, AppKit renders the header region as an opaque black strip.
fileprivate final class RequestLogHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: RequestLogView.headerFont, .foregroundColor: NSColor.secondaryLabelColor
        ]
        let title = stringValue as NSString
        let size = title.size(withAttributes: attributes)
        // View-based cells sit half the intercell spacing inside the column.
        let spacing = (controlView as? NSTableHeaderView)?.tableView?.intercellSpacing.width ?? 0
        let x = cellFrame.minX + spacing / 2
        title.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Faint stripes that read on glass in both appearances, instead of the opaque alternating colors.
fileprivate final class RequestLogRowView: NSTableRowView {
    var striped = false
    override func drawBackground(in dirtyRect: NSRect) {
        guard striped else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

/// Holds the vertical offset that keeps the rows in place while the header sticks; the user's
/// sideways scrolling cannot move it.
fileprivate final class RequestLogLockedClipView: NSClipView {
    var lockedY: CGFloat = 0
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.y = lockedY
        return rect
    }
}
