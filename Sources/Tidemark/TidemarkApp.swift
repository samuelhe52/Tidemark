//
//  TidemarkApp.swift
//  Tidemark
//
//  Created by Claude Code on behalf of Samuel He on 2026/11/2.
//

import SwiftUI

@main
struct TidemarkApp: App {
    var body: some Scene {
        MenuBarExtra("Tidemark", systemImage: "water.waves") {
            Button("Quit Tidemark") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
