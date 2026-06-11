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

    /// Что делает хоткей при срабатывании.
    private enum Behavior {
        /// Синтезировать Cmd+C, прочитать выделение и отдать его в `onCapture` (нужен Accessibility).
        case capture(TicketAction)
        /// Просто вызвать колбэк — например, показать окно (Accessibility не нужен).
        case fire(() -> Void)
    }

    private struct Registered {
        let ref: EventHotKeyRef
        let behavior: Behavior
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

    /// Регистрирует комбинацию под уникальным `id`, привязывая к ней действие над выделением
    /// (синтез Cmd+C → чтение буфера → `onCapture`). Требует Accessibility.
    func register(id: UInt32, action: TicketAction, keyCode: UInt32, modifiers: UInt32) {
        register(id: id, keyCode: keyCode, modifiers: modifiers, behavior: .capture(action))
    }

    /// Регистрирует комбинацию, которая при срабатывании просто вызывает `onFire`
    /// (например, показывает окно). Accessibility не требуется.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        register(id: id, keyCode: keyCode, modifiers: modifiers, behavior: .fire(onFire))
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, behavior: Behavior) {
        installHandlerIfNeeded()
        guard registered[id] == nil else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[id] = Registered(ref: ref, behavior: behavior)
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
        switch registered[id]?.behavior {
        case .fire(let callback):
            callback()
        case .capture(let action):
            capture(action: action)
        case nil:
            break
        }
    }

    private func capture(action: TicketAction) {
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

    /// Снимает текущее выделение синтетическим Cmd+C и ВОЗВРАЩАЕТ прежнее содержимое
    /// буфера на место — выделение в буфере не оседает. Требует Accessibility; без него
    /// буфер не меняется и `completion` получает `nil` (вызывающий откатится к буферу/пустому).
    /// `completion` всегда вызывается на главном потоке.
    func captureSelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let beforeCount = pasteboard.changeCount
        let saved = savedItems(of: pasteboard)

        synthesizeCopy()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            var text: String?
            let changed = pasteboard.changeCount != beforeCount
            if changed, let s = pasteboard.string(forType: .string), !s.isEmpty {
                text = s
            }
            // Возвращаем прежнее содержимое, только если сами его перетёрли своим Cmd+C.
            if changed {
                pasteboard.clearContents()
                if let saved, !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
            completion(text)
        }
    }

    /// Снимок содержимого буфера (копии элементов всех типов) для последующего восстановления.
    private func savedItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            var hasData = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    hasData = true
                }
            }
            return hasData ? copy : nil
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
