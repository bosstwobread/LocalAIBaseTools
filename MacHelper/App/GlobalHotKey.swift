import AppKit
import Carbon

struct GlobalShortcut: Codable, Equatable {
    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        keyLabel: "M"
    )

    private static let modifierSymbols: [(NSEvent.ModifierFlags, UInt32, String)] = [
        (.control, UInt32(controlKey), "⌃"),
        (.option, UInt32(optionKey), "⌥"),
        (.shift, UInt32(shiftKey), "⇧"),
        (.command, UInt32(cmdKey), "⌘")
    ]

    let keyCode: UInt32
    let modifiers: UInt32
    private let keyLabel: String

    var displayName: String {
        Self.modifierSymbols.filter { modifiers & $0.1 != 0 }.map { $0.2 }.joined() + keyLabel
    }

    private init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat, event.keyCode < 128, event.keyCode != kVK_Escape,
              let label = Self.keyLabel(for: event) else { return nil }
        let modifiers = Self.modifierSymbols.reduce(UInt32(0)) { result, modifier in
            event.modifierFlags.contains(modifier.0) ? result | modifier.1 : result
        }
        guard modifiers.nonzeroBitCount >= 2 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }

    static func load(from data: Data?) -> GlobalShortcut {
        guard let data, data.count <= 1024,
              let shortcut = try? JSONDecoder().decode(Self.self, from: data),
              shortcut.keyCode < 128, shortcut.keyCode != kVK_Escape,
              shortcut.modifiers.nonzeroBitCount >= 2,
              shortcut.modifiers & ~UInt32(controlKey | optionKey | shiftKey | cmdKey) == 0,
              (1...3).contains(shortcut.keyLabel.count),
              shortcut.keyLabel.rangeOfCharacter(from: .controlCharacters) == nil
        else { return .defaultShortcut }
        return shortcut
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "␣"
        case kVK_Tab: return "⇥"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }
        if let value = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(value) {
            return "F\(value - UInt32(NSF1FunctionKey) + 1)"
        }
        let unmodified = event.characters(byApplyingModifiers: [])
        guard let text = unmodified?.count == 1 ? unmodified : event.charactersIgnoringModifiers,
              text.count == 1 else { return nil }
        guard text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .privateUse }),
              text.rangeOfCharacter(from: .controlCharacters.union(.whitespacesAndNewlines)) == nil
        else { return nil }
        return text.uppercased()
    }
}

@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x4D48_4B59 // MHKY
    private struct Registration {
        let shortcut: GlobalShortcut
        let identifier: UInt32
        let reference: EventHotKeyRef
    }

    private var registration: Registration?
    private var lastIdentifier: UInt32 = 0
    private var eventHandler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        if let current = registration?.shortcut,
           current.keyCode == shortcut.keyCode, current.modifiers == shortcut.modifiers {
            self.action = action
            return true
        }

        let target = GetApplicationEventTarget()
        guard installHandler(on: target) else { return false }
        lastIdentifier &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: lastIdentifier),
            target,
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            if registration == nil { unregister() }
            return false
        }

        if let previous = registration { UnregisterEventHotKey(previous.reference) }
        registration = Registration(shortcut: shortcut, identifier: lastIdentifier, reference: reference)
        self.action = action
        return true
    }

    private func installHandler(on target: EventTargetRef?) -> Bool {
        if eventHandler != nil { return true }
        // Handle release once even when the user holds the shortcut long enough for key repeat.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased)
        )
        let handlerStatus = InstallEventHandler(
            target,
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { registrar.handleRelease(event) }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        return handlerStatus == noErr
    }

    func unregister() {
        action = nil
        if let registration {
            UnregisterEventHotKey(registration.reference)
            self.registration = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration.reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func handleRelease(_ event: EventRef) -> OSStatus {
        var eventID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventID
        )
        guard status == noErr,
              eventID.signature == Self.signature,
              eventID.id == registration?.identifier,
              let action else { return OSStatus(eventNotHandledErr) }

        action()
        return noErr
    }
}
