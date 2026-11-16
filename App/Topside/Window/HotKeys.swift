import AppKit
import Carbon.HIToolbox

/// Global hot keys through Carbon's RegisterEventHotKey: works in any app and,
/// unlike an event tap, needs no Accessibility permission (M0 conclusion 4).
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    /// Names of hot keys another app already holds.
    private(set) var unavailable: [String] = []

    func register(id: UInt32, keyCode: Int, modifiers: Int, name: String, action: @escaping () -> Void) {
        installHandler()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5450_5344), id: id)   // 'TPSD'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        } else {
            unavailable.append(name)
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().actions[id]?()
            }
            return noErr
        }, 1, &spec, me, &handler)
    }
}
