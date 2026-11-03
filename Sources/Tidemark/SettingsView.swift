//
//  SettingsView.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement
import SwiftUI
import TidemarkData

@Observable @MainActor
final class LoginItemSettings {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: LocalizedStringResource?

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        refresh()
    }
}

/// Standard macOS form styling, system colors and controls; independent of companion skins.
fileprivate struct SettingsPane<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 500, height: height)
    }
}

struct GeneralSettingsView: View {
    let shortcut: GlobalShortcut
    let login: LoginItemSettings

    var body: some View {
        SettingsPane(height: 250) {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { login.isRegistered }, set: login.setEnabled))
                if login.status == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Approval needed in System Settings")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = login.error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            Section {
                LabeledContent("Show or hide companion") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(shortcut: shortcut)
                            .frame(width: 160, height: 24)
                        Button {
                            _ = shortcut.setShortcut(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(shortcut.shortcut == nil && !shortcut.isRecording)
                        .help("Clear keyboard shortcut")
                        .accessibilityLabel("Clear keyboard shortcut")
                    }
                }
                if let error = shortcut.error { Text(error).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Use Command, Control, or Option. Press Escape to cancel or Delete to clear.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}

struct CompanionSettingsView: View {
    @Bindable var settings: SettingsStore
    let resetPosition: () -> Void

    var body: some View {
        SettingsPane(height: 300) {
            Section {
                Picker("Show dashboard on", selection: $settings.hoverToExpand) {
                    Text("Hover").tag(true)
                    Text("Click").tag(false)
                }
                .pickerStyle(.segmented)
                if settings.hoverToExpand {
                    delay("Expand after", value: $settings.expansionDelay)
                }
                delay("Retract after", value: $settings.retractionDelay)
            } footer: {
                Text(
                    "Hovering the screen edge always shows the orb. Option-click or right-click the orb to pin the dashboard open; do it again or press Escape to unpin."
                )
            }
            Section {
                LabeledContent("Position") {
                    Button("Reset", action: resetPosition)
                }
            } footer: {
                Text("Moves the companion back to its default edge on the main display.")
            }
        }
    }

    private func delay(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                // Continuous, rounded to 0.1 s: a stepped slider draws a tick for every step.
                Slider(
                    value: Binding(
                        get: { value.wrappedValue },
                        set: { new in
                            let rounded = (new * 10).rounded() / 10
                            if rounded != value.wrappedValue { value.wrappedValue = rounded }
                        }),
                    in: 0...3
                ) {
                    Text(title)
                }
                .labelsHidden()
                .frame(width: 160)
                Text("\(value.wrappedValue, format: .number.precision(.fractionLength(1))) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

struct UsageSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPane(height: 300) {
            Section {
                Toggle("Live usage", isOn: $settings.liveUsageEnabled)
            } footer: {
                Text(
                    "Fetch current quotas using existing sign-ins. Managed CC Switch Codex sign-ins may be renewed and saved. When off, Tidemark uses local readings."
                )
            }
            Section("Display") {
                Picker("Show quota as", selection: $settings.display.percentageStyle) {
                    Text("Remaining").tag(QuotaPercentageStyle.remaining)
                    Text("Used").tag(QuotaPercentageStyle.used)
                }
                .pickerStyle(.segmented)
                Picker("Show resets as", selection: $settings.display.resetTimeStyle) {
                    Text("Countdown").tag(QuotaResetTimeStyle.countdown)
                    Text("Clock time").tag(QuotaResetTimeStyle.clock)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct AccountsSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var dropTargetID: String?

    private var summaryServices: [QuotaService] {
        QuotaService.allCases.filter { service in settings.accounts.contains { $0.service == service } }
    }

    var body: some View {
        SettingsPane(height: 460) {
            Section {
                if summaryServices.isEmpty {
                    Text("Accounts appear after usage has been read.").foregroundStyle(.secondary)
                }
                ForEach(summaryServices, id: \.self) { service in
                    summaryPicker(service)
                }
            } header: {
                Text("Compact Summary")
            } footer: {
                Text("Automatic shows the account currently in use. Off leaves the service out of the summary.")
            }
            Section {
                if settings.accounts.isEmpty {
                    Text("Accounts appear after usage has been read.").foregroundStyle(.secondary)
                }
                ForEach(settings.orderedAccounts) { account in
                    row(account)
                }
            } header: {
                Text("Dashboard Accounts")
            } footer: {
                Text("Drag to reorder. Unchecked accounts are hidden from the dashboard.")
            }
        }
    }

    private func summaryPicker(_ service: QuotaService) -> some View {
        let choice = Binding(
            get: { settings.display.summaryChoice(for: service) },
            set: { settings.display.summaryChoices[service] = $0 == .automatic ? nil : $0 }
        )
        let accounts = settings.orderedAccounts.filter {
            $0.service == service && !settings.display.hiddenAccountIDs.contains($0.id)
        }
        return Picker(QuotaText.serviceName(service), selection: choice) {
            Text("Automatic").tag(QuotaSummaryChoice.automatic)
            ForEach(accounts) { account in
                Text(QuotaText.accountName(account)).tag(
                    QuotaSummaryChoice.account(account.id))
            }
            if case .account(let id) = choice.wrappedValue, !accounts.contains(where: { $0.id == id }) {
                Text("Selected account unavailable").tag(QuotaSummaryChoice.account(id))
            }
            Divider()
            Text("Off").tag(QuotaSummaryChoice.off)
        }
    }

    private func row(_ account: AccountUsage) -> some View {
        let ids = settings.orderedAccounts.map(\.id)
        let index = ids.firstIndex(of: account.id) ?? 0
        let name = QuotaText.accountName(account)
        return HStack(spacing: 10) {
            // A bare checkbox: on macOS a checkbox label toggles on click, which would swallow drags.
            Toggle(
                name,
                isOn: Binding(
                    get: { !settings.display.hiddenAccountIDs.contains(account.id) },
                    set: { settings.setVisible($0, accountID: account.id) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1).truncationMode(.middle)
                Text(QuotaText.serviceName(account.service))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .draggable(account.id) {
            Text(name).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, let source = ids.firstIndex(of: dragged), source != index else {
                return false
            }
            // Dropping onto a row takes that row's position, from either direction.
            move(account: dragged, to: source < index ? index + 1 : index)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetID = account.id
            } else if dropTargetID == account.id {
                dropTargetID = nil
            }
        }
        .listRowBackground(dropTargetID == account.id ? Color.accentColor.opacity(0.15) : nil)
        .contextMenu {
            Button("Move to Top") { move(account: account.id, to: 0) }.disabled(index == 0)
            Button("Move Up") { move(account: account.id, to: index - 1) }.disabled(index == 0)
            Button("Move Down") { move(account: account.id, to: index + 2) }.disabled(index == ids.count - 1)
            Button("Move to Bottom") { move(account: account.id, to: ids.count) }.disabled(index == ids.count - 1)
        }
        .accessibilityActions {
            if index > 0 { Button("Move Up") { move(account: account.id, to: index - 1) } }
            if index < ids.count - 1 { Button("Move Down") { move(account: account.id, to: index + 2) } }
        }
    }

    /// `offset` follows `onMove` semantics: the destination index before removal.
    private func move(account id: String, to offset: Int) {
        guard let index = settings.orderedAccounts.firstIndex(where: { $0.id == id }) else { return }
        settings.moveAccounts(fromOffsets: IndexSet(integer: index), toOffset: offset)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(shortcut: shortcut)
    }

    static func dismantleNSView(_ view: ShortcutRecorderButton, coordinator: ()) { view.cancelRecording() }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.title =
            shortcut.isRecording
            ? String(localized: "Type shortcut…")
            : shortcut.shortcut?.label ?? String(localized: "Record Shortcut")
    }
}

final class ShortcutRecorderButton: NSButton {
    private let shortcut: GlobalShortcut

    init(shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(record)
        setAccessibilityLabel(String(localized: "Show or hide companion keyboard shortcut"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }

    @objc private func record() {
        window?.makeFirstResponder(self)
        shortcut.beginRecording()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard shortcut.isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard shortcut.isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    func cancelRecording() { shortcut.cancelRecording() }

    override func resignFirstResponder() -> Bool {
        shortcut.cancelRecording()
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            shortcut.cancelRecording()
            return
        }
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)),
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        {
            _ = shortcut.setShortcut(nil)
        } else if let value = KeyboardShortcut(event: event) {
            _ = shortcut.setShortcut(value)
        } else {
            NSSound.beep()
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let shortcut: GlobalShortcut
    private let login: LoginItemSettings

    init(settings: SettingsStore, shortcut: GlobalShortcut, resetPosition: @escaping () -> Void) {
        self.shortcut = shortcut
        let login = LoginItemSettings()
        self.login = login
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (label, symbol, view) in [
            (
                String(localized: "General"), "gearshape",
                AnyView(GeneralSettingsView(shortcut: shortcut, login: login))
            ),
            (
                String(localized: "Companion"), "water.waves",
                AnyView(CompanionSettingsView(settings: settings, resetPosition: resetPosition))
            ),
            (String(localized: "Usage"), "chart.pie", AnyView(UsageSettingsView(settings: settings))),
            (String(localized: "Accounts"), "person.crop.circle", AnyView(AccountsSettingsView(settings: settings)))
        ] {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            host.title = label
            let item = NSTabViewItem(viewController: host)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        login.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { shortcut.cancelRecording() }
    func windowDidResignKey(_ notification: Notification) { shortcut.cancelRecording() }
}
