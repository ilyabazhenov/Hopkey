import AppKit
import HopkeyCore

/// Модальное окно (sheet) создания/редактирования одного сниппета.
///
/// Имя видно в списке пикера; тип (секрет/текст/ссылка) задаёт, как показывать значение:
/// у секрета поле скрыто точками с тумблером «показать», у текста и ссылки — обычное поле.
/// По «Сохранить» кладёт результат в `result` (готовый `Snippet` + значение) и закрывает
/// sheet с `.OK`.
final class SnippetEditorWindowController: NSWindowController, NSTextFieldDelegate {

    /// Результат по «Сохранить»: метаданные + значение. Читается после закрытия sheet.
    private(set) var result: (snippet: Snippet, value: String)?

    /// Редактируемый сниппет (для новой записи — свежий id).
    private let editing: Snippet

    /// Порядок сегментов переключателя типа — он же порядок `SnippetKind.allCases`.
    private static let kinds = SnippetKind.allCases
    /// Порядок сегментов переключателя действия ссылки — `SnippetLinkAction.allCases`.
    private static let linkActions = SnippetLinkAction.allCases

    private let kindControl = NSSegmentedControl()
    /// Действие по умолчанию для ссылки (перейти/скопировать) + его подпись — видны только
    /// когда тип = ссылка.
    private let linkActionControl = NSSegmentedControl()
    private let linkActionCaption = NSTextField(labelWithString: L("snippet.editor.linkAction"))
    private let nameField = NSTextField()
    /// Два поля значения в одной позиции: защищённое (для секрета) и обычное (текст/ссылка).
    /// Показываем одно за раз, держим их значения в синхроне (см. `controlTextDidChange`).
    private let valueField = NSTextField()
    private let secureValueField = NSSecureTextField()
    private let revealToggle = NSButton(checkboxWithTitle: L("snippet.editor.reveal"), target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")

    /// Вертикальный стек полей и ряд кнопок — нужны для пересчёта высоты окна при смене типа
    /// (тумблер «показать» появляется/исчезает, и высота содержимого меняется).
    private var contentStack: NSStackView!
    private var buttonRow: NSStackView!

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
        // Плейсхолдеры (пример имени и значения) зависят от типа — их ставит applyKind().
        setupField(nameField, editing.name, "")
        setupField(valueField, value, "")
        setupField(secureValueField, value, "")
        valueField.isHidden = true  // стартовая раскладка задаётся ниже в applyKind()

        // Переключатель типа: Секрет / Текст / Ссылка. Порядок сегментов = `Self.kinds`.
        configureSegments(kindControl, cases: Self.kinds, selected: editing.kind,
                          labelPrefix: "snippet.kind.")
        kindControl.target = self
        kindControl.action = #selector(kindChanged)

        // Действие по умолчанию для ссылки: Вставить / Перейти / Скопировать.
        configureSegments(linkActionControl, cases: Self.linkActions, selected: editing.linkAction,
                          labelPrefix: "snippet.linkAction.")
        linkActionCaption.font = .systemFont(ofSize: 11)
        linkActionCaption.textColor = .secondaryLabelColor
        linkActionCaption.translatesAutoresizingMaskIntoConstraints = false
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
            caption(L("snippet.editor.kind")), kindControl,
            caption(L("snippet.editor.name")), nameField,
            caption(L("snippet.editor.value")), valueBox, revealToggle,
            linkActionCaption, linkActionControl,
            errorLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: kindControl)
        stack.setCustomSpacing(12, after: nameField)
        stack.setCustomSpacing(6, after: valueBox)
        stack.setCustomSpacing(12, after: revealToggle)
        stack.setCustomSpacing(16, after: linkActionControl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack

        let cancelButton = NSButton(title: L("common.cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        let saveButton = NSButton(title: L("common.save"), target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        // Медово-янтарная основная кнопка, как «Открыть»: единый вид главного действия.
        saveButton.bezelColor = Brand.buttonFill
        saveButton.attributedTitle = NSAttributedString(
            string: L("common.save"),
            attributes: [.foregroundColor: Brand.onAccentText,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        self.buttonRow = buttonRow

        content.addSubview(stack)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            kindControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            linkActionControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            valueBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
        ])

        applyKind()  // стартовая раскладка полей под текущий тип
        resizeToFit()
    }

    /// Подгоняет высоту окна под текущее содержимое (число видимых полей меняется при смене
    /// типа — у секрета есть тумблер «показать», у текста/ссылки нет).
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = 20 + contentStack.fittingSize.height + 16 + buttonRow.fittingSize.height + 16
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

    /// Наполняет сегмент-контрол кейсами enum'а: подписи берутся из локализации по ключу
    /// `labelPrefix + rawValue`, выделяется сегмент текущего значения. Порядок сегментов =
    /// порядок `cases`.
    private func configureSegments<T: Equatable & RawRepresentable>(
        _ control: NSSegmentedControl, cases: [T], selected: T, labelPrefix: String
    ) where T.RawValue == String {
        control.segmentCount = cases.count
        control.segmentDistribution = .fillEqually
        control.trackingMode = .selectOne
        for (i, value) in cases.enumerated() {
            control.setLabel(L("\(labelPrefix)\(value.rawValue)"), forSegment: i)
        }
        control.selectedSegment = cases.firstIndex(of: selected) ?? 0
        control.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Тип, выбранный в переключателе (с защитой от рассинхрона индекса).
    private func currentKind() -> SnippetKind {
        Self.kinds.indices.contains(kindControl.selectedSegment)
            ? Self.kinds[kindControl.selectedSegment] : .secret
    }

    @objc private func kindChanged() {
        applyKind()
        resizeToFit()  // высота зависит от наличия тумблера «показать»
    }

    /// Перестраивает поле значения под текущий тип: секрет — точки + тумблер «показать»;
    /// текст/ссылка — обычное открытое поле (тумблер прячем). Значения полей синхронны.
    private func applyKind() {
        let kind = currentKind()
        let isSecret = kind.isSecret
        revealToggle.isHidden = !isSecret
        // Выбор действия по умолчанию имеет смысл только для ссылки.
        linkActionCaption.isHidden = kind != .link
        linkActionControl.isHidden = kind != .link
        // Секрет показываем по состоянию тумблера; текст и ссылку — всегда открытым полем.
        let showPlain = isSecret ? (revealToggle.state == .on) : true
        valueField.isHidden = !showPlain
        secureValueField.isHidden = showPlain
        let active = showPlain ? valueField : secureValueField
        let other  = showPlain ? secureValueField : valueField
        active.stringValue = other.stringValue
        // Пример имени и значения под выбранный тип (ключи вида ...placeholder.secret/text/link).
        nameField.placeholderString = L("snippet.editor.name.placeholder.\(kind.rawValue)")
        let valuePlaceholder = L("snippet.editor.value.placeholder.\(kind.rawValue)")
        valueField.placeholderString = valuePlaceholder
        secureValueField.placeholderString = valuePlaceholder
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
        let kind = currentKind()
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
        // Ссылку без валидного http(s)-адреса не сохраняем: иначе кнопка «открыть» молча
        // не сработает. Точка нормализации одна и та же, что и при открытии.
        if kind == .link, Snippet.url(forValue: value) == nil {
            errorLabel.stringValue = L("snippet.error.invalidURL")
            NSSound.beep()
            window?.makeFirstResponder(valueField.isHidden ? secureValueField : valueField)
            return
        }
        // linkAction осмыслен только для ссылки; у секрета/текста фиксируем дефолт, чтобы
        // не сохранять «залипшее» в скрытом контроле значение.
        let linkAction: SnippetLinkAction = kind == .link
            && Self.linkActions.indices.contains(linkActionControl.selectedSegment)
            ? Self.linkActions[linkActionControl.selectedSegment] : .open
        result = (Snippet(id: editing.id, name: name, kind: kind, linkAction: linkAction), value)
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
