import AppKit
import HopkeyCore

/// Панель пикера: ловит Esc на уровне окна (закрытие работает независимо от фокуса).
/// Неактивирующая — становится ключевой для клавиатуры/кликов, НЕ активируя наше
/// `.accessory`-приложение. Так прежнее приложение не теряет фокус, и синтетический
/// Cmd+V после выбора попадает прямо в поле, где стоял курсор.
private final class SnippetPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Таблица сниппетов: ↩/Enter подтверждают выбранную строку, цифра 1–9 — быстрый выбор
/// соответствующего сниппета, Esc отдаём панели (закрытие).
private final class SnippetTableView: NSTableView {
    var onConfirm: (() -> Void)?
    var onDigit: ((Int) -> Void)?
    /// Строка под курсором (или -1, если курсор вне строк) — для hover-подсветки.
    var onHover: ((Int) -> Void)?

    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTracking { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { onHover?(-1) }

    override func keyDown(with event: NSEvent) {
        // Цифра без модификаторов — быстрый выбор N-го сниппета.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), digit >= 1, digit <= SnippetQuickSelect.maxDigits {
            onDigit?(digit)
            return
        }
        switch Int(event.keyCode) {
        case 36, 76:  // Return / keypad Enter
            onConfirm?()
        default:
            super.keyDown(with: event)  // в т.ч. Esc (53) → cancelOperation панели
        }
    }
}

/// Строка списка: имя слева + иконка-кнопка «скопировать» справа. Имя — некликабельная
/// метка, поэтому клик по строке доходит до таблицы (→ вставка), а клик по кнопке
/// обрабатывает сама кнопка (→ копирование), без конфликта действий.
private final class SnippetRowView: NSView {
    /// Номер для быстрого выбора (1–9) в виде брендового колпачка клавиши; пусто для строк
    /// за пределами девяти.
    let indexBadge = KeycapBadge()
    let nameField = NSTextField(labelWithString: "")
    let copyButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        indexBadge.translatesAutoresizingMaskIntoConstraints = false

        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                   accessibilityDescription: L("snippet.picker.copy"))
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = L("snippet.picker.copy")
        copyButton.setButtonType(.momentaryChange)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indexBadge)
        addSubview(nameField)
        addSubview(copyButton)
        NSLayoutConstraint.activate([
            // Отступы больше скругления выделения (dx:6 в SnippetRowBackground), иначе текст
            // и иконка вылезают за края скруглённой подсветки и кажутся подрезанными.
            indexBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            indexBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexBadge.widthAnchor.constraint(equalToConstant: 20),
            indexBadge.heightAnchor.constraint(equalToConstant: 20),
            nameField.leadingAnchor.constraint(equalTo: indexBadge.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
}

/// Фон строки: мягкое скруглённое выделение с лёгким оттенком акцента вместо тяжёлой
/// сплошной синей заливки — чтобы вписаться в «стеклянный» вид.
private final class SnippetRowBackground: NSTableRowView {
    /// Курсор над строкой — рисуем слабую янтарную подсветку (слабее выделения).
    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    // Выделение заливаем мягким янтарём (не сплошным синим), поэтому НЕ даём AppKit
    // перекрашивать текст ячеек в «эмфазный» белый: на светлой заливке он тонет. `.normal`
    // оставляет имя сниппета тёмным независимо от выделения.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// Скруглённая «пилюля» под строку — общая геометрия для выделения и hover.
    private func rowPath() -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // Hover показываем только на невыбранной строке: на выбранной поверх рисуется выделение.
        guard isHovered, !isSelected else { return }
        Brand.hoverFill.setFill()
        rowPath().fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Янтарный оттенок бренда вместо системного синего — мягкая заливка под «стекло».
        Brand.selectionFill.setFill()
        rowPath().fill()
    }
}

/// Окно-пикер сниппетов: по хоткею показывает список заранее заданных значений.
/// Клик по строке (или ↩ по выделенной) — вставить в активное поле (`onPick`); кнопка
/// «скопировать» в строке — положить значение в буфер (`onCopy`); Esc закрывает.
/// Окно можно ресайзить, размер запоминается.
///
/// Саму вставку/копирование (Keychain → буфер → Cmd+V) делает AppDelegate — окно лишь
/// показывает имена и сообщает выбранное действие.
final class SnippetPickerWindowController: NSWindowController, NSWindowDelegate,
                                           NSTableViewDataSource, NSTableViewDelegate {

    private let store: SnippetStore
    /// Выбран сниппет для вставки.
    var onPick: ((Snippet) -> Void)?
    /// Выбран сниппет для копирования в буфер (без вставки).
    var onCopy: ((Snippet) -> Void)?

    private let tableView = SnippetTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L("snippet.picker.empty"))
    /// Иконка-кролик над текстом пустого состояния.
    private let emptyIcon = NSImageView()
    /// Иконка + текст пустого состояния в столбик — показываем, когда сниппетов нет.
    private let emptyStack = NSStackView()
    private let hintLabel = NSTextField(labelWithString: L("snippet.picker.hint"))

    /// Текущий список (снимок на момент показа).
    private var snippets: [Snippet] = []
    /// Строка под курсором для hover-подсветки (-1 — нет).
    private var hoveredRow = -1
    /// Защита от двойного действия за один показ (клик по кнопке и по строке и т.п.).
    private var finished = false

    private static let rowID = NSUserInterfaceItemIdentifier("snippetRow")
    private static let defaultWidth: CGFloat = 360
    private static let rowHeight: CGFloat = 36
    /// Сколько строк показываем без прокрутки при авторазмере — дальше скролл.
    private static let maxVisibleRows = 8
    /// Ключ для запоминания ширины окна (высота всегда под содержимое).
    private static let sizeKeyW = "snippetPicker.width"

    init(store: SnippetStore) {
        self.store = store
        let panel = SnippetPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 200),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("snippet.picker.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // «Жидкое стекло»: матовый фон занимает всю площадь окна, заголовок — прозрачный
        // поверх него (без отдельной непрозрачной полосы). Тему НЕ фиксируем — стекло
        // следует системной (светлеет в светлой теме, темнеет в тёмной), иначе тёмное
        // окно выглядит чужеродным пятном на светлом фоне.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true
        // Лёгкая прозрачность всего окна поверх размытия — «жидкое стекло» становится
        // чуть более сквозным. Ниже ~0.85 текст начинает блёкнуть.
        panel.alphaValue = 1.0
        panel.minSize = NSSize(width: 260, height: 110)
        // Те же причины, что и у окна ввода: показываем панель на активном Space
        // (в т.ч. фуллскрин) поверх чужого полноэкранного окна, не выкидывая из него.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI() {
        guard let window else { return }

        // Полупрозрачный фон с размытием — как у Spotlight: панель «вписывается» поверх
        // того, что под ней. `.menu` — translucent и АДАПТИВНЫЙ (в отличие от вечно
        // тёмного `.hudWindow`): в светлой теме фон светлый, в тёмной — тёмный.
        let backdrop = NSVisualEffectView()
        backdrop.material = .windowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        window.contentView = backdrop
        window.isOpaque = false
        window.backgroundColor = .clear

        // Тёплый кремовый тон поверх стекла — фон теплеет под цвет иконки.
        Brand.addGlassTint(to: backdrop)

        // Свой брендовый заголовок: прячем системный текст и рисуем «иконка + название» по
        // центру полосы заголовка — окно узнаётся как Hopkey.
        window.titleVisibility = .hidden
        let header = Brand.makeHeaderView(title: L("snippet.picker.title"))
        backdrop.addSubview(header)
        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            header.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 9),
        ])

        let column = NSTableColumn(identifier: Self.rowID)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.rowHeight = Self.rowHeight
        // `.plain` (не `.inset`): без скрытых вертикальных отступов стиля — высоту окна
        // считаем точно. Скруглённое выделение рисуем сами (см. `SnippetRowBackground`).
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle  // колонка во всю ширину
        tableView.backgroundColor = .clear  // показываем размытие сквозь таблицу
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.target = self
        // Одиночный клик по строке — выбрать и вставить (выбор = действие).
        tableView.action = #selector(tableClicked)
        tableView.onConfirm = { [weak self] in self?.confirmSelection() }
        tableView.onDigit = { [weak self] digit in self?.pickByDigit(digit) }
        tableView.onHover = { [weak self] row in self?.setHovered(row) }

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(scroll)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(separator)

        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hintLabel)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0

        // Брендовый empty-state: монохромный силуэт-кролик (приглушённый) над текстом.
        emptyIcon.image = Brand.markImage
        emptyIcon.contentTintColor = .tertiaryLabelColor  // приглушённый, адаптивный под тему
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.setViews([emptyIcon, emptyLabel], in: .center)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(emptyStack)

        NSLayoutConstraint.activate([
            // Отступ сверху освобождает прозрачную полосу заголовка (с кнопками окна).
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 36),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -10),

            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -10),

            emptyStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -16),
        ])
    }

    /// Показывает пикер поверх остальных и ставит фокус в список.
    func show() {
        finished = false
        hoveredRow = -1
        snippets = store.snippets
        tableView.reloadData()
        emptyStack.isHidden = !snippets.isEmpty
        hintLabel.isHidden = snippets.isEmpty
        if !snippets.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        fitWindow()

        // Не активируем приложение (нужно для авто-вставки — см. `SnippetPickerPanel`):
        // неактивирующая панель становится ключевой сама, прежнее приложение остаётся активным.
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(tableView)
    }

    /// Высота — всегда под число строк (без пустоты под коротким списком), ширину берём
    /// запомненную (её можно тянуть). Позицию центрируем на активном экране.
    private func fitWindow() {
        guard let window else { return }
        tableView.layoutSubtreeIfNeeded()
        // Высота списка — по фактической геометрии строк (учитывает rowHeight + межстрочный
        // зазор), а не по формуле: иначе последняя строка подрезается.
        let visible = min(max(snippets.count, 1), Self.maxVisibleRows)
        let listHeight = snippets.isEmpty ? Self.rowHeight
                                          : ceil(tableView.rect(ofRow: visible - 1).maxY)
        // полоса заголовка + список + сепаратор + подсказка + поля
        let height = 36 + listHeight + 6 + 1 + 6 + 16 + 10
        let savedW = UserDefaults.standard.double(forKey: Self.sizeKeyW)
        let width = savedW >= 260 ? savedW : Self.defaultWidth
        window.setContentSize(NSSize(width: width, height: height))
        centerOnActiveScreen()
    }

    func windowDidResize(_ notification: Notification) {
        // Запоминаем только ширину — высота каждый раз подгоняется под содержимое.
        guard let width = window?.contentView?.frame.size.width else { return }
        UserDefaults.standard.set(Double(width), forKey: Self.sizeKeyW)
    }

    /// Центрирует окно на экране, где сейчас курсор.
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

    /// Обновляет hover-подсветку: гасим прежнюю строку, подсвечиваем новую под курсором.
    private func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        for r in [previous, row] where snippets.indices.contains(r) {
            (tableView.rowView(atRow: r, makeIfNecessary: false) as? SnippetRowBackground)?
                .isHovered = (r == row)
        }
    }

    // MARK: - Действия

    /// Клик мышью по строке (не по кнопке) — вставить именно эту строку.
    @objc private func tableClicked() {
        let row = tableView.clickedRow
        guard snippets.indices.contains(row) else { return }
        finish { self.onPick?(self.snippets[row]) }
    }

    /// Подтверждение с клавиатуры (↩) — вставить выделенную строку.
    @objc private func confirmSelection() {
        let row = tableView.selectedRow
        guard snippets.indices.contains(row) else { NSSound.beep(); return }
        finish { self.onPick?(self.snippets[row]) }
    }

    /// Быстрый выбор цифрой 1–9 — вставить N-й сниппет.
    private func pickByDigit(_ digit: Int) {
        guard let row = SnippetQuickSelect.index(forDigit: digit, count: snippets.count) else {
            NSSound.beep(); return
        }
        finish { self.onPick?(self.snippets[row]) }
    }

    /// Кнопка «скопировать» в строке — положить значение в буфер (без вставки).
    @objc private func copyClicked(_ sender: NSButton) {
        let row = sender.tag
        guard snippets.indices.contains(row) else { return }
        finish { self.onCopy?(self.snippets[row]) }
    }

    /// Закрывает окно и выполняет действие (порядок важен: закрытие вернёт ключевое окно
    /// прежнему приложению до синтетического Cmd+V во вставке).
    private func finish(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        window?.close()
        action()
    }

    // MARK: - Таблица

    func numberOfRows(in tableView: NSTableView) -> Int { snippets.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("snippetRowBg")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? SnippetRowBackground)
            ?? {
                let v = SnippetRowBackground()
                v.identifier = id
                return v
            }()
        view.isHovered = (row == hoveredRow)  // переиспользуемые строки не тащат чужой hover
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.rowID, owner: self) as? SnippetRowView)
            ?? {
                let v = SnippetRowView()
                v.identifier = Self.rowID
                v.copyButton.target = self
                v.copyButton.action = #selector(copyClicked(_:))
                return v
            }()
        // НИКОГДА не возвращаем nil для строки, которую таблица раскладывает: иначе у строки
        // не будет вью в колонке 0, и при простановке выделения AppKit вызовет
        // -[NSTableRowView viewAtColumn:] → NSRangeException → краш всего приложения (а с ним
        // пропадает и иконка в строке меню). Для невалидного индекса отдаём пустую ячейку.
        guard snippets.indices.contains(row) else {
            cell.indexBadge.value = ""
            cell.nameField.stringValue = ""
            cell.nameField.toolTip = nil
            cell.setAccessibilityLabel(nil)
            cell.copyButton.tag = -1
            return cell
        }
        let name = snippets[row].displayName
        cell.indexBadge.value = SnippetQuickSelect.label(forRow: row)  // номер для быстрого выбора
        cell.nameField.stringValue = name
        cell.nameField.toolTip = name   // полное имя по наведению, когда оно обрезано хвостом
        cell.setAccessibilityLabel(name)
        cell.copyButton.tag = row  // действие кнопки знает свою строку
        return cell
    }
}
