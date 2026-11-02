//
//  QuotaDashboard.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import SwiftUI
import TidemarkData

struct QuotaDashboard: View {
    let observations: [ServiceObservation]
    let pinned: Bool
    let refreshing: Bool
    let refresh: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tidemark").font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text("A little room to keep going").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.cyan)
                            .accessibilityLabel("Pinned")
                    }
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).disabled(refreshing)
                    .help("Read local usage again").accessibilityLabel("Refresh local usage")
                }
                .padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(observations) { observation in
                            serviceSection(observation, now: context.date)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                Divider().overlay(.white.opacity(0.06)).padding(.top, 10).padding(.bottom, 9)
                HStack(spacing: 5) {
                    Circle().fill(.mint.opacity(0.8)).frame(width: 4, height: 4)
                    Text("Local observations · no live requests").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.025, green: 0.06, blue: 0.09).opacity(0.86))
                RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.13), lineWidth: 0.7)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private func serviceSection(_ observation: ServiceObservation, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(
                    systemName: observation.service == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right"
                )
                .foregroundStyle(observation.service == .claude ? Color.orange.opacity(0.85) : Color.mint)
                Text(observation.service == .claude ? "Claude Code" : "Codex")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("LOCAL").font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if observation.windows.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quota unknown").font(.system(size: 12, weight: .medium))
                        Text(issueLabel(observation.issue)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("—").font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(observation.windows) { window in
                    quotaRow(window, now: now)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func quotaRow(_ window: QuotaWindow, now: Date) -> some View {
        let remaining = window.remainingPercent(at: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(windowLabel(window.id)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let remaining {
                    Text("\(remaining, specifier: "%.0f")% left")
                        .font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
                } else {
                    Text("Unknown").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.07))
                if let remaining {
                    Capsule().fill(.mint.opacity(0.75))
                        .frame(width: geometry.size.width * remaining / 100)
                }
            }
            .frame(height: 3)
            HStack(alignment: .firstTextBaseline) {
                if window.freshness(at: now) == .expired {
                    Text("Refresh needed")
                } else if window.freshness(at: now) == .stale {
                    Text("Stale observation")
                } else if let reset = window.resetsAt {
                    Text("Resets in \(countdown(reset.timeIntervalSince(now)))")
                } else {
                    Text("Reset unknown")
                }
                Spacer(minLength: 4)
                Text("\(sourceLabel(window.source)) · \(age(window.observedAt, now: now))")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func issueLabel(_ issue: QuotaReadIssue?) -> LocalizedStringResource {
        switch issue {
        case .missing: "No local observation yet"
        case .unreadable: "Local source could not be read"
        case .unrecognized: "No supported quota in the local source"
        case nil: "Waiting for a local observation"
        }
    }

    private func windowLabel(_ id: String) -> String {
        switch id {
        case "five_hour": String(localized: "5 hours")
        case "seven_day": String(localized: "7 days")
        case "30_day": String(localized: "30 days")
        case "seven_day_opus": String(localized: "7 days · Opus")
        case "seven_day_sonnet": String(localized: "7 days · Sonnet")
        case "seven_day_fable": String(localized: "7 days · Fable")
        default: id.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func sourceLabel(_ source: QuotaSource) -> String {
        switch source {
        case .claudeCache: String(localized: "cache")
        case .statusline: String(localized: "statusline")
        case .rollout: String(localized: "rollout")
        }
    }

    private func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return String(localized: "clock mismatch") }
        return String(localized: "\(countdown(max(0, seconds))) ago")
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return String(localized: "<1m") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        if minutes < 1440 { return String(localized: "\(minutes / 60)h \(minutes % 60)m") }
        return String(localized: "\(minutes / 1440)d \(minutes % 1440 / 60)h")
    }
}
