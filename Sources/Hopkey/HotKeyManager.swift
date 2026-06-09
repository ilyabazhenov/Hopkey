import AppKit
import Carbon.HIToolbox
import HopkeyCore

/// Регистрирует несколько глобальных хоткеев через Carbon, каждый — со своим действием.
/// При срабатывании синтезирует Cmd+C, читает выделение из буфера и отдаёт его в `onCapture`
/// вместе с действием сработавшего хоткея.
///
/// Синтез Cmd+C и чтение чужого выделения требуют разрешения Accessibility.
final class HotKeyManager {

    /// Текст выделения и действие сработавшего хоткея.
    var onCapture: ((String, TicketAction) -> Void)?

    private struct Registered {
        let ref: EventHotKeyRef
        let action: TicketAction
    }

    /// Зарегистрированные хоткеи по их `EventHotKeyID.id`.
    private var registered: [UInt32: Registered] = [:]
    private var eventHandler: EventHandlerRef?

    private let signature = fourCharCode("JOPN")

    /// Есть ли разрешение Accessibility. `prompt: true` покажет системный запрос.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Регистрирует комбинацию под уникальным `id`, привязывая к ней действие.
    func register(id: UInt32, action: TicketAction, keyCode: UInt32, modifiers: UInt32) {
        installHandlerIfNeeded()
        guard registered[id] == nil else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[id] = Registered(ref: ref, action: action)
        } else {
            NSLog("Hopkey: не удалось зарегистрировать хоткей id=\(id) (status=\(status)) — комбинация занята?")
        }
    }

    /// Снимает все зарегистрированные хоткеи и обработчик событий.
    func unregisterAll() {
        for entry in registered.values {
            UnregisterEventHotKey(entry.ref)
        }
        registered.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

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
            manager.handleFire(id: hkID.id)
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
    }

    private func handleFire(id: UInt32) {
        guard let action = registered[id]?.action else { return }

        let pasteboard = NSPasteboard.general
        let beforeCount = pasteboard.changeCount

        synthesizeCopy()

        // Небольшая задержка, чтобы целевое приложение успело положить выделение в буфер.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            // Берём текст, только если буфер реально обновился после нашего Cmd+C.
            if pasteboard.changeCount != beforeCount,
               let text = pasteboard.string(forType: .string), !text.isEmpty {
                self.onCapture?(text, action)
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
