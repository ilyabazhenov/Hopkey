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

/// Ячейка поля ввода с отступом слева — освобождает место под иконку-ключ внутри поля, не
/// давая тексту (и при наборе, и при выделении) налезать на неё.
private final class IconTextFieldCell: NSTextFieldCell {
    /// Левый отступ под иконку. Совпадает с местом, куда кладём `keyIcon` в `buildUI`.
    var leftInset: CGFloat = 26

    private func inset(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + leftInset, y: rect.minY,
               width: max(0, rect.width - leftInset), height: rect.height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: inset(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView,
                   editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(rect), in: controlView,
                     editor: editor, delegate: delegate, start: start, length: length)
    }
}

/// Поле ввода с иконкой-ключом слева. Просто подменяет класс ячейки на `IconTextFieldCell`.
private final class IconTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { IconTextFieldCell.self }
        set {}
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
final class QuickTicketWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private let config: JiraConfig
    /// Найденные тикеты и выбранное действие — отдаём наружу.
    var onSubmit: (([TicketMatch], TicketAction) -> Void)?

    private let input = IconTextField()
    private let projectLabel = NSTextField(labelWithString: L("quick.templateLabel"))
    /// Вертикальный список шаблонов: заголовок + радио-кнопки. Выбор — одним кликом.
    private let projectGroup = NSStackView()
    private var projectRadios: [NSButton] = []
    /// Индекс выбранного шаблона в `fillableTemplates` — ведём явно, не полагаясь на скан состояния радио.
    private var selectedTemplateIndex = 0
    /// Живое превью итоговой ссылки/строки под полем ввода: показывает, что именно
    /// откроется/скопируется по ↩. Скрыто, пока ввод не резолвится в ссылку.
    private let previewLabel = NSTextField(labelWithString: "")
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
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("quick.window.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // «Жидкое стекло» — единый стиль с пикером сниппетов: матовый фон на всю площадь
        // окна, прозрачный бесшовный заголовок. Тему не фиксируем — стекло адаптивное.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true
        panel.alphaValue = 1.0
        // Без этого панель «принадлежит» Space рабочего стола: при хоткее из чужого
        // фуллскрина macOS выкинула бы пользователя из полноэкранного режима, чтобы
        // показать окно. `.canJoinAllSpaces` показывает панель на активном Space (в т.ч.
        // фуллскрин-Space), `.fullScreenAuxiliary` разрешает рисоваться поверх фуллскрина.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.onCommandReturn = { [weak self] in self?.submit(action: .copyURL) }
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI() {
        guard let window else { return }
        // Матовый фон-стекло на всю площадь окна — тот же приём, что в пикере сниппетов.
        // `.menu` — адаптивный материал (следует светлой/тёмной теме).
        let backdrop = NSVisualEffectView()
        backdrop.material = .windowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        window.contentView = backdrop
        window.isOpaque = false
        window.backgroundColor = .clear
        let content = backdrop

        // Тёплый кремовый тон поверх стекла — фон теплеет под цвет иконки.
        Brand.addGlassTint(to: content)

        // Свой брендовый заголовок: прячем системный текст и рисуем «иконка + название» по
        // центру полосы заголовка — окно узнаётся как Hopkey.
        window.titleVisibility = .hidden
        let header = Brand.makeHeaderView(title: L("quick.window.title"))
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
        ])

        input.placeholderString = L("quick.placeholder")
        input.font = .systemFont(ofSize: 14)
        input.delegate = self  // ловим правки, чтобы обновлять превью на лету
        input.translatesAutoresizingMaskIntoConstraints = false

        // Иконка-ключ внутри поля слева — сразу понятно, что вводим ключ тикета. Текст
        // отступает под неё за счёт `IconTextFieldCell`.
        let keyIcon = NSImageView(image: NSImage(
            systemSymbolName: "key", accessibilityDescription: nil) ?? NSImage())
        keyIcon.contentTintColor = .secondaryLabelColor
        keyIcon.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(keyIcon)
        NSLayoutConstraint.activate([
            keyIcon.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 8),
            keyIcon.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            keyIcon.widthAnchor.constraint(equalToConstant: 14),
            keyIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        // Превью итоговой ссылки: одна строка, длинный URL сокращаем посередине
        // (домен и хвост важнее середины), полный текст — во всплывающей подсказке.
        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.maximumNumberOfLines = 1
        previewLabel.isSelectable = true  // можно выделить и скопировать ссылку вручную
        previewLabel.isHidden = true
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

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
        let copyButton = NSButton(title: L("quick.copy"), target: self, action: #selector(submitCopy))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("quick.copy"))
        copyButton.imagePosition = .imageLeading
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        // Основная кнопка по умолчанию ловит обычный ↩ даже при фокусе в поле.
        let openButton = NSButton(title: L("quick.open"), target: self, action: #selector(submitOpen))
        openButton.imagePosition = .imageLeading
        openButton.keyEquivalent = "\r"
        // Янтарь бренда вместо системно-синей кнопки по умолчанию. Тёмный титул и иконка —
        // светлый янтарь сам по себе низкоконтрастен с белым.
        openButton.bezelColor = Brand.buttonFill
        openButton.attributedTitle = NSAttributedString(
            string: L("quick.open"),
            attributes: [.foregroundColor: Brand.onAccentText,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        // Иконку красим в тот же адаптивный цвет и делаем НЕ-шаблонной: у дефолтной кнопки
        // macOS иначе перетинтит шаблонную иконку в белый (как у эмфазной синей), и она
        // разойдётся по цвету с титулом.
        openButton.image = NSImage(systemSymbolName: "arrow.up.right.square",
                                   accessibilityDescription: L("quick.open"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Brand.onAccentText]))
        openButton.image?.isTemplate = false
        openButton.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.setViews([copyButton, openButton], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        contentStack.setViews([input, previewLabel, projectGroup, messageLabel], in: .leading)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentStack)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            // Отступ сверху освобождает прозрачную полосу заголовка (с кнопками окна).
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            input.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 12),
        ])
    }

    /// Показывает окно поверх остальных и ставит фокус в поле ввода.
    /// Приложение работает как `.accessory`, поэтому без `NSApp.activate` панель
    /// не получит клавиатурный фокус (тот же приём, что и в окне настроек).
    /// - Parameter prefill: текст для подстановки в поле при открытии (например, голое число
    ///   из выделения/буфера).
    ///
    /// Свежий непустой префилл подставляем всегда — в том числе когда окно уже открыто
    /// (пользователь выделил другой текст и повторил хоткей: ожидается, что в поле окажется
    /// новое выделение, а не старое). Если же окно уже открыто, а нового префилла нет
    /// (пустой/nil) — сохраняем то, что пользователь успел ввести вручную, и не сбрасываем.
    func showWindow(prefill: String? = nil) {
        let wasVisible = window?.isVisible ?? false
        let hasPrefill = !(prefill ?? "").isEmpty
        let applyPrefill = !wasVisible || hasPrefill
        if applyPrefill {
            input.stringValue = prefill ?? ""
            preparePicker()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if applyPrefill {
            window?.makeFirstResponder(input)
            // Подставленное выделяем: ↩ откроет сразу, а ввод цифр заменит его.
            if hasPrefill { input.selectText(nil) }
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
            showMessage(hasTemplates ? L("quick.notKey")
                                     : L("quick.noTemplates"), isError: true)
            NSSound.beep()
        }
    }

    private func resolveWithPicker(number: String, action: TicketAction) {
        guard fillableTemplates.indices.contains(selectedTemplateIndex) else { NSSound.beep(); return }
        let template = fillableTemplates[selectedTemplateIndex]
        guard case let .resolved(match) = QuickTicketInput.resolve(number: number, template: template) else {
            showMessage(L("quick.buildFailed"), isError: true)
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

    // MARK: - Превью ссылки

    /// Обновляет строку превью под полем. Показывает ровно то, что соберётся по ↩
    /// для текущего ввода и выбранного шаблона; если ввод не резолвится — прячет строку.
    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    private func updatePreview() {
        let wasHidden = previewLabel.isHidden
        if let link = previewLink() {
            previewLabel.stringValue = link
            previewLabel.toolTip = link  // полный URL по наведению, когда строка обрезана
            previewLabel.isHidden = false
        } else {
            previewLabel.stringValue = ""
            previewLabel.toolTip = nil
            previewLabel.isHidden = true
        }
        // Появление/исчезновение строки меняет высоту окна. Когда строка уже видна
        // и меняется лишь её текст, высота прежняя — не дёргаем размер на каждом нажатии.
        if previewLabel.isHidden != wasHidden { sizeWindowToFit() }
    }

    /// Итоговая ссылка для текущего состояния поля и выбора шаблона, или `nil`,
    /// если ввод пока не складывается в ссылку. Та же логика, что и при submit.
    private func previewLink() -> String? {
        switch QuickTicketInput.resolve(input.stringValue, templates: config.templates) {
        case .resolved(let match):
            return match.url.absoluteString
        case .needsTemplate(let number):
            guard fillableTemplates.indices.contains(selectedTemplateIndex),
                  case let .resolved(match) = QuickTicketInput.resolve(
                    number: number, template: fillableTemplates[selectedTemplateIndex])
            else { return nil }
            return match.url.absoluteString
        case .empty, .invalid:
            return nil
        }
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
        showMessage(ambiguous ? L("quick.hint.ambiguous")
                              : L("quick.hint.simple"), isError: false)
        updatePreview()
        sizeWindowToFit()
    }

    /// Высота окна — под фактический контент (поле + список + подсказка + кнопки),
    /// чтобы не подгонять магические числа под метрики контролов вручную.
    private func sizeWindowToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = 36 + contentStack.fittingSize.height + 12 + buttonRow.fittingSize.height + 16
        window.setContentSize(NSSize(width: 380, height: height))
        centerOnActiveScreen()
    }

    /// Центрирует окно на экране, где сейчас курсор, — там внимание пользователя.
    /// `window.center()` всегда брал бы `NSScreen.main` (экран с меню-баром), из-за чего
    /// при мультимониторе/фуллскрине на втором дисплее окно появлялось не на том экране.
    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2))
    }

    /// Выбор шаблона — только запоминаем. Открытие/копирование делается кнопками
    /// (или ↩ / ⌘↩), а не самим кликом по радио.
    @objc private func projectRadioClicked(_ sender: NSButton) {
        selectedTemplateIndex = sender.tag
        updatePreview()  // превью зависит от выбранного шаблона
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
