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
    /// Возвращает `false`, если комбинация занята и зарегистрировать её не удалось.
    @discardableResult
    func register(id: UInt32, action: TicketAction, keyCode: UInt32, modifiers: UInt32) -> Bool {
        register(id: id, keyCode: keyCode, modifiers: modifiers, behavior: .capture(action))
    }

    /// Регистрирует комбинацию, которая при срабатывании просто вызывает `onFire`
    /// (например, показывает окно). Accessibility не требуется.
    /// Возвращает `false`, если комбинация занята и зарегистрировать её не удалось.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) -> Bool {
        register(id: id, keyCode: keyCode, modifiers: modifiers, behavior: .fire(onFire))
    }

    @discardableResult
    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, behavior: Behavior) -> Bool {
        installHandlerIfNeeded()
        guard registered[id] == nil else { return true }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[id] = Registered(ref: ref, behavior: behavior)
            return true
        }
        NSLog("Hopkey: не удалось зарегистрировать хоткей id=\(id) (status=\(status)) — комбинация занята?")
        return false
    }

    /// Системный обработчик Carbon и регистрации хоткеев живут вне жизненного цикла
    /// объекта — если не снять их при уничтожении, они «зависнут» в системе.
    deinit { unregisterAll() }

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
        whenModifiersCleared { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            let beforeCount = pasteboard.changeCount

            self.synthesizeCopy()

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
    }

    /// Биты модификаторов, отпускания которых ждём перед синтезом Cmd+C (⌃⌥⇧⌘).
    /// Caps Lock / Fn не учитываем — иначе ждали бы их отпускания зря.
    private static let watchedModifierMask: UInt64 =
        CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand]).rawValue

    /// Ждёт отпускания зажатых хоткеем модификаторов перед синтезом Cmd+C: иначе они
    /// подмешаются (⌃⌥⌘C вместо ⌘C) и «Копировать» не сработает. Решение о готовности и
    /// поллинг — в `ModifierReleaseWaiter`/`ModifierReleaseGate` (HopkeyCore, под тестами);
    /// сюда внедряем реальный источник флагов и задержку ~20 мс (не дольше ~0.5 c суммарно).
    private lazy var modifierWaiter = ModifierReleaseWaiter(
        gate: ModifierReleaseGate(watched: Self.watchedModifierMask),
        flags: { CGEventSource.flagsState(.combinedSessionState).rawValue },
        schedule: { work in DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work) })

    private func whenModifiersCleared(_ work: @escaping () -> Void) {
        modifierWaiter.wait(work)
    }

    /// Снимает текущее выделение синтетическим Cmd+C и ВОЗВРАЩАЕТ прежнее содержимое
    /// буфера на место — выделение в буфере не оседает. Требует Accessibility; без него
    /// буфер не меняется и `completion` получает `nil` (вызывающий откатится к буферу/пустому).
    /// `completion` всегда вызывается на главном потоке.
    func captureSelection(completion: @escaping (String?) -> Void) {
        whenModifiersCleared {
            let pasteboard = NSPasteboard.general
            let beforeCount = pasteboard.changeCount
            let saved = self.savedItems(of: pasteboard)

            self.synthesizeCopy()

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

    /// Кладёт `text` в буфер и синтезирует Cmd+V — чтобы значение вставилось в поле,
    /// которое сейчас в фокусе (вызывающий заранее вернул фокус целевому приложению).
    /// Перед синтезом ждёт отпускания ⌃⌥⇧⌘ (как `captureSelection`), иначе зажатые
    /// модификаторы хоткея дадут ⌃⌥⌘V вместо ⌘V.
    /// Прежнее содержимое буфера восстанавливается, НО только когда Accessibility выдан
    /// (иначе Cmd+V не сработал — оставляем `text` в буфере как запасной путь для ручного
    /// ⌘V). `completion` всегда вызывается на главном потоке.
    func paste(_ text: String, completion: (() -> Void)? = nil) {
        whenModifiersCleared {
            let pasteboard = NSPasteboard.general
            let saved = self.savedItems(of: pasteboard)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            self.synthesizePaste()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if AXIsProcessTrusted() {
                    pasteboard.clearContents()
                    if let saved, !saved.isEmpty { pasteboard.writeObjects(saved) }
                }
                completion?()
            }
        }
    }

    private func synthesizePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
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
