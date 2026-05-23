import Carbon.HIToolbox
import Foundation

final class GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerRef: EventHandlerRef?

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        var hotKeyID = EventHotKeyID(signature: FourCharCode("APIP"), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if status == noErr, let action = GlobalHotKey.actions[hotKeyID.id] {
                DispatchQueue.main.async(execute: action)
            }

            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }
}

private func FourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for character in string.utf8.prefix(4) {
        result = (result << 8) + OSType(character)
    }
    return result
}
