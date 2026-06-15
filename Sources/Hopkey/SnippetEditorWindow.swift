import AppKit
import HopkeyCore

/// Модальное окно (sheet) создания/редактирования одного сниппета.
///
/// Имя видно в списке пикера; значение по умолчанию скрыто (точками) — рядом тумблер
/// «показать», т.к. это может быть пароль. По «Сохранить» кладёт результат в
/// `result` (готовый `Snippet` + значение) и закрывает sheet с `.OK`.
final class SnippetEditorWindowController: NSWindowController, NSTextFieldDelegate {

    /// Результат по «Сохранить»: метаданные + значение. Читается после закрытия sheet.
    private(set) var result: (snippet: Snippet, value: String)?

    /// Редактируемый сниппет (для новой записи — свежий id).
    private let editing: Snippet

    private let nameField = NSTextField()
    /// Два поля значения в одной позиции: защищённое (по умолчанию) и обычное.
    /// Показываем одно за раз, держим их значения в синхроне (см. `controlTextDidChange`).
    private let valueField = NSTextField()
    private let secureValueField = NSSecureTextField()
    private let revealToggle = NSButton(checkboxWithTitle: L("snippet.editor.reveal"), target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")

    init(snippet: Snippet?, value: String) {
        self.editing = snippet ?? Snippet(name: "")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = snippet == nil ? L("snippet.editor.new") : L("snippet.editor.edit")
        super.init(window: window)
        buildUI(value: value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI(value: String) {
        guard let window, let content = window.contentView else { return }

        func caption(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }
        func setupField(_ field: NSTextField, _ string: String, _ placeholder: String) {
            field.stringValue = string
            field.placeholderString = placeholder
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        setupField(nameField, editing.name, L("snippet.editor.name.placeholder"))
        setupField(valueField, value, L("snippet.editor.value.placeholder"))
        setupField(secureValueField, value, L("snippet.editor.value.placeholder"))
        valueField.isHidden = true  // по умолчанию показываем защищённое поле
        // VoiceOver: подписи берём из тех же строк, что и видимые заголовки полей.
        nameField.setAccessibilityLabel(L("snippet.editor.name"))
        valueField.setAccessibilityLabel(L("snippet.editor.value"))
        secureValueField.setAccessibilityLabel(L("snippet.editor.value"))

        // Оба поля значения в одной ячейке-контейнере, друг поверх друга.
        let valueBox = NSView()
        valueBox.translatesAutoresizingMaskIntoConstraints = false
        valueBox.addSubview(secureValueField)
        valueBox.addSubview(valueField)
        for f in [secureValueField, valueField] {
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: valueBox.leadingAnchor),
                f.trailingAnchor.constraint(equalTo: valueBox.trailingAnchor),
                f.topAnchor.constraint(equalTo: valueBox.topAnchor),
                f.bottomAnchor.constraint(equalTo: valueBox.bottomAnchor),
            ])
        }

        revealToggle.state = .off
        revealToggle.target = self
        revealToggle.action = #selector(toggleReveal)
        revealToggle.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = 380
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            caption(L("snippet.editor.name")), nameField,
            caption(L("snippet.editor.value")), valueBox, revealToggle,
            errorLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: nameField)
        stack.setCustomSpacing(6, after: valueBox)
        stack.setCustomSpacing(16, after: revealToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: L("common.cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        let saveButton = NSButton(title: L("common.save"), target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            valueBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
        ])

        content.layoutSubtreeIfNeeded()
        let height = 20 + stack.fittingSize.height + 16 + buttonRow.fittingSize.height + 16
        window.setContentSize(NSSize(width: 420, height: height))
    }

    /// Держит значения защищённого и обычного полей в синхроне, чтобы переключение
    /// «показать» не теряло введённое.
    func controlTextDidChange(_ notification: Notification) {
        guard let edited = notification.object as? NSTextField else { return }
        if edited === secureValueField {
            valueField.stringValue = secureValueField.stringValue
        } else if edited === valueField {
            secureValueField.stringValue = valueField.stringValue
        }
    }

    @objc private func toggleReveal() {
        let show = revealToggle.state == .on
        valueField.isHidden = !show
        secureValueField.isHidden = show
        let active = show ? valueField : secureValueField
        let other = show ? secureValueField : valueField
        active.stringValue = other.stringValue
        window?.makeFirstResponder(active)
    }

    /// Текущее значение из видимого поля (поля синхронизированы).
    private func currentValue() -> String {
        (valueField.isHidden ? secureValueField : valueField).stringValue
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = currentValue()
        if name.isEmpty {
            // Звук + фокус на проблемном поле: красную надпись легко не заметить.
            errorLabel.stringValue = L("snippet.error.emptyName")
            NSSound.beep()
            window?.makeFirstResponder(nameField)
            return
        }
        if value.isEmpty {
            errorLabel.stringValue = L("snippet.error.emptyValue")
            NSSound.beep()
            window?.makeFirstResponder(valueField.isHidden ? secureValueField : valueField)
            return
        }
        result = (Snippet(id: editing.id, name: name), value)
        endSheet(.OK)
    }

    @objc private func cancel() {
        endSheet(.cancel)
    }

    private func endSheet(_ code: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: code)
    }
}
