import AppKit
import HopkeyCore

/// Модальное окно (sheet) создания/редактирования одного шаблона. Все поля шаблона
/// правятся здесь, чтобы таблица настроек оставалась простым списком «для опознания».
///
/// Презентуется через `beginSheet`; по «Сохранить» кладёт готовый шаблон в `result`
/// и закрывает sheet с `.OK`, по «Отмена»/Esc — с `.cancel`.
final class TemplateEditorWindowController: NSWindowController {

    /// Готовый шаблон по «Сохранить» (nil, пока не сохранён/отменён). Читается после закрытия.
    private(set) var result: LinkTemplate?

    private let nameField = NSTextField()
    private let patternField = NSTextField()
    private let urlField = NSTextField()
    private let wholeWordCheck = NSButton(checkboxWithTitle:
        "Границы слова — совпадение не приклеено к буквам/цифрам (PROJ-1, но не XPROJ-1)",
        target: nil, action: nil)
    private let uppercaseCheck = NSButton(checkboxWithTitle:
        "Верхний регистр — нормализовать ключ (proj-7 → PROJ-7)", target: nil, action: nil)
    private let enabledCheck = NSButton(checkboxWithTitle: "Включён", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")

    init(template: LinkTemplate?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 1),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = template == nil ? "Новый шаблон" : "Шаблон"
        super.init(window: window)
        buildUI(template: template ?? LinkTemplate(name: "", pattern: "", url: ""))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI(template: LinkTemplate) {
        guard let window, let content = window.contentView else { return }

        func caption(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }
        func setupField(_ field: NSTextField, _ value: String, _ placeholder: String) {
            field.stringValue = value
            field.placeholderString = placeholder
            field.font = .systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        setupField(nameField, template.name, "Jira")
        setupField(patternField, template.pattern, "PROJ-(\\d+)")
        setupField(urlField, template.url, "https://jira.company.net/browse/PROJ-$1")
        wholeWordCheck.state = template.wholeWord ? .on : .off
        uppercaseCheck.state = template.uppercase ? .on : .off
        enabledCheck.state = template.enabled ? .on : .off
        for c in [wholeWordCheck, uppercaseCheck, enabledCheck] {
            c.translatesAutoresizingMaskIntoConstraints = false
        }

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = 440
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            caption("Имя"), nameField,
            caption("Шаблон (regex) — группы доступны в URL как $1, $2…"), patternField,
            caption("URL — $1 подставляет первую группу (номер), $0 — всё совпадение"), urlField,
            wholeWordCheck, uppercaseCheck, enabledCheck,
            errorLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: nameField)
        stack.setCustomSpacing(12, after: patternField)
        stack.setCustomSpacing(16, after: urlField)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
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
            patternField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
        ])

        content.layoutSubtreeIfNeeded()
        let height = 20 + stack.fittingSize.height + 16 + buttonRow.fittingSize.height + 16
        window.setContentSize(NSSize(width: 480, height: height))
    }

    private func currentTemplate() -> LinkTemplate {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return LinkTemplate(
            name: trim(nameField.stringValue),
            pattern: trim(patternField.stringValue),
            url: trim(urlField.stringValue),
            wholeWord: wholeWordCheck.state == .on,
            uppercase: uppercaseCheck.state == .on,
            enabled: enabledCheck.state == .on)
    }

    @objc private func save() {
        let template = currentTemplate()
        if let problem = template.validation {
            errorLabel.stringValue = Self.message(for: problem)
            return
        }
        result = template
        endSheet(.OK)
    }

    @objc private func cancel() {
        endSheet(.cancel)
    }

    private func endSheet(_ code: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: code)
    }

    private static func message(for problem: LinkTemplate.Invalid) -> String {
        switch problem {
        case .emptyPattern: return "Укажите регулярное выражение."
        case .invalidRegex: return "Регулярное выражение не компилируется — проверьте скобки и экранирование."
        case .emptyURL: return "Укажите URL."
        case .noPlaceholder: return "В URL нужен плейсхолдер: $1 (номер) или $0 (всё совпадение)."
        }
    }
}
