//
//  TidemarkApp.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/2.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let companion = CompanionController()

    func applicationDidFinishLaunching(_ notification: Notification) { companion.start() }
    func applicationWillTerminate(_ notification: Notification) { companion.stop() }
}

@main
struct TidemarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("Tidemark", systemImage: "water.waves") {
            Button("Show Companion") { delegate.companion.showCompanion() }
            Button("Reset Position") { delegate.companion.resetPlacement() }
            Divider()
            Button("Quit Tidemark") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show Companion") { delegate.companion.showCompanion() }
                Button("Reset Position") { delegate.companion.resetPlacement() }
            }
        }
    }
}
