//
//  CompanionController.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import Combine
import SwiftUI
import TidemarkData
import TidemarkEngine

@MainActor
final class CompanionController: NSObject, ObservableObject {
    @Published private(set) var state = CompanionState()
    @Published private(set) var layout: CompanionLayout?
    @Published private(set) var observations = QuotaService.allCases.map {
        ServiceObservation(service: $0, issue: .missing)
    }
    @Published private(set) var refreshing = false
    let panel = CompanionPanel()
    private let reader: PassiveQuotaReader
    private var placement: DockPlacement?
    private var anchor: DockAnchor?
    private var deadlineTimer: Timer?
    private var pointerTimer: Timer?
    private var refreshTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var escapeMonitor: Any?
    private var sleeping = false
    private var locked = false
    private var dragPoint: CGPoint?
    private var lastRefresh = Date.distantPast

    override init() {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        reader = PassiveQuotaReader(codexHome: codexHome)
        super.init()
    }

    func start() {
        if let data = UserDefaults.standard.data(forKey: "dockPlacement") {
            placement = try? JSONDecoder().decode(DockPlacement.self, from: data)
        }
        let hosting = CompanionHostingView(rootView: CompanionRootView(controller: self))
        hosting.hiddenStripActive = { [weak self] in self?.state.phase == .hidden }
        hosting.pointerChanged = { [weak self] event in
            self?.reconcilePointer(at: event.window?.convertPoint(toScreen: event.locationInWindow))
        }
        hosting.stripClicked = { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            guard let self, self.layout?.strip.contains(point) == true else { return false }
            self.send(.companionClicked)
            return true
        }
        panel.contentView = hosting
        updatePlacement()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            Task { @MainActor in self?.reconcilePointer() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.state.phase == .pinned {
                self.send(.escape)
            } else if event.type != .keyDown {
                self.reconcilePointer()
            }
            return event
        }
        // macOS delivers global key events only when input-monitoring access already permits it.
        // Registration does not request that permission; orb click always provides an unpin path.
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.sleeping, !self.locked else { return }
                self.refresh()
            }
        }
        refresh()
        reconcilePointer()
    }

    func stop() {
        deadlineTimer?.invalidate()
        pointerTimer?.invalidate()
        refreshTimer?.invalidate()
        for monitor in [globalMonitor, localMonitor, escapeMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        escapeMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        panel.orderOut(nil)
    }

    func send(_ event: CompanionEvent) {
        guard !sleeping, !locked else { return }
        let previous = state.phase
        state.send(event, now: ProcessInfo.processInfo.systemUptime)
        if previous == .hidden, state.phase != .hidden, Date().timeIntervalSince(lastRefresh) >= 5 { refresh() }
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
        } else if pointerTimer == nil {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reconcilePointer() }
            }
        }
        if previous != state.phase { updatePanelFrame() }
        updateHitTesting()
    }

    func showCompanion() {
        if anchor == nil { updatePlacement() }
        if state.phase != .pinned { send(.companionClicked) }
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

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { [weak self, reader] in
            let result = await reader.read()
            guard let self else { return }
            self.observations = result
            self.refreshing = false
            self.lastRefresh = .now
        }
    }

    func dragChanged(to point: CGPoint) {
        if state.phase != .dragging { send(.dragBegan) }
        dragPoint = point
        if let nearest = DockGeometry.nearest(to: point, displays: displays()) {
            anchor = nearest
            applyLayout()
        }
    }

    func dragEnded() {
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
        panel.ignoresMouseEvents = state.phase != .hidden && !layout.contains(NSEvent.mouseLocation, phase: state.phase)
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

    private func applyLayout() {
        guard let anchor else { return }
        let newLayout = CompanionLayout(anchor: anchor, dragPoint: dragPoint)
        layout = newLayout
        updatePanelFrame()
        updateHitTesting()
    }

    private func updatePanelFrame() {
        guard let layout else { return }
        panel.setFrame(state.phase == .hidden ? layout.strip : layout.frame, display: true)
    }

    private func persistPlacement() {
        guard let placement, let data = try? JSONEncoder().encode(placement) else { return }
        UserDefaults.standard.set(data, forKey: "dockPlacement")
    }

    private func suspend() {
        state.send(.reset, now: ProcessInfo.processInfo.systemUptime)
        deadlineTimer?.invalidate()
        pointerTimer?.invalidate()
        pointerTimer = nil
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
        refresh()
    }
    @objc private func screenLocked() {
        locked = true
        suspend()
    }
    @objc private func screenUnlocked() {
        locked = false
        updatePlacement()
        refresh()
    }
}
