//
//  TidemarkApp.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/2.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private lazy var companion = CompanionController(settings: settings)
    private let shortcut = GlobalShortcut()
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, shortcut: shortcut, resetPosition: { [weak self] in self?.companion.resetPlacement() })
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
        menu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ","
        ).target = self
        liveItem.target = self
        menu.addItem(liveItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Quit Tidemark"), action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Quit Tidemark"), action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        // Window key equivalents such as Command-W only reach the settings window through menu items.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(
            withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        companion.openSettings = { [weak self] in self?.settingsWindow.show() }
        shortcut.onPressed = { [weak self] in self?.companion.toggleCompanion() }
        shortcut.start()
        companion.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut.stop()
        companion.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        liveItem.state = companion.liveEnabled ? .on : .off
    }

    @objc private func showSettings() { settingsWindow.show() }
    @objc private func showCompanion() { companion.showCompanion() }
    @objc private func resetPosition() { companion.resetPlacement() }
    @objc private func toggleLive() { companion.setLiveEnabled(!companion.liveEnabled) }
}
