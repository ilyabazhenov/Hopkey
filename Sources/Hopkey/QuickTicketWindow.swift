import AppKit
import HopkeyCore

/// Панель окна ввода: ловит Esc на уровне окна, чтобы закрытие работало независимо
/// от того, где сейчас фокус (поле ввода, радио-кнопка или сама панель). Также ловит
/// ⌘↩ для «скопировать» — так кнопка остаётся обычной (серой), а не второй синей.
private final class QuickTicketPanel: NSPanel {
    var onCommandReturn: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let onlyCommand = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask) == .command
        if onlyCommand, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Окно быстрого ручного ввода тикета.
///
/// Пользователь вводит ключ целиком (`PROJ-123`, `#42`) или только номер (`123`):
/// `↩` открывает тикет, `⌘↩` копирует ссылку, `Esc` закрывает. Если введён один
/// номер, а заполнимых шаблонов несколько — появляется выбор шаблона.
///
/// Само действие (открыть/скопировать) выполняет AppDelegate через `onSubmit`,
/// переиспользуя общий путь `perform(_:on:)`.
final class QuickTicketWindowController: NSWindowController, NSWindowDelegate {

    private let config: JiraConfig
    /// Найденные тикеты и выбранное действие — отдаём наружу.
    var onSubmit: (([TicketMatch], TicketAction) -> Void)?

    private let input = NSTextField()
    private let projectLabel = NSTextField(labelWithString: "Шаблон:")
    /// Вертикальный список шаблонов: заголовок + радио-кнопки. Выбор — одним кликом.
    private let projectGroup = NSStackView()
    private var projectRadios: [NSButton] = []
    /// Индекс выбранного шаблона в `fillableTemplates` — ведём явно, не полагаясь на скан состояния радио.
    private var selectedTemplateIndex = 0
    private let messageLabel = NSTextField(labelWithString: "")

    /// Содержимое (поле + список + подсказка) и ряд кнопок — нужны для расчёта высоты окна.
    private let contentStack = NSStackView()
    private let buttonRow = NSStackView()

    /// Заполнимые числом шаблоны для текущего выбора, в порядке конфига.
    private var fillableTemplates: [LinkTemplate] = []

    init(config: JiraConfig) {
        self.config = config
        let panel = QuickTicketPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Открыть по ключу"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        panel.onCommandReturn = { [weak self] in self?.submit(action: .copyURL) }
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        input.placeholderString = "PROJ-123 или 123"
        input.font = .systemFont(ofSize: 14)
        input.translatesAutoresizingMaskIntoConstraints = false

        projectLabel.translatesAutoresizingMaskIntoConstraints = false
        // Заголовок + радио-кнопки в столбик. Сами кнопки добавляются в `preparePicker`.
        projectGroup.orientation = .vertical
        projectGroup.alignment = .leading
        projectGroup.spacing = 4
        projectGroup.translatesAutoresizingMaskIntoConstraints = false
        projectGroup.isHidden = true
        projectGroup.addArrangedSubview(projectLabel)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        // «Скопировать» — обычная серая кнопка. Шорткат ⌘↩ ловит сама панель
        // (см. `performKeyEquivalent`), чтобы кнопка не стала второй синей «по умолчанию».
        let copyButton = NSButton(title: "Скопировать", target: self, action: #selector(submitCopy))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        // Основная кнопка по умолчанию ловит обычный ↩ даже при фокусе в поле.
        let openButton = NSButton(title: "Открыть", target: self, action: #selector(submitOpen))
        openButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeading
        openButton.keyEquivalent = "\r"
        openButton.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.setViews([copyButton, openButton], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        contentStack.setViews([input, projectGroup, messageLabel], in: .leading)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentStack)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            input.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 12),
        ])
    }

    /// Показывает окно поверх остальных и ставит фокус в поле ввода.
    /// Приложение работает как `.accessory`, поэтому без `NSApp.activate` панель
    /// не получит клавиатурный фокус (тот же приём, что и в окне настроек).
    /// Если окно уже открыто (повторное нажатие хоткея) — не сбрасываем введённое.
    /// - Parameter prefill: текст для подстановки в поле при открытии (например, голое число
    ///   из выделения/буфера). Подставляется только когда окно открывается заново.
    func showWindow(prefill: String? = nil) {
        let wasVisible = window?.isVisible ?? false
        if !wasVisible {
            input.stringValue = prefill ?? ""
            preparePicker()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !wasVisible {
            window?.makeFirstResponder(input)
            // Подставленное выделяем: ↩ откроет сразу, а ввод цифр заменит его.
            if !(prefill ?? "").isEmpty { input.selectText(nil) }
        }
    }

    // MARK: - Submit

    @objc private func submitOpen() { submit(action: .openInBrowser) }
    @objc private func submitCopy() { submit(action: .copyURL) }

    private func submit(action: TicketAction) {
        switch QuickTicketInput.resolve(input.stringValue, templates: config.templates) {
        case .resolved(let match):
            finish(match, action: action)

        case .needsTemplate(let number):
            // Полный ключ всегда резолвится напрямую (минуя эту ветку), поэтому сюда
            // попадаем только на чистом номере. Список шаблонов уже показан (см.
            // `preparePicker`), поэтому одного ↩ хватает — собираем по выбранному.
            resolveWithPicker(number: number, action: action)

        case .empty:
            NSSound.beep()

        case .invalid:
            let hasTemplates = config.templates.contains(where: \.isValid)
            showMessage(hasTemplates ? "Не похоже на ключ"
                                     : "Сначала добавьте шаблон в настройках", isError: true)
            NSSound.beep()
        }
    }

    private func resolveWithPicker(number: String, action: TicketAction) {
        guard fillableTemplates.indices.contains(selectedTemplateIndex) else { NSSound.beep(); return }
        let template = fillableTemplates[selectedTemplateIndex]
        guard case let .resolved(match) = QuickTicketInput.resolve(number: number, template: template) else {
            showMessage("Не удалось собрать ключ", isError: true)
            NSSound.beep()
            return
        }
        config.lastQuickTemplate = template.displayName  // запомним выбор для следующего раза
        finish(match, action: action)
    }

    private func finish(_ match: TicketMatch, action: TicketAction) {
        onSubmit?([match], action)
        window?.close()
    }

    // MARK: - Выбор шаблона

    /// Готовит выбор шаблона при открытии окна. Если заполнимых числом шаблонов
    /// больше одного, список показывается сразу — чтобы ввод номера и выбор были рядом
    /// и хватало одного ↩. При одном шаблоне (или вводе полного ключа) список не нужен.
    private func preparePicker() {
        fillableTemplates = QuickTicketInput.fillableTemplates(in: config.templates)

        // Пересобираем радио-кнопки под актуальные шаблоны (заголовок `projectLabel` оставляем).
        for radio in projectRadios {
            projectGroup.removeArrangedSubview(radio)
            radio.removeFromSuperview()
        }
        // Паттерн показываем как приглушённую подсказку, только если он отличается от имени
        // (иначе при name == pattern он лишь повторяется и шумит).
        projectRadios = fillableTemplates.enumerated().map { i, template in
            let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(projectRadioClicked))
            radio.tag = i
            let hint = template.name == template.pattern ? nil : template.pattern
            radio.attributedTitle = templateTitle(name: template.displayName, hint: hint)
            radio.translatesAutoresizingMaskIntoConstraints = false
            projectGroup.addArrangedSubview(radio)
            return radio
        }
        // Предвыбор: если в поле уже лежит текст, целиком совпадающий с шаблоном (выделили
        // полный ключ вроде ONECOLLECT-123) — сразу выбираем его, экономя клик. Иначе —
        // шаблон из прошлого раза, иначе первый.
        let current = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, let i = fillableTemplates.firstIndex(where: { $0.matchesWhole(current) }) {
            selectedTemplateIndex = i
        } else {
            selectedTemplateIndex = fillableTemplates.firstIndex { $0.displayName == config.lastQuickTemplate } ?? 0
        }
        if projectRadios.indices.contains(selectedTemplateIndex) {
            projectRadios[selectedTemplateIndex].state = .on
        }

        let ambiguous = fillableTemplates.count > 1
        projectGroup.isHidden = !ambiguous
        showMessage(ambiguous ? "Введите номер и выберите шаблон · ⌘↩ — скопировать"
                              : "↩ — открыть · ⌘↩ — скопировать ссылку", isError: false)
        sizeWindowToFit()
    }

    /// Высота окна — под фактический контент (поле + список + подсказка + кнопки),
    /// чтобы не подгонять магические числа под метрики контролов вручную.
    private func sizeWindowToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = 20 + contentStack.fittingSize.height + 12 + buttonRow.fittingSize.height + 16
        window.setContentSize(NSSize(width: 380, height: height))
        window.center()
    }

    /// Выбор шаблона — только запоминаем. Открытие/копирование делается кнопками
    /// (или ↩ / ⌘↩), а не самим кликом по радио.
    @objc private func projectRadioClicked(_ sender: NSButton) {
        selectedTemplateIndex = sender.tag
    }

    private func showMessage(_ text: String, isError: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// Подпись радио-кнопки: имя шаблона обычным цветом, паттерн (если отличается) —
    /// приглушённым, чтобы он не перетягивал внимание с имени.
    /// Шрифт задаём явно: `attributedTitle` обходит дефолтный шрифт контрола.
    private func templateTitle(name: String, hint: String?) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.foregroundColor: NSColor.labelColor, .font: font])
        if let hint {
            title.append(NSAttributedString(
                string: "  \(hint)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font]))
        }
        return title
    }
}
