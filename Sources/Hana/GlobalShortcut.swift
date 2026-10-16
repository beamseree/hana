import Carbon

/// Exclusive registration, not global keyboard monitoring. Owned by Mac Interaction.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var selection: SearchShortcut?
    private let invoke: () -> Void

    init(invoke: @escaping () -> Void) { self.invoke = invoke }

    func register(_ shortcut: SearchShortcut = .optionSpace) -> OSStatus {
        if selection == shortcut, hotKey != nil { return noErr }
        if handler == nil {
            let installed = installHandler()
            guard installed == noErr else { return installed }
        }
        // Acquire the replacement before releasing the current shortcut, so a
        // conflict (for example Spotlight) cannot disable the working choice.
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(
            UInt32(kVK_Space), shortcut.modifiers,
            EventHotKeyID(signature: 0x48414E41, id: shortcut.hotKeyID),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &replacement
        )
        guard result == noErr else {
            if hotKey == nil { unregister() }
            return result
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        selection = shortcut
        return noErr
    }

    private func installHandler() -> OSStatus {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            MainActor.assumeIsolated {
                guard let context else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().handle(event)
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func handle(_ event: EventRef?) -> OSStatus {
        guard let event, let selection else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard result == noErr, identifier.signature == 0x48414E41,
              identifier.id == selection.hotKeyID else { return OSStatus(eventNotHandledErr) }
        invoke()
        return noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        selection = nil
    }
}
