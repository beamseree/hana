// Runtime fixture: reserve Option+Space in another process. No UI or settings changes.
// Compile/run separately from Hana; stop with Control-C when the conflict check ends.
import Carbon
import Foundation

var hotKey: EventHotKeyRef?
let status = RegisterEventHotKey(
    UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x54455354, id: 1),
    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
)
guard status == noErr else {
    print("Could not reserve shortcut; OSStatus=\(status). Quit Hana/prototype first.")
    exit(1)
}
print("Reserved Option+Space exclusively. PID=\(ProcessInfo.processInfo.processIdentifier). Stop with Control-C.")
fflush(stdout)
RunLoop.main.run()
