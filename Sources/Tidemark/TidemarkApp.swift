//
//  TidemarkApp.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/2.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let companion = CompanionController()
    private var statusItem: NSStatusItem?
    private let liveItem = NSMenuItem(
        title: String(localized: "Live Usage"), action: #selector(toggleLive), keyEquivalent: "")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Tidemark")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(
            withTitle: String(localized: "Show Companion"), action: #selector(showCompanion), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: String(localized: "Reset Position"), action: #selector(resetPosition), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        liveItem.target = self
        menu.addItem(liveItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Quit Tidemark"), action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        companion.start()
    }

    func applicationWillTerminate(_ notification: Notification) { companion.stop() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        liveItem.state = companion.liveEnabled ? .on : .off
    }

    @objc private func showCompanion() { companion.showCompanion() }
    @objc private func resetPosition() { companion.resetPlacement() }
    @objc private func toggleLive() { companion.setLiveEnabled(!companion.liveEnabled) }
}
