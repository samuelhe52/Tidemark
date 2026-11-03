//
//  CompanionController.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import TidemarkData
import TidemarkEngine

@MainActor
final class CompanionController: NSObject {
    private(set) var state = CompanionState()
    var liveEnabled: Bool { settings.liveUsageEnabled }
    private let settings: SettingsStore
    /// Opens the settings window; set by the app delegate.
    var openSettings: (() -> Void)?
    private var appliedLiveEnabled: Bool
    private var layout: CompanionLayout?
    private let panel = CompanionPanel()
    private let stage: CompanionStageView
    private let usageService: UsageService
    private var usage: [ServiceUsage] = []
    private var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private let historyReader = UsageHistoryReader(environment: .current)
    private var history: DashboardView.History
    private var historyTask: Task<Void, Never>?
    private var historyAgain = false
    private var placement: DockPlacement?
    private var anchor: DockAnchor?
    private var deadlineTimer: Timer?
    private var pointerTimer: Timer?
    private var clockTimer: Timer?
    private var refreshTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var escapeMonitor: Any?
    private var sleeping = false
    private var locked = false
    private var dragPoint: CGPoint?
    private var lastRefresh = Date.distantPast
    /// True while the panel is shrunk to the hover strip; it grows only for visible phases.
    private var panelShowsStrip = true
    /// Identifies the newest presentation, so a superseded retract never shrinks the panel.
    private var presentationGeneration = 0
    private var layoutGeneration = 0

    private static let historyRangeKey = "usageHistoryRange"
    private static let historyViewKey = "usageHistoryView"

    init(settings: SettingsStore) {
        self.settings = settings
        appliedLiveEnabled = settings.liveUsageEnabled
        state = CompanionState(behavior: settings.behavior)
        stage = CompanionStageView(settings: settings)
        usageService = UsageService(liveEnabled: settings.liveUsageEnabled)
        let range = UserDefaults.standard.string(forKey: Self.historyRangeKey).flatMap(UsageHistoryRange.init)
        let view = UserDefaults.standard.string(forKey: Self.historyViewKey).flatMap(DashboardView.HistoryView.init)
        history = DashboardView.History(range: range ?? .today, view: view ?? .chart)
        super.init()
        settings.onChange = { [weak self] in self?.settingsChanged() }
    }

    func start() {
        if let data = UserDefaults.standard.data(forKey: "dockPlacement") {
            placement = try? JSONDecoder().decode(DockPlacement.self, from: data)
        }
        stage.hiddenStripActive = { [weak self] in self?.state.phase == .hidden }
        stage.pointerChanged = { [weak self] event in
            self?.reconcilePointer(at: event.window?.convertPoint(toScreen: event.locationInWindow))
        }
        stage.stripClicked = { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            guard let self, self.layout?.strip.contains(point) == true else { return false }
            self.send(.companionClicked)
            return true
        }
        stage.orbHandle.clicked = { [weak self] in self?.send(.companionClicked) }
        stage.orbHandle.pinToggled = { [weak self] in self?.send(.pinToggled) }
        stage.orbHandle.dragChanged = { [weak self] in self?.dragChanged(to: $0) }
        stage.orbHandle.dragEnded = { [weak self] in self?.dragEnded() }
        stage.dashboard.onRefresh = { [weak self] in self?.refresh(userInitiated: true) }
        stage.dashboard.onOpenSettings = { [weak self] in self?.openSettings?() }
        stage.dashboard.onHistoryRangeChanged = { [weak self] in self?.setHistoryRange($0) }
        stage.dashboard.onHistoryViewChanged = { [weak self] in self?.setHistoryView($0) }
        panel.contentView = stage
        renderUsage()
        updatePlacement()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            Task { @MainActor in self?.reconcilePointer() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.state.phase == .pinned,
                NSApp.keyWindow == nil || NSApp.keyWindow === self.panel
            {
                self.send(.escape)
            } else if event.type != .keyDown {
                self.reconcilePointer()
            }
            return event
        }
        // macOS delivers global key events only when input-monitoring access already permits it.
        // Registration does not request that permission; clicking or Option-clicking the orb always
        // provides an unpin path.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.send(.escape) }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil)
        // Passive files every minute; the usage service rate-limits live requests on its own.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.sleeping, !self.locked else { return }
                self.refresh(userInitiated: false)
            }
        }
        refresh(userInitiated: false)
        reconcilePointer()
    }

    func stop() {
        for timer in [deadlineTimer, pointerTimer, clockTimer, refreshTimer] { timer?.invalidate() }
        for monitor in [globalMonitor, localMonitor, escapeMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        escapeMonitor = nil
        refreshTask?.cancel()
        historyTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        panel.orderOut(nil)
    }

    func send(_ event: CompanionEvent) {
        guard !sleeping, !locked else { return }
        let previous = state.phase
        state.send(event, now: ProcessInfo.processInfo.systemUptime)
        if previous == .hidden, state.phase != .hidden, Date().timeIntervalSince(lastRefresh) >= 5 {
            refresh(userInitiated: false)
        }
        deadlineTimer?.invalidate()
        if let deadline = state.nextDeadline {
            deadlineTimer = Timer.scheduledTimer(
                withTimeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.send(.timePassed)
                    self?.reconcilePointer()
                }
            }
        }
        if state.phase == .hidden {
            pointerTimer?.invalidate()
            pointerTimer = nil
            clockTimer?.invalidate()
            clockTimer = nil
        } else {
            if pointerTimer == nil {
                pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.reconcilePointer() }
                }
            }
            if clockTimer == nil {
                // Countdowns and ages have minute resolution.
                clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.renderUsage() }
                }
            }
        }
        if previous != state.phase { present(animated: true) }
        updateHitTesting()
    }

    func showCompanion() {
        if anchor == nil { updatePlacement() }
        if state.phase != .pinned { send(.pinToggled) }
        panel.orderFrontRegardless()
        reconcilePointer()
    }

    func resetPlacement() {
        guard let display = displays().first else { return }
        placement = DockPlacement(displayID: display.id)
        send(.reset)
        updatePlacement()
        persistPlacement()
    }

    func setLiveEnabled(_ enabled: Bool) {
        guard enabled != liveEnabled else { return }
        settings.liveUsageEnabled = enabled
    }

    private func settingsChanged() {
        let previous = state.phase
        state.configure(settings.behavior, now: ProcessInfo.processInfo.systemUptime)
        if previous != state.phase { present(animated: true) }
        // Reschedule timers using the new settings even when the phase stays the same.
        send(.timePassed)
        renderUsage(animated: true)
        if appliedLiveEnabled != liveEnabled {
            appliedLiveEnabled = liveEnabled
            let enabled = liveEnabled
            Task { [usageService] in
                await usageService.setLiveEnabled(enabled)
                self.refresh(userInitiated: true)
            }
        }
    }

    func toggleCompanion() {
        if state.phase == .hidden { showCompanion() } else { send(.dismiss) }
    }

    func refresh(userInitiated: Bool) {
        refreshHistory()
        guard refreshTask == nil else {
            refreshAgain = refreshAgain || userInitiated
            return
        }
        refreshTask = Task { [weak self, usageService] in
            let result = await usageService.refresh(userInitiated: userInitiated)
            guard let self else { return }
            self.usage = result
            self.settings.updateAccounts(result)
            self.refreshedAt = .now
            self.lastRefresh = .now
            self.refreshTask = nil
            self.renderUsage(animated: true)
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh(userInitiated: true)
            }
        }
        renderUsage()
    }

    // MARK: - History

    private func setHistoryRange(_ range: UsageHistoryRange) {
        guard range != history.range else { return }
        UserDefaults.standard.set(range.rawValue, forKey: Self.historyRangeKey)
        history.range = range
        history.issue = nil
        // The picker already shows the new range; the rows change once its figures arrive.
        refreshHistory()
    }

    private func setHistoryView(_ view: DashboardView.HistoryView) {
        guard view != history.view else { return }
        UserDefaults.standard.set(view.rawValue, forKey: Self.historyViewKey)
        history.view = view
        renderUsage(animated: true)
    }

    /// Reads CC Switch's database off the main actor; concurrent requests coalesce into one rerun.
    private func refreshHistory() {
        guard historyTask == nil else {
            historyAgain = true
            return
        }
        let range = history.range
        historyTask = Task { [weak self, historyReader] in
            let result = await Task.detached(priority: .utility) { historyReader.read(range, now: Date()) }.value
            guard let self, !Task.isCancelled else { return }
            self.historyTask = nil
            if range == self.history.range {
                switch result {
                case .success(let usage):
                    self.history.usage = usage
                    self.history.issue = nil
                case .failure(let issue):
                    // Keep the last good figures for this range beside the issue.
                    self.history.issue = issue
                }
                self.renderUsage(animated: true)
            }
            if self.historyAgain {
                self.historyAgain = false
                self.refreshHistory()
            }
        }
    }

    // MARK: - Presentation

    private func present(animated: Bool) {
        guard let layout else { return }
        layoutGeneration += 1
        presentationGeneration += 1
        let generation = presentationGeneration
        if state.phase != .hidden, panelShowsStrip {
            // Grow first: the docked orb keeps its screen position, so the change is invisible.
            panelShowsStrip = false
            panel.setFrame(layout.frame, display: false)
            stage.place(layout, in: layout.frame)
        }
        stage.orbHandle.pinned = state.phase == .pinned
        stage.show(state.phase, layout: layout, animated: animated) { [weak self] in
            guard let self, generation == self.presentationGeneration, self.state.phase == .hidden else { return }
            self.collapseToStrip()
        }
    }

    /// Shrinks the panel to the hover strip once the retract has finished.
    private func collapseToStrip() {
        guard let layout, !panelShowsStrip else { return }
        panelShowsStrip = true
        panel.setFrame(layout.strip, display: true)
        stage.place(layout, in: layout.strip)
        updateHitTesting()
    }

    private func renderUsage(animated: Bool = false) {
        let canAnimate = !panelShowsStrip && (state.phase == .expanded || state.phase == .pinned)
        let transition =
            canAnimate && (animated || stage.dashboard.contentTransitionIsActive)
            ? stage.dashboard.prepareContentTransition() : nil
        layoutGeneration += 1
        stage.dashboard.cancelContentTransition()
        let now = Date()
        stage.summary.update(text: QuotaText.summary(usage, preferences: settings.display, now: now))
        stage.dashboard.update(
            usage, history: history, refreshing: refreshTask != nil, refreshedAt: refreshedAt,
            now: now)
        applyLayout(transition: transition)
    }

    // MARK: - Dragging

    private func dragChanged(to point: CGPoint) {
        if state.phase != .dragging { send(.dragBegan) }
        dragPoint = point
        if let nearest = DockGeometry.nearest(to: point, displays: displays()) {
            anchor = nearest
            applyLayout()
        }
    }

    private func dragEnded() {
        if let point = dragPoint, let nearest = DockGeometry.nearest(to: point, displays: displays()) {
            placement = nearest.placement
            anchor = nearest
        }
        dragPoint = nil
        applyLayout()
        persistPlacement()
        send(.dragEnded)
        reconcilePointer()
    }

    // MARK: - Pointer and geometry

    private func reconcilePointer(at eventPoint: CGPoint? = nil) {
        guard let layout, !sleeping, !locked else { return }
        let point = eventPoint ?? NSEvent.mouseLocation
        send(
            .pointer(
                inside: layout.contains(point, phase: state.phase),
                onCompanion: layout.onOrb(point) || layout.strip.contains(point)))
    }

    private func updateHitTesting() {
        guard let layout else { return }
        // The strip-sized panel always listens; a larger panel listens only inside the companion's shape.
        panel.ignoresMouseEvents =
            !panelShowsStrip && state.phase != .dragging
            && !layout.contains(NSEvent.mouseLocation, phase: state.phase)
    }

    private func displays() -> [DockDisplay] {
        // NSScreen.screens starts with the menu-bar display, independent of the key window.
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "display-\(number?.uint32Value ?? 0)"
            return DockDisplay(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    private func updatePlacement() {
        let screens = displays()
        guard let first = screens.first else {
            panel.orderOut(nil)
            return
        }
        let requested = placement ?? DockPlacement(displayID: first.id)
        anchor = DockGeometry.resolve(requested, displays: screens)
        // Retain the saved display ID so a temporarily disconnected display can reclaim its placement.
        if placement == nil { placement = anchor?.placement }
        applyLayout()
        if !sleeping, !locked { panel.orderFrontRegardless() }
    }

    private func applyLayout(transition: DashboardView.ContentTransition? = nil) {
        guard let anchor else { return }
        layoutGeneration += 1
        let generation = layoutGeneration
        stage.dashboard.cancelContentTransition()
        let newLayout = CompanionLayout(
            anchor: anchor, dragPoint: dragPoint, summarySize: stage.summary.preferredSize,
            dashboardSize: stage.dashboard.preferredSize(maxHeight: CompanionLayout.dashboardMaxHeight(for: anchor)))
        layout = newLayout
        let container =
            panelShowsStrip
            ? newLayout.strip
            : transition == nil ? newLayout.frame : newLayout.frame.union(panel.frame)
        if panel.frame != container { panel.setFrame(container, display: true) }
        stage.place(newLayout, in: container)
        if let transition, !panelShowsStrip {
            stage.dashboard.animateContent(from: transition) { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.applyLayout()
            }
        }
        updateHitTesting()
    }

    private func persistPlacement() {
        guard let placement, let data = try? JSONEncoder().encode(placement) else { return }
        UserDefaults.standard.set(data, forKey: "dockPlacement")
    }

    private func suspend() {
        state.send(.reset, now: ProcessInfo.processInfo.systemUptime)
        for timer in [deadlineTimer, pointerTimer, clockTimer] { timer?.invalidate() }
        pointerTimer = nil
        clockTimer = nil
        if let layout {
            presentationGeneration += 1
            stage.show(.hidden, layout: layout, animated: false)
            collapseToStrip()
        }
        panel.orderOut(nil)
    }

    @objc private func menuOpened() { send(.menuOpened) }
    @objc private func menuClosed() { send(.menuClosed) }
    @objc private func displaysChanged() { updatePlacement() }
    @objc private func willSleep() {
        sleeping = true
        suspend()
    }
    @objc private func didWake() {
        sleeping = false
        updatePlacement()
        refresh(userInitiated: false)
    }
    @objc private func screenLocked() {
        locked = true
        suspend()
    }
    @objc private func screenUnlocked() {
        locked = false
        updatePlacement()
        refresh(userInitiated: false)
    }
}
