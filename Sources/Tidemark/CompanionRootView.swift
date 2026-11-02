//
//  CompanionRootView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import SwiftUI
import TidemarkAppearance
import TidemarkData
import TidemarkEngine

struct CompanionRootView: View {
    @ObservedObject var controller: CompanionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let layout = controller.layout {
            if controller.state.phase == .hidden {
                Capsule().fill(.cyan.opacity(0.65))
                    .frame(width: layout.glow.width, height: layout.glow.height)
                    .frame(width: layout.strip.width, height: layout.strip.height)
                    .allowsHitTesting(false)
            } else {
                visibleContent(layout)
            }
        }
    }

    private func visibleContent(_ layout: CompanionLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            OrbView(
                pinned: controller.state.phase == .pinned,
                animated: !ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            .overlay {
                CompanionInteraction(
                    clicked: { controller.send(.companionClicked) },
                    dragChanged: { controller.dragChanged(to: $0) },
                    dragEnded: { controller.dragEnded() })
            }
            .frame(width: 64, height: 64)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                controller.state.phase == .pinned ? Text("Unpin companion") : Text("Pin companion")
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.send(.companionClicked) }
            .position(layout.localCenter(layout.orb))
            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.8)))
            if controller.state.phase == .expanded || controller.state.phase == .pinned {
                QuotaDashboard(
                    observations: controller.observations,
                    pinned: controller.state.phase == .pinned,
                    refreshing: controller.refreshing, refresh: controller.refresh
                )
                .frame(width: layout.dashboard.width, height: layout.dashboard.height)
                .position(layout.localCenter(layout.dashboard))
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
            } else if controller.state.phase == .revealed {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(summary(at: context.date))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                }
                .frame(width: layout.summary.width, height: layout.summary.height)
                .position(layout.localCenter(layout.summary)).allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        // Animate inside a stable panel size; never animate the hidden strip into this rectangle.
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.86),
            value: controller.state.phase)
    }

    private func summary(at now: Date) -> String {
        controller.observations.map { observation in
            let name = observation.service == .claude ? "Claude" : "Codex"
            guard let window = observation.windows.first, let remaining = window.remainingPercent(at: now) else {
                return String(localized: "\(name) unknown")
            }
            let duration: String
            switch window.duration {
            case 18000: duration = "5h"
            case 604800: duration = "7d"
            case 2_592_000: duration = "30d"
            default: duration = ""
            }
            return "\(name) \(duration) \(Int(remaining.rounded()))%"
        }.joined(separator: "  ·  ")
    }
}
