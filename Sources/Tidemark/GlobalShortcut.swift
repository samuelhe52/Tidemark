//
//  GlobalShortcut.swift
//  Tidemark
//
//  Created by OpenAI Codex on behalf of Samuel He on 2026/11/3.
//

import AppKit
import Carbon
import Observation

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers =
            (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
        switch event.keyCode {
        case 36: keyLabel = "↩"
        case 48: keyLabel = "⇥"
        case 49: keyLabel = String(localized: "Space")
        case 51: keyLabel = "⌫"
        case 123: keyLabel = "←"
        case 124: keyLabel = "→"
        case 125: keyLabel = "↓"
        case 126: keyLabel = "↑"
        default:
            let functionKeys = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
            ]
            if let index = functionKeys.firstIndex(of: Int(event.keyCode)) {
                keyLabel = "F\(index + 1)"
                return
            }
            guard let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            keyLabel = characters.uppercased()
        }
    }
}

/// System hotkeys avoid an event tap and don't ask for global keyboard-monitoring access.
@Observable @MainActor
final class GlobalShortcut {
    private(set) var shortcut: KeyboardShortcut?
    private(set) var isRecording = false
    private(set) var error: LocalizedStringResource?
    var onPressed: (() -> Void)?
    private let defaults: UserDefaults
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var registeredID: UInt32?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = defaults.data(forKey: "companionKeyboardShortcut")
            .flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) }
    }

    func start() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x5449_4445 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                    if identifier.id == owner.registeredID, !owner.isRecording { owner.onPressed?() }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            error = "Couldn't enable keyboard shortcuts (\(status))."
            return
        }
        _ = register(shortcut)
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        registeredID = nil
        handler = nil
    }

    func beginRecording() {
        error = nil
        isRecording = true
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        registeredID = nil
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        _ = register(shortcut)
    }

    @discardableResult
    func setShortcut(_ value: KeyboardShortcut?) -> Bool {
        guard register(value) else { return false }
        shortcut = value
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: "companionKeyboardShortcut")
        isRecording = false
        return true
    }

    private func register(_ value: KeyboardShortcut?) -> Bool {
        guard let value else {
            if let hotKey {
                UnregisterEventHotKey(hotKey)
                self.hotKey = nil
            }
            registeredID = nil
            error = nil
            return true
        }
        guard handler != nil else {
            error = "Keyboard shortcuts are unavailable. Try reopening Tidemark."
            return false
        }
        var replacement: EventHotKeyRef?
        nextID &+= 1
        let status = RegisterEventHotKey(
            value.keyCode, value.modifiers, EventHotKeyID(signature: 0x5449_4445, id: nextID),
            GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else {
            error = "This shortcut couldn't be registered. It may be in use. Choose another."
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        registeredID = nextID
        error = nil
        return true
    }
}
