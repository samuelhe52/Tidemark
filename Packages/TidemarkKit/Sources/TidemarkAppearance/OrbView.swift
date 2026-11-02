//
//  OrbView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import SwiftUI

/// Provisional native renderer.
///
/// Receives presentation values, never engine or usage objects.
public struct OrbView: View {
    public let pinned: Bool
    public let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pinned: Bool, animated: Bool) {
        self.pinned = pinned
        self.animated = animated
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion)) { context in
            let breath = animated && !reduceMotion ? sin(context.date.timeIntervalSinceReferenceDate * 1.4) : 0
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.18))
                    .blur(radius: 8)
                    .scaleEffect(1.1 + breath * 0.04)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.74, green: 1, blue: 0.94), .cyan,
                                Color(red: 0.05, green: 0.32, blue: 0.48),
                                Color(red: 0.03, green: 0.10, blue: 0.22)
                            ],
                            center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 58)
                    )
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.7)
                    }
                    .overlay(alignment: .topLeading) {
                        Ellipse().fill(.white.opacity(0.55)).frame(width: 18, height: 9)
                            .blur(radius: 3).offset(x: 13, y: 11)
                    }
                    .scaleEffect(0.94 + breath * 0.025)
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9)).shadow(radius: 2)
                }
            }
            .frame(width: 64, height: 64)
        }
        .accessibilityLabel("Tidemark companion")
    }
}
