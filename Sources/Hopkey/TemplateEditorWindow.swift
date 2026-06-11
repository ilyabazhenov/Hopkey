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
    private let wholeWordCheck = NSButton(checkboxWithTitle: L("template.wholeWord"), target: nil, action: nil)
    private let uppercaseCheck = NSButton(checkboxWithTitle: L("template.uppercase"), target: nil, action: nil)
    private let enabledCheck = NSButton(checkboxWithTitle: L("template.enabled"), target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")

    /// Поповер-шпаргалка по полям (что такое \d+, (…), $1/$0, границы слова, регистр)
    /// с готовым примером. Создаётся один раз при первом показе.
    private lazy var helpPopover: NSPopover = {
        let title = NSTextField(labelWithString: L("template.help.title"))
        title.font = .boldSystemFont(ofSize: 13)
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: L("template.help.body"))
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = 360
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        container.layoutSubtreeIfNeeded()

        let vc = NSViewController()
        vc.view = container
        let popover = NSPopover()
        popover.behavior = .transient  // закрывается кликом вне поповера
        popover.contentViewController = vc
        popover.contentSize = container.fittingSize
        return popover
    }()

    init(template: LinkTemplate?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 1),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = template == nil ? L("template.window.new") : L("template.window.edit")
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
        // Серый пример под полем: подсказывает формат, не мешая значению. `mono` —
        // для строк-кодов (regex/URL), чтобы примеры читались как то, что нужно ввести.
        func example(_ text: String, mono: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = mono ? .monospacedSystemFont(ofSize: 10, weight: .regular) : .systemFont(ofSize: 10)
            l.textColor = .tertiaryLabelColor
            l.isSelectable = false
            l.preferredMaxLayoutWidth = 440
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

        let nameHint = example(L("template.hint.name"))
        let patternHint = example(L("template.hint.pattern"), mono: true)
        let urlHint = example(L("template.hint.url"), mono: true)

        let stack = NSStackView(views: [
            caption(L("template.field.name")), nameField, nameHint,
            caption(L("template.field.pattern")), patternField, patternHint,
            caption(L("template.field.url")), urlField, urlHint,
            wholeWordCheck, uppercaseCheck, enabledCheck,
            errorLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // Поле и его пример держим тесной парой (3pt), а перед следующей подписью — воздух.
        stack.setCustomSpacing(3, after: nameField)
        stack.setCustomSpacing(12, after: nameHint)
        stack.setCustomSpacing(3, after: patternField)
        stack.setCustomSpacing(12, after: patternHint)
        stack.setCustomSpacing(3, after: urlField)
        stack.setCustomSpacing(16, after: urlHint)
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

        // Круглая «?» у нижнего ряда кнопок: по клику — поповер-шпаргалка по полям.
        let helpButton = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        helpButton.bezelStyle = .helpButton
        helpButton.toolTip = L("template.help.button.tooltip")
        helpButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        content.addSubview(buttonRow)
        content.addSubview(helpButton)
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
            helpButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            helpButton.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
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

    @objc private func showHelp(_ sender: NSButton) {
        helpPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func endSheet(_ code: NSApplication.ModalResponse) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: code)
    }

    private static func message(for problem: LinkTemplate.Invalid) -> String {
        switch problem {
        case .emptyPattern: return L("template.error.emptyPattern")
        case .invalidRegex: return L("template.error.invalidRegex")
        case .emptyURL: return L("template.error.emptyURL")
        case .noPlaceholder: return L("template.error.noPlaceholder")
        }
    }
}
