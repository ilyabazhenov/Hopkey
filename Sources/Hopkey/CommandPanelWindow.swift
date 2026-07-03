import AppKit
import CoreAudio
import HopkeyCore

/// Панель-палитра команд: тумблеры (плитки), разовые действия и сниппеты (строки) на одной
/// поверхности. Вызывается двойным тапом правого ⌘ или левым кликом по иконке. Неактивирующая
/// стеклянная панель в идиоме пикера сниппетов — фокус целевого приложения не теряется, поэтому
/// вставка сниппета/paste попадает туда, где стоял курсор.
private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Контейнер списка: держит фокус клавиатуры, водит выделение (стрелки), выполняет по Enter /
/// цифре 1–9, закрывает по Esc. Индексы совпадают с массивом `entries` контроллера.
private final class CommandListView: NSView {
    var onRun: ((Int) -> Void)?
    var onDigit: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onMove: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 125: onMove?(1)     // ↓
        case 126: onMove?(-1)    // ↑
        case 36, 76: onRun?(-1)  // Return — по текущему выделению
        case 53: onClose?()      // Esc
        default:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty, let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), digit >= 1, digit <= 9 {
                onDigit?(digit)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// Крупная плитка-тумблер: иконка + номер + название + статус, цвет фона кодирует состояние
/// (красный — микрофон замьючен/тревога, янтарный — включённый тумблер, иначе нейтральный).
private final class CommandTileView: NSView {
    enum State { case inactive, active, attention }

    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var state: State = .inactive
    var isSelected = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        iconView.imageScaling = .scaleProportionallyDown
        numberLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        numberLabel.alignment = .right
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)

        for field in [numberLabel, titleLabel, statusLabel] {
            field.isEditable = false; field.isBordered = false; field.drawsBackground = false
        }
        let top = NSStackView(views: [iconView, NSView(), numberLabel])
        top.orientation = .horizontal
        top.alignment = .centerY
        let stack = NSStackView(views: [top, titleLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 78),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func mouseUp(with event: NSEvent) { onClick?() }

    func configure(digit: Int?, symbol: String, title: String, status: String, state: State) {
        self.state = state
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        numberLabel.stringValue = digit.map(String.init) ?? ""
        titleLabel.stringValue = title
        statusLabel.stringValue = status
        setAccessibilityLabel("\(title). \(status)")
        refresh()
    }

    private func refresh() {
        let fill: NSColor
        let stroke: NSColor
        let fg: NSColor
        switch state {
        case .attention:
            fill = NSColor.systemRed.withAlphaComponent(0.14); stroke = .systemRed; fg = .systemRed
        case .active:
            fill = NSColor.controlAccentColor.withAlphaComponent(0.14)
            stroke = .controlAccentColor
            fg = .controlAccentColor
        case .inactive:
            fill = .clear; stroke = .separatorColor; fg = .secondaryLabelColor
        }
        layer?.backgroundColor = fill.cgColor
        iconView.contentTintColor = fg
        numberLabel.textColor = fg
        statusLabel.textColor = fg
        titleLabel.textColor = (state == .inactive) ? .labelColor : fg
        // Выделение с клавиатуры — акцентная рамка поверх состояния.
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : stroke).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
    }
}

/// Нейтральный бейдж номера быстрого выбора (без брендового янтаря) — под «чистое стекло».
private final class NumberBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    var value: String {
        get { label.stringValue }
        set { label.stringValue = newValue; isHidden = newValue.isEmpty }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14).cgColor
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
}

/// Кнопка-иконка с замыканием — вторичные действия сниппета в строке (открыть/скопировать).
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(symbol: String, tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .accessoryBarAction
        contentTintColor = .secondaryLabelColor
        toolTip = tooltip
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
    @objc private func fire() { handler() }
}

/// Строка (действие / лончер / сниппет): номер + иконка + название + трейлинг (хоткей действия
/// или тип сниппета). У сниппетов на hover/выборе трейлинг сменяется кнопками действий.
/// Выделение — нейтральная акцентная заливка, hover — слабая серая.
private final class CommandRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let keycap = NumberBadge()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private var hasActions = false
    private var tracking: NSTrackingArea?

    var isSelected = false { didSet { refreshBackground(); updateActionsVisibility() } }
    private var isHovered = false { didSet { refreshBackground(); updateActionsVisibility() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        keycap.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor

        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        titleLabel.usesSingleLineMode = true; titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        trailingLabel.isEditable = false; trailingLabel.isBordered = false; trailingLabel.drawsBackground = false
        trailingLabel.usesSingleLineMode = true
        trailingLabel.font = .systemFont(ofSize: 12)
        trailingLabel.textColor = .secondaryLabelColor
        trailingLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

        actionsStack.orientation = .horizontal
        actionsStack.spacing = 2
        actionsStack.isHidden = true
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(keycap); addSubview(iconView); addSubview(titleLabel)
        addSubview(trailingLabel); addSubview(actionsStack)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 20),
            keycap.heightAnchor.constraint(equalToConstant: 20),
            iconView.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(digit: Int?, symbol: String, title: String, trailing: String?) {
        keycap.value = digit.map(String.init) ?? ""
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
        trailingLabel.stringValue = trailing ?? ""
    }

    /// Вторичные действия строки (кнопки-иконки), показываются на hover/выборе вместо трейлинга.
    func setActions(_ actions: [(symbol: String, tooltip: String, run: () -> Void)]) {
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            actionsStack.addArrangedSubview(
                ClosureButton(symbol: action.symbol, tooltip: action.tooltip, handler: action.run))
        }
        hasActions = !actions.isEmpty
        updateActionsVisibility()
    }

    private func updateActionsVisibility() {
        let show = hasActions && (isSelected || isHovered)
        actionsStack.isHidden = !show
        trailingLabel.isHidden = show
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private func refreshBackground() {
        let color: NSColor
        if isSelected { color = NSColor.controlAccentColor.withAlphaComponent(0.20) }
        else if isHovered { color = NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
        else { color = .clear }
        layer?.backgroundColor = color.cgColor
    }
}

/// Строка окна истории буфера: номер быстрого выбора + предпросмотр текста, паста-глиф на hover.
private final class HistoryRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let keycap = NumberBadge()
    private let textLabel = NSTextField(labelWithString: "")
    private let pasteIcon = NSImageView()
    private var tracking: NSTrackingArea?

    var isSelected = false { didSet { refresh() } }
    private var isHovered = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        keycap.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.usesSingleLineMode = true
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isEditable = false; textLabel.isBordered = false; textLabel.drawsBackground = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        pasteIcon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        pasteIcon.contentTintColor = .secondaryLabelColor
        pasteIcon.isHidden = true
        pasteIcon.translatesAutoresizingMaskIntoConstraints = false

        addSubview(keycap); addSubview(textLabel); addSubview(pasteIcon)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 20),
            keycap.heightAnchor.constraint(equalToConstant: 20),
            textLabel.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 10),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: pasteIcon.leadingAnchor, constant: -8),
            pasteIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pasteIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pasteIcon.widthAnchor.constraint(equalToConstant: 15),
            pasteIcon.heightAnchor.constraint(equalToConstant: 15),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(digit: Int?, text: String) {
        keycap.value = digit.map(String.init) ?? ""
        textLabel.stringValue = text
        setAccessibilityLabel(text)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private func refresh() {
        let color: NSColor
        if isSelected { color = NSColor.controlAccentColor.withAlphaComponent(0.20) }
        else if isHovered { color = NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
        else { color = .clear }
        layer?.backgroundColor = color.cgColor
        pasteIcon.isHidden = !(isSelected || isHovered)
    }
}


final class CommandPanelWindowController: NSWindowController, NSWindowDelegate {

    /// Действие над сниппетом: первичное (клик/Enter) или вторичное (кнопки в строке).
    var onSnippetActivation: ((Snippet, SnippetActivation) -> Void)?
    /// Панель закрылась (Esc/выбор/клик мимо) — вызывающий сбрасывает состояние жеста-триггера.
    var onClose: (() -> Void)?

    /// Одна выбираемая позиция панели (плитка или строка) в визуальном порядке.
    /// `digit` — номер быстрого выбора 1–9 (nil у истории: она номера не расходует).
    private struct Entry {
        let view: NSView
        let digit: Int?
        let setSelected: (Bool) -> Void
        let run: () -> Void
    }
    private var entries: [Entry] = []
    private var selectedIndex = 0
    private var finished = false
    /// Счётчик присвоенных номеров 1–9.
    private var digitCounter = 0

    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()

    private static let width: CGFloat = 470
    private static let maxHeight: CGFloat = 620

    init() {
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildChrome() {
        guard let window else { return }
        // Весь контент панели живёт в одном контейнере, который кладётся внутрь стекла.
        let content = NSView()
        installGlass(in: window, content: content)

        let header = Brand.makeHeaderView(title: L("panel.title"))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(contentStack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listView
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString: L("panel.footer"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),

            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            listView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -6),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] index in self?.runIndex(index) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onClose = { [weak self] in self?.window?.close() }
    }

    /// Показывает панель. `commands` — команды тулбокса (без лончера сниппетов; сами сниппеты
    /// идут построчно в `snippets`).
    func show(commands: [ToolboxCommand], snippets: [Snippet]) {
        finished = false
        rebuild(commands: commands, snippets: snippets)
        sizeToFit()
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(listView)
    }

    private func rebuild(commands: [ToolboxCommand], snippets: [Snippet]) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
        digitCounter = 0

        let toggles = commands.filter { $0.id.section == .toggles }
        let actions = commands.filter { $0.id.section == .actions || $0.id.section == .launchers }

        // Зона «переключатели» — плитки по две в ряд.
        if !toggles.isEmpty {
            addHeader(L("panel.section.toggles"), trailing: nil)
            var pair: [NSView] = []
            for command in toggles {
                let tile = makeTile(command)
                pair.append(tile)
                if pair.count == 2 { addTileRow(pair); pair = [] }
            }
            if !pair.isEmpty { addTileRow(pair) }
        }

        // Зона «действия» — строки (paste-plain, открыть тикет).
        if !actions.isEmpty {
            addHeader(L("panel.section.actions"), trailing: nil)
            for command in actions { addRow(makeCommandRow(command)) }
        }

        // Зона «сниппеты» — каждый в один клик.
        if !snippets.isEmpty {
            addHeader(L("panel.section.snippets"), trailing: L("panel.snippets.all"))
            for snippet in snippets { addRow(makeSnippetRow(snippet)) }
        }

        // Нумерация 1–9 проставлена при создании строк/плиток (см. nextDigit).
        selectedIndex = entries.isEmpty ? -1 : 0
        updateSelection()
    }

    /// Выдаёт следующий номер 1–9 (или nil за пределами девяти). Историю НЕ нумеруем.
    private func nextDigit() -> Int? {
        guard digitCounter < 9 else { return nil }
        digitCounter += 1
        return digitCounter
    }

    // MARK: Плитки-тумблеры

    private func makeTile(_ command: ToolboxCommand) -> CommandTileView {
        let tile = CommandTileView()
        let on = command.isOn() == true
        // Микрофон в мьюте — тревожно-красный; остальные включённые тумблеры — янтарные.
        let state: CommandTileView.State = on
            ? (command.id == .micToggle ? .attention : .active)
            : .inactive
        let digit = nextDigit()
        tile.configure(digit: digit, symbol: command.symbol(), title: command.title(),
                       status: command.trailing() ?? "", state: state)
        let idx = entries.count
        tile.onClick = { [weak self] in self?.runCommand(command, at: idx) }
        entries.append(Entry(view: tile, digit: digit,
                             setSelected: { [weak tile] in tile?.isSelected = $0 },
                             run: { [weak self] in self?.runCommand(command, at: idx) }))
        return tile
    }

    private func addTileRow(_ tiles: [NSView]) {
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    // MARK: Строки

    private func makeCommandRow(_ command: ToolboxCommand) -> CommandRowView {
        let row = CommandRowView()
        let digit = nextDigit()
        row.configure(digit: digit, symbol: command.symbol(), title: command.title(),
                      trailing: command.trailing())
        let idx = entries.count
        row.onClick = { [weak self] in self?.runCommand(command, at: idx) }
        row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
        entries.append(Entry(view: row, digit: digit,
                             setSelected: { [weak row] in row?.isSelected = $0 },
                             run: { [weak self] in self?.runCommand(command, at: idx) }))
        return row
    }

    private func makeSnippetRow(_ snippet: Snippet) -> CommandRowView {
        let row = CommandRowView()
        let digit = nextDigit()
        row.configure(digit: digit, symbol: Self.snippetSymbol(snippet.kind),
                      title: snippet.displayName, trailing: Self.snippetTypeLabel(snippet.kind))
        // Вторичные действия = доступные, кроме первичного (первичное — по клику/Enter).
        let secondary = snippet.availableActivations.filter { $0 != snippet.primaryActivation }
        row.setActions(secondary.map { activation in
            (symbol: Self.activationSymbol(activation),
             tooltip: Self.activationTooltip(activation),
             run: { [weak self] in self?.finish { self?.onSnippetActivation?(snippet, activation) } })
        })
        row.onClick = { [weak self] in self?.runSnippet(snippet) }
        row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
        entries.append(Entry(view: row, digit: digit,
                             setSelected: { [weak row] in row?.isSelected = $0 },
                             run: { [weak self] in self?.runSnippet(snippet) }))
        return row
    }

    private func addRow(_ row: CommandRowView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// Добавляет заголовок секции в стек и только ПОТОМ вешает ширину (иначе констрейнт с
    /// `contentStack` активируется до появления общего предка → Auto Layout exception).
    private func addHeader(_ text: String, trailing: String?) {
        let header = makeHeader(text, trailing: trailing)
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func makeHeader(_ text: String, trailing: String?) -> NSView {
        let left = NSTextField(labelWithString: text.lowercased())
        left.font = .systemFont(ofSize: 11); left.textColor = .secondaryLabelColor
        left.isEditable = false; left.isBordered = false; left.drawsBackground = false
        left.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(left)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        if let trailing {
            let right = NSTextField(labelWithString: trailing)
            right.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            right.textColor = .secondaryLabelColor
            right.isEditable = false; right.isBordered = false; right.drawsBackground = false
            right.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(right)
            NSLayoutConstraint.activate([
                right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
                right.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            ])
        }
        return container
    }

    // MARK: Выделение и запуск

    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + entries.count) % entries.count
        updateSelection()
        entries[selectedIndex].view.scrollToVisible(entries[selectedIndex].view.bounds)
    }

    private func updateSelection() {
        for (i, entry) in entries.enumerated() { entry.setSelected(i == selectedIndex) }
    }

    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        guard entries.indices.contains(target) else { NSSound.beep(); return }
        entries[target].run()
    }

    /// Быстрый выбор цифрой 1–9: запускаем entry с этим номером (история номеров не имеет).
    private func runDigit(_ digit: Int) {
        guard let entry = entries.first(where: { $0.digit == digit }) else { NSSound.beep(); return }
        entry.run()
    }

    /// Тумблер остаётся в панели (обновляет плитку), лончеры/действия закрывают её.
    private func runCommand(_ command: ToolboxCommand, at index: Int) {
        if command.isOn() != nil {
            command.run()
            refreshTile(command, at: index)
        } else {
            finish { command.run() }
        }
    }

    private func refreshTile(_ command: ToolboxCommand, at index: Int) {
        guard let tile = entries[safe: index]?.view as? CommandTileView else { return }
        let on = command.isOn() == true
        let state: CommandTileView.State = on
            ? (command.id == .micToggle ? .attention : .active)
            : .inactive
        tile.configure(digit: entries[safe: index]?.digit, symbol: command.symbol(),
                       title: command.title(), status: command.trailing() ?? "", state: state)
        tile.isSelected = (index == selectedIndex)
    }

    private func runSnippet(_ snippet: Snippet) {
        finish { [weak self] in self?.onSnippetActivation?(snippet, snippet.primaryActivation) }
    }

    private func finish(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        window?.close()
        action()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Геометрия

    private func sizeToFit() {
        guard let window else { return }
        contentStack.layoutSubtreeIfNeeded()
        let content = contentStack.fittingSize.height + 12  // + верх/низ отступы listView
        let chrome: CGFloat = 36 + 6 + 11 + 10 + 6  // заголовок + зазоры + футер
        let height = min(content + chrome, Self.maxHeight)
        // Сохраняем верхнюю кромку окна — при разворачивании секции панель растёт вниз, не «прыгает».
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(NSSize(width: Self.width, height: height))
        window.setFrameTopLeftPoint(topLeft)
    }

    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    // MARK: Сниппеты — иконки/типы

    private static func snippetSymbol(_ kind: SnippetKind) -> String {
        switch kind {
        case .secret: return "key.fill"
        case .text:   return "text.alignleft"
        case .link:   return "link"
        }
    }

    private static func snippetTypeLabel(_ kind: SnippetKind) -> String {
        switch kind {
        case .secret: return L("snippet.kind.secret")
        case .text:   return L("snippet.kind.text")
        case .link:   return L("snippet.kind.link")
        }
    }

    private static func activationSymbol(_ activation: SnippetActivation) -> String {
        switch activation {
        case .paste: return "arrow.down.doc"
        case .open:  return "arrow.up.right.square"
        case .copy:  return "doc.on.doc"
        }
    }

    private static func activationTooltip(_ activation: SnippetActivation) -> String {
        switch activation {
        case .paste: return L("snippet.picker.paste")
        case .open:  return L("snippet.picker.open")
        case .copy:  return L("snippet.picker.copy")
        }
    }
}

// MARK: - Общее стекло и предпросмотр

/// Оборачивает контент окна в Liquid Glass (macOS 26) или матовое стекло (фолбэк). Переиспользуют
/// панель команд и окно истории буфера.
private func installGlass(in window: NSWindow, content: NSView) {
    window.isOpaque = false
    window.backgroundColor = .clear
    content.translatesAutoresizingMaskIntoConstraints = false
    let container: NSView
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        glass.style = .regular
        glass.tintColor = nil
        glass.contentView = content
        container = glass
    } else {
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.addSubview(content)
        container = backdrop
    }
    window.contentView = container
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        content.topAnchor.constraint(equalTo: container.topAnchor),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
}

/// Однострочный обрезанный предпросмотр значения из истории буфера.
private func historyPreview(_ text: String) -> String {
    let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
}

// MARK: - Обобщённое окно-список (пикер)

/// Обобщённое стеклянное окно-список: заголовок, прокручиваемый список строк с клавнавигацией
/// (стрелки/1–9/Enter/Esc), выделение, пустое состояние, опц. кнопка-корзина в заголовке.
/// Специфику строк (история/трансформации/аудио) дают статические билдеры `Item`.
final class GlassListWindowController: NSWindowController, NSWindowDelegate {

    struct Item {
        let view: NSView
        let digit: Int?
        /// Применимо ли (у трансформации с nil-результатом — false: сигнал, окно остаётся).
        let enabled: Bool
        let setSelected: (Bool) -> Void
        let setOnClick: (@escaping () -> Void) -> Void
        let run: () -> Void
    }

    private let titleKey: String
    private let emptyKey: String?
    private let rowHeight: CGFloat
    private let width: CGFloat
    private let maxHeight: CGFloat
    private var clearHandler: (() -> Void)?

    private var items: [Item] = []
    private var selectedIndex = 0
    private var finished = false
    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var clearButton: ClosureButton?

    init(titleKey: String, emptyKey: String? = nil, rowHeight: CGFloat = 40,
         width: CGFloat = 460, maxHeight: CGFloat = 560) {
        self.titleKey = titleKey
        self.emptyKey = emptyKey
        self.rowHeight = rowHeight
        self.width = width
        self.maxHeight = maxHeight
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 280),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildChrome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Включает кнопку-корзину в заголовке (напр. очистка истории). Клик — `handler` + закрыть.
    func enableClearButton(_ handler: @escaping () -> Void) {
        clearHandler = handler
    }

    private func buildChrome() {
        guard let window else { return }
        let content = NSView()
        installGlass(in: window, content: content)

        let header = Brand.makeHeaderView(title: L(titleKey))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let clear = ClosureButton(symbol: "trash", tooltip: L("panel.clipboard.clear")) { [weak self] in
            self?.clearHandler?()
            self?.window?.close()
        }
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.isHidden = true
        content.addSubview(clear)
        clearButton = clear

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(contentStack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listView
        content.addSubview(scroll)

        emptyLabel.stringValue = emptyKey.map { L($0) } ?? ""
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        let hint = NSTextField(labelWithString: L("panel.footer"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            clear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            listView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] _ in self?.runIndex(-1) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onClose = { [weak self] in self?.window?.close() }
    }

    func show(items: [Item], preselect: Int = 0) {
        finished = false
        self.items = items
        rebuild()
        selectedIndex = items.isEmpty ? -1 : min(max(preselect, 0), items.count - 1)
        updateSelection()
        emptyLabel.isHidden = !items.isEmpty
        clearButton?.isHidden = (clearHandler == nil || items.isEmpty)
        sizeToFit()
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(listView)
    }

    private func rebuild() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            item.setOnClick { [weak self] in self?.runIndex(index) }
            item.view.translatesAutoresizingMaskIntoConstraints = false
            item.view.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            contentStack.addArrangedSubview(item.view)
            item.view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        updateSelection()
        items[selectedIndex].view.scrollToVisible(items[selectedIndex].view.bounds)
    }
    private func updateSelection() {
        for (i, item) in items.enumerated() { item.setSelected(i == selectedIndex) }
    }
    private func runDigit(_ digit: Int) {
        guard let index = items.firstIndex(where: { $0.digit == digit }) else { NSSound.beep(); return }
        runIndex(index)
    }
    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        guard items.indices.contains(target) else { NSSound.beep(); return }
        let item = items[target]
        guard item.enabled else { NSSound.beep(); return }
        finish { item.run() }
    }
    private func finish(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        window?.close()
        action()
    }
    func windowWillClose(_ notification: Notification) {}

    private func sizeToFit() {
        guard let window else { return }
        contentStack.layoutSubtreeIfNeeded()
        let inner = items.isEmpty ? 60 : contentStack.fittingSize.height + 12
        let chrome: CGFloat = 36 + 6 + 11 + 10 + 6
        let height = min(inner + chrome, maxHeight)
        window.setContentSize(NSSize(width: width, height: height))
    }
    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    // MARK: - Билдеры Item

    static func historyItems(_ history: [String], onPaste: @escaping (String) -> Void) -> [Item] {
        history.enumerated().map { index, text in
            let digit = index < 9 ? index + 1 : nil
            let row = HistoryRowView()
            row.configure(digit: digit, text: historyPreview(text))
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            return Item(view: row, digit: digit, enabled: true,
                        setSelected: { [weak row] in row?.isSelected = $0 },
                        setOnClick: { [weak row] handler in row?.onClick = handler },
                        run: { onPaste(text) })
        }
    }

    static func transformItems(source: String, onApply: @escaping (String) -> Void) -> [Item] {
        TextTransform.allCases.enumerated().map { index, transform in
            let digit = index < 9 ? index + 1 : nil
            let result = transform.apply(to: source)
            let row = CommandRowView()
            row.configure(digit: digit, symbol: transformSymbol(transform),
                          title: L(transform.titleKey), trailing: result.map(historyPreview) ?? "—")
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            return Item(view: row, digit: digit, enabled: result != nil,
                        setSelected: { [weak row] in row?.isSelected = $0 },
                        setOnClick: { [weak row] handler in row?.onClick = handler },
                        run: { if let result { onApply(result) } })
        }
    }

    static func audioItems(_ devices: [AudioDevice], currentID: AudioDeviceID?,
                           onPick: @escaping (AudioDeviceID) -> Void) -> (items: [Item], preselect: Int) {
        var preselect = 0
        let items = devices.enumerated().map { index, device -> Item in
            let digit = index < 9 ? index + 1 : nil
            let isCurrent = device.id == currentID
            if isCurrent { preselect = index }
            let row = CommandRowView()
            row.configure(digit: digit, symbol: audioSymbol(device.transport),
                          title: device.name, trailing: isCurrent ? L("audio.current") : nil)
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            return Item(view: row, digit: digit, enabled: true,
                        setSelected: { [weak row] in row?.isSelected = $0 },
                        setOnClick: { [weak row] handler in row?.onClick = handler },
                        run: { onPick(device.id) })
        }
        return (items, preselect)
    }

    private static func transformSymbol(_ t: TextTransform) -> String {
        switch t {
        case .upper, .lower, .title, .camel, .snake, .kebab, .constant, .slug: return "textformat"
        case .trim, .collapseSpaces, .removeEmptyLines, .joinLines: return "wand.and.stars"
        case .jsonPretty, .jsonMinify: return "curlybraces"
        case .urlEncode, .urlDecode: return "link"
        case .base64Encode, .base64Decode: return "barcode"
        case .sortLines, .sortLinesDesc, .dedupeLines, .reverseLines: return "arrow.up.arrow.down"
        }
    }
    private static func audioSymbol(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "speaker.wave.2.fill"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
