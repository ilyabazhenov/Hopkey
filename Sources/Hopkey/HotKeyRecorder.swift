import AppKit
import Carbon.HIToolbox
import HopkeyCore

/// Поле-рекордер: по клику переходит в режим записи и ждёт нажатия комбинации.
/// Принимает только комбинации хотя бы с одним модификатором (иначе перехват
/// ломал бы обычный ввод). Результат отдаёт в `onChange` в Carbon-формате.
final class HotKeyRecorderView: NSView {

    /// Вызывается при выборе новой комбинации: keyCode + модификаторы (Carbon).
    var onChange: ((_ keyCode: UInt32, _ modifiers: UInt32) -> Void)?

    /// Текущая комбинация. Установка извне обновляет подпись (без вызова `onChange`).
    var combo: (keyCode: UInt32, modifiers: UInt32) = (0, 0) {
        didSet { updateTitle() }
    }

    /// Выключённый рекордер не реагирует на клики и приглушён — используется,
    /// когда глобальный хоткей отключён и комбинация ни на что не влияет.
    var isEnabled = true {
        didSet {
            if !isEnabled, isRecording {
                isRecording = false
                window?.makeFirstResponder(nil)
            }
            updateTitle()
            needsDisplay = true
        }
    }

    private var isRecording = false {
        didSet {
            updateTitle()
            needsDisplay = true
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .labelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Esc — отмена записи без изменений.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let carbon = carbonModifiers(from: event.modifierFlags)
        // Требуем хотя бы один значимый модификатор.
        guard carbon != 0 else {
            NSSound.beep()
            return
        }

        let keyCode = UInt32(event.keyCode)
        combo = (keyCode, carbon)
        onChange?(keyCode, carbon)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        if isRecording {
            label.stringValue = L("hotkey.recording")
            label.textColor = .secondaryLabelColor
        } else if combo.keyCode == 0 && combo.modifiers == 0 {
            label.stringValue = L("hotkey.unset")
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = hotKeyDisplayString(keyCode: combo.keyCode, modifiers: combo.modifiers)
            label.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let borderColor: NSColor
        if !isEnabled {
            borderColor = .quaternaryLabelColor
        } else {
            borderColor = isRecording ? .controlAccentColor : .separatorColor
        }
        layer?.borderColor = borderColor.cgColor
    }
}

/// Переводит Cocoa-флаги модификаторов в Carbon-формат (для RegisterEventHotKey).
/// Зависит от AppKit, поэтому остаётся в app-таргете; форматирование строки —
/// в HopkeyCore (`hotKeyDisplayString`).
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    return result
}
