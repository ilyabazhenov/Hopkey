import AppKit
import HopkeyCore

/// Панель-палитра команд: вызывается двойным тапом правого ⌘ (или левым кликом по иконке).
/// Неактивирующая стеклянная панель в том же визуальном языке, что пикер сниппетов
/// (`SnippetPickerWindowController`) — переиспользуем уже отполированный вид, а не изобретаем.
/// Команды сгруппированы по зонам (тумблеры / действия / Jira и сниппеты).
private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Контейнер списка: держит фокус клавиатуры, водит выделение стрелками, выполняет по Enter /
/// цифре 1–9, закрывает по Esc. Заголовки секций в `rowViews` не входят — индексы совпадают
/// с массивом команд.
private final class CommandListView: NSView {
    var onRun: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onMove: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 125: onMove?(1)          // ↓
        case 126: onMove?(-1)         // ↑
        case 36, 76: onRun?(-1)       // Return/Enter — по текущему выделению
        case 53: onClose?()           // Esc
        default:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty, let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), digit >= 1, digit <= 9 {
                onRun?(digit - 1)     // 1–9 — прямой выбор N-й команды
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// Строка команды: keycap с номером быстрого выбора + иконка + название + трейлинг
/// (статус тумблера или прямой хоткей). Выделение/hover — мягкая скруглённая заливка бренда.
private final class CommandRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let keycap = KeycapBadge()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    var isSelected = false { didSet { refreshBackground() } }
    private var isHovered = false { didSet { refreshBackground() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        keycap.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        trailingLabel.isEditable = false
        trailingLabel.isBordered = false
        trailingLabel.drawsBackground = false
        trailingLabel.usesSingleLineMode = true
        trailingLabel.font = .systemFont(ofSize: 12)
        trailingLabel.textColor = .secondaryLabelColor
        trailingLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(keycap)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(trailingLabel)
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
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(digit: Int?, symbol: String, title: String, trailing: String?, active: Bool) {
        keycap.value = digit.map(String.init) ?? ""
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.contentTintColor = active ? Brand.accentForeground : .secondaryLabelColor
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
        trailingLabel.stringValue = trailing ?? ""
        trailingLabel.textColor = active ? Brand.accentForeground : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }

    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private func refreshBackground() {
        let color: NSColor
        if isSelected { color = Brand.selectionFill }
        else if isHovered { color = Brand.hoverFill }
        else { color = .clear }
        layer?.backgroundColor = color.cgColor
    }
}

final class CommandPanelWindowController: NSWindowController, NSWindowDelegate {

    /// Исходный набор команд (порядок реестра).
    private var commands: [ToolboxCommand] = []
    /// Команды в визуальном порядке строк (после группировки по секциям) — индексы совпадают
    /// с `rowViews`, выделением, цифрами и кликами.
    private var orderedCommands: [ToolboxCommand] = []
    private var rowViews: [CommandRowView] = []
    private var selectedIndex = 0

    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private var finished = false

    private static let width: CGFloat = 460
    private static let rowHeight: CGFloat = 40

    init() {
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
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
        let backdrop = NSVisualEffectView()
        backdrop.material = .windowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        window.contentView = backdrop
        window.isOpaque = false
        window.backgroundColor = .clear
        Brand.addGlassTint(to: backdrop)

        let header = Brand.makeHeaderView(title: L("panel.title"))
        backdrop.addSubview(header)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(contentStack)
        backdrop.addSubview(listView)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            header.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 9),

            listView.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 36),
            listView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            listView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            listView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -8),

            contentStack.topAnchor.constraint(equalTo: listView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] index in self?.runIndex(index) }
        listView.onClose = { [weak self] in self?.window?.close() }
    }

    /// Показывает панель с актуальным набором команд.
    func show(commands: [ToolboxCommand]) {
        self.commands = commands
        finished = false
        rebuildRows()
        sizeToFit()
        centerOnActiveScreen()

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(listView)
    }

    private func rebuildRows() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        orderedCommands.removeAll()

        for section in CommandSection.allCases {
            let inSection = commands.filter { $0.id.section == section }
            guard !inSection.isEmpty else { continue }
            contentStack.addArrangedSubview(makeHeader(L(section.titleKey)))
            for command in inSection {
                let visualIndex = orderedCommands.count
                orderedCommands.append(command)
                let row = makeRow(command: command, visualIndex: visualIndex,
                                  digit: visualIndex < 9 ? visualIndex + 1 : nil)
                rowViews.append(row)
                contentStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        }
        selectedIndex = rowViews.isEmpty ? -1 : 0
        updateSelection()
    }

    private func makeHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.lowercased())
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    /// `visualIndex` — позиция строки в списке (== индекс в `rowViews`/`orderedCommands`).
    private func makeRow(command: ToolboxCommand, visualIndex: Int, digit: Int?) -> CommandRowView {
        let row = CommandRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        row.configure(digit: digit, symbol: command.symbol(), title: command.title(),
                      trailing: command.trailing(), active: command.isOn() == true)
        row.onClick = { [weak self] in self?.runCommand(at: visualIndex) }
        row.onHover = { [weak self] hovered in self?.hover(rowFor: visualIndex, hovered) }
        return row
    }

    // MARK: - Выделение и запуск

    private func moveSelection(by delta: Int) {
        guard !rowViews.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rowViews.count) % rowViews.count
        updateSelection()
    }

    private func updateSelection() {
        for (i, row) in rowViews.enumerated() { row.isSelected = (i == selectedIndex) }
    }

    private func hover(rowFor index: Int, _ hovered: Bool) {
        guard rowViews.indices.contains(index) else { return }
        rowViews[index].setHovered(hovered)
    }

    /// Запуск по индексу из клавиатуры: -1 = текущее выделение.
    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        runCommand(at: target)
    }

    private func runCommand(at index: Int) {
        guard orderedCommands.indices.contains(index) else { NSSound.beep(); return }
        let command = orderedCommands[index]
        // Тумблер обновляет свою строку и оставляет панель открытой; остальное — закрывает.
        if command.isOn() != nil {
            command.run()
            refreshRow(at: index)
        } else {
            finish { command.run() }
        }
    }

    /// Перечитывает строку после переключения тумблера (состояние/иконка/статус).
    private func refreshRow(at index: Int) {
        guard rowViews.indices.contains(index), orderedCommands.indices.contains(index) else { return }
        let command = orderedCommands[index]
        let digit = index < 9 ? index + 1 : nil
        rowViews[index].configure(digit: digit, symbol: command.symbol(), title: command.title(),
                                  trailing: command.trailing(), active: command.isOn() == true)
    }

    private func finish(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        window?.close()
        action()
    }

    // MARK: - Геометрия

    private func sizeToFit() {
        guard let window else { return }
        contentStack.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        let height = 36 + contentHeight + 8  // полоса заголовка + список + нижний отступ
        window.setContentSize(NSSize(width: Self.width, height: height))
    }

    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                      y: area.midY - size.height / 2))
    }
}
