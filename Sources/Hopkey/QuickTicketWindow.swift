import AppKit
import HopkeyCore

/// Панель окна ввода: ловит Esc на уровне окна, чтобы закрытие работало независимо
/// от того, где сейчас фокус (поле ввода, радио-кнопка или сама панель).
private final class QuickTicketPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Окно быстрого ручного ввода тикета.
///
/// Пользователь вводит ключ целиком (`PROJ-123`) или только номер (`123`):
/// `↩` открывает тикет, `⌘↩` копирует ссылку, `Esc` закрывает. Если введён один
/// номер, а проектов/префиксов несколько — появляется выбор проекта.
///
/// Само действие (открыть/скопировать) выполняет AppDelegate через `onSubmit`,
/// переиспользуя общий путь `perform(_:on:)`.
final class QuickTicketWindowController: NSWindowController, NSWindowDelegate {

    private let config: JiraConfig
    /// Найденные тикеты и выбранное действие — отдаём наружу.
    var onSubmit: (([TicketMatch], TicketAction) -> Void)?

    private let input = NSTextField()
    private let projectLabel = NSTextField(labelWithString: "Проект:")
    /// Вертикальный список проектов: заголовок + радио-кнопки. Выбор — одним кликом.
    private let projectGroup = NSStackView()
    private var projectRadios: [NSButton] = []
    /// Индекс выбранного проекта в `pickerPairs` — ведём явно, не полагаясь на скан состояния радио.
    private var selectedProjectIndex = 0
    private let messageLabel = NSTextField(labelWithString: "")

    /// Содержимое (поле + список + подсказка) и ряд кнопок — нужны для расчёта высоты окна.
    private let contentStack = NSStackView()
    private let buttonRow = NSStackView()

    /// Пары (проект, префикс) для текущего выбора, в порядке списка.
    private var pickerPairs: [(project: JiraProject, prefix: String)] = []

    init(config: JiraConfig) {
        self.config = config
        let panel = QuickTicketPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Открыть тикет"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
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

        // Кнопка ⌘↩ «Скопировать» — видимая, но без рамки (рядом с основной «Открыть»).
        let copyButton = NSButton(title: "Скопировать", target: self, action: #selector(submitCopy))
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.isBordered = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        // Основная кнопка по умолчанию ловит обычный ↩ даже при фокусе в поле.
        let openButton = NSButton(title: "Открыть", target: self, action: #selector(submitOpen))
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
    func showWindow() {
        let wasVisible = window?.isVisible ?? false
        if !wasVisible {
            input.stringValue = ""
            preparePicker()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !wasVisible { window?.makeFirstResponder(input) }
    }

    // MARK: - Submit

    @objc private func submitOpen() { submit(action: .openInBrowser) }
    @objc private func submitCopy() { submit(action: .copyURL) }

    private func submit(action: TicketAction) {
        switch QuickTicketInput.resolve(input.stringValue, projects: config.projects) {
        case .resolved(let match):
            finish(match, action: action)

        case .needsProject(let number):
            // Полный ключ всегда резолвится напрямую (минуя эту ветку), поэтому сюда
            // попадаем только на чистом номере. Список проектов уже показан (см.
            // `preparePicker`), поэтому одного ↩ хватает — собираем по выбранному.
            resolveWithPicker(number: number, action: action)

        case .empty:
            NSSound.beep()

        case .invalid:
            let hasProjects = config.projects.contains(where: \.isValid)
            showMessage(hasProjects ? "Не похоже на ключ тикета"
                                    : "Сначала добавьте проект в настройках", isError: true)
            NSSound.beep()
        }
    }

    private func resolveWithPicker(number: String, action: TicketAction) {
        guard pickerPairs.indices.contains(selectedProjectIndex) else { NSSound.beep(); return }
        let pair = pickerPairs[selectedProjectIndex]
        guard case let .resolved(match) = QuickTicketInput.resolve(number: number,
                                                                   project: pair.project,
                                                                   prefix: pair.prefix) else {
            showMessage("Не удалось собрать ключ", isError: true)
            NSSound.beep()
            return
        }
        config.lastQuickPrefix = pair.prefix  // запомним выбор для следующего раза
        finish(match, action: action)
    }

    private func finish(_ match: TicketMatch, action: TicketAction) {
        onSubmit?([match], action)
        window?.close()
    }

    // MARK: - Выбор проекта

    /// Готовит выбор проекта при открытии окна. Если валидных пар «проект+префикс»
    /// больше одной, список показывается сразу — чтобы ввод номера и выбор были рядом
    /// и хватало одного ↩. При одной паре (или вводе полного ключа) список не нужен.
    private func preparePicker() {
        pickerPairs = QuickTicketInput.pickerPairs(in: config.projects)

        // Пересобираем радио-кнопки под актуальные проекты (заголовок `projectLabel` оставляем).
        for radio in projectRadios {
            projectGroup.removeArrangedSubview(radio)
            radio.removeFromSuperview()
        }
        // Адрес показываем, только если хосты реально различаются — при едином сервере
        // (типичный случай: одна Jira, разные префиксы) он лишь повторяется и шумит.
        let hosts = pickerPairs.map { host(of: $0.project.baseURL) }
        let showHost = Set(hosts).count > 1
        projectRadios = pickerPairs.enumerated().map { i, pair in
            let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(projectRadioClicked))
            radio.tag = i
            radio.attributedTitle = projectTitle(prefix: pair.prefix, host: showHost ? hosts[i] : nil)
            radio.translatesAutoresizingMaskIntoConstraints = false
            projectGroup.addArrangedSubview(radio)
            return radio
        }
        // Предвыбираем проект, выбранный в прошлый раз; если такого префикса больше нет — первый.
        selectedProjectIndex = pickerPairs.firstIndex { $0.prefix == config.lastQuickPrefix } ?? 0
        if projectRadios.indices.contains(selectedProjectIndex) {
            projectRadios[selectedProjectIndex].state = .on
        }

        let ambiguous = pickerPairs.count > 1
        projectGroup.isHidden = !ambiguous
        showMessage(ambiguous ? "Введите номер и выберите проект · ⌘↩ — скопировать"
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

    /// Выбор проекта. Кликом мыши при уже введённом номере — сразу открываем (один клик
    /// завершает ввод). При выборе с клавиатуры (стрелки) только запоминаем выбор, без
    /// преждевременного открытия — иначе навигация по списку открывала бы тикет на лету.
    @objc private func projectRadioClicked(_ sender: NSButton) {
        selectedProjectIndex = sender.tag
        let isMouse = NSApp.currentEvent.map { $0.type == .leftMouseUp || $0.type == .leftMouseDown } ?? false
        guard isMouse, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submit(action: .openInBrowser)
    }

    private func showMessage(_ text: String, isError: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// Хост из базового URL для подписи радио-кнопки (фолбэк — сам URL).
    private func host(of baseURL: String) -> String {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? baseURL
    }

    /// Подпись радио-кнопки: префикс обычным цветом, адрес сервера (если задан) —
    /// приглушённым, чтобы он не перетягивал внимание с префикса проекта.
    /// Шрифт задаём явно: `attributedTitle` обходит дефолтный шрифт контрола.
    private func projectTitle(prefix: String, host: String?) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = NSMutableAttributedString(
            string: prefix,
            attributes: [.foregroundColor: NSColor.labelColor, .font: font])
        if let host {
            title.append(NSAttributedString(
                string: "  \(host)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font]))
        }
        return title
    }
}
