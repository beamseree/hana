import Carbon

/// Exclusive registration, not global keyboard monitoring. Owned by Mac Interaction.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let invoke: () -> Void

    init(invoke: @escaping () -> Void) { self.invoke = invoke }

    func register() -> OSStatus {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            MainActor.assumeIsolated {
                guard let context else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().invoke()
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return installed }
        return RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x48414E41, id: 1),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
        )
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
