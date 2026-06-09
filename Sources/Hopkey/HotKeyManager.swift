import AppKit
import Carbon.HIToolbox

/// Регистрирует глобальный хоткей (по умолчанию ⌃⌥J) через Carbon.
/// При срабатывании синтезирует Cmd+C, читает выделение из буфера и отдаёт его в `onCapture`.
///
/// Синтез Cmd+C и чтение чужого выделения требуют разрешения Accessibility.
final class HotKeyManager {

    /// Текст выделения, полученный после нажатия хоткея.
    var onCapture: ((String) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private let hotKeyID = EventHotKeyID(signature: fourCharCode("JOPN"), id: 1)

    /// Есть ли разрешение Accessibility. `prompt: true` покажет системный запрос.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Регистрирует комбинацию `keyCode` + `modifiers` (Carbon-формат модификаторов).
    func register(keyCode: UInt32, modifiers: UInt32) {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.id == manager.hotKeyID.id {
                manager.handleFire()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Hopkey: не удалось зарегистрировать хоткей (status=\(status)) — комбинация занята системой?")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleFire() {
        let pasteboard = NSPasteboard.general
        let beforeCount = pasteboard.changeCount

        synthesizeCopy()

        // Небольшая задержка, чтобы целевое приложение успело положить выделение в буфер.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            // Берём текст, только если буфер реально обновился после нашего Cmd+C.
            if pasteboard.changeCount != beforeCount,
               let text = pasteboard.string(forType: .string), !text.isEmpty {
                self.onCapture?(text)
            } else {
                // Буфер не изменился: синтетический Cmd+C не сработал.
                // Почти всегда это значит, что не выдан Accessibility для текущего бинарника.
                NSLog("Hopkey: хоткей сработал, но буфер не изменился — проверьте разрешение Accessibility (после пересборки его нужно выдать заново).")
            }
        }
    }

    private func synthesizeCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Превращает 4-символьную строку в OSType для сигнатуры хоткея.
private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + FourCharCode(scalar.value & 0xFF)
    }
    return result
}
