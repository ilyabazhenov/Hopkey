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

/// Таблица сниппетов: ↩/Enter подтверждают выбранную строку, Esc отдаём панели (закрытие).
private final class SnippetTableView: NSTableView {
    var onConfirm: (() -> Void)?

    override func keyDown(with event: NSEvent) {
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
    let nameField = NSTextField(labelWithString: "")
    let copyButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = .systemFont(ofSize: 13)
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

        addSubview(nameField)
        addSubview(copyButton)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
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
    private let hintLabel = NSTextField(labelWithString: L("snippet.picker.hint"))

    /// Текущий список (снимок на момент показа).
    private var snippets: [Snippet] = []
    /// Защита от двойного действия за один показ (клик по кнопке и по строке и т.п.).
    private var finished = false

    private static let rowID = NSUserInterfaceItemIdentifier("snippetRow")
    private static let defaultWidth: CGFloat = 340
    private static let rowHeight: CGFloat = 34
    /// Сколько строк показываем без прокрутки при авторазмере — дальше скролл.
    private static let maxVisibleRows = 8
    /// Ключ для запоминания размера окна между показами/запусками.
    private static let sizeKeyW = "snippetPicker.width"
    private static let sizeKeyH = "snippetPicker.height"

    init(store: SnippetStore) {
        self.store = store
        let panel = SnippetPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 200),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L("snippet.picker.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 260, height: 160)
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
        // того, что под ней, и не выглядит тяжёлым непрозрачным окном.
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        window.contentView = backdrop
        window.isOpaque = false
        window.backgroundColor = .clear

        let column = NSTableColumn(identifier: Self.rowID)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.rowHeight = Self.rowHeight
        tableView.style = .inset            // современный вид: вложенные строки, скруглённое выделение
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
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -10),

            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -16),
        ])
    }

    /// Показывает пикер поверх остальных и ставит фокус в список.
    func show() {
        finished = false
        snippets = store.snippets
        tableView.reloadData()
        emptyLabel.isHidden = !snippets.isEmpty
        hintLabel.isHidden = snippets.isEmpty
        if !snippets.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        restoreOrFitSize()

        // Не активируем приложение (нужно для авто-вставки — см. `SnippetPickerPanel`):
        // неактивирующая панель становится ключевой сама, прежнее приложение остаётся активным.
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(tableView)
    }

    /// Берёт запомненный размер (если есть), иначе подгоняет высоту под число строк.
    /// Позицию всегда центрируем на активном экране — там внимание пользователя.
    private func restoreOrFitSize() {
        guard let window else { return }
        let defaults = UserDefaults.standard
        let savedW = defaults.double(forKey: Self.sizeKeyW)
        let savedH = defaults.double(forKey: Self.sizeKeyH)
        if savedW >= 260, savedH >= 160 {
            window.setContentSize(NSSize(width: savedW, height: savedH))
        } else {
            let rows = max(snippets.count, 1)
            let visible = min(rows, Self.maxVisibleRows)
            let listHeight = CGFloat(visible) * (Self.rowHeight + 2)
            let height = 8 + listHeight + 6 + 1 + 6 + 16 + 10  // список + сепаратор + подсказка + поля
            window.setContentSize(NSSize(width: Self.defaultWidth, height: height))
        }
        centerOnActiveScreen()
    }

    func windowDidResize(_ notification: Notification) {
        guard let size = window?.contentView?.frame.size else { return }
        UserDefaults.standard.set(Double(size.width), forKey: Self.sizeKeyW)
        UserDefaults.standard.set(Double(size.height), forKey: Self.sizeKeyH)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard snippets.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.rowID, owner: self) as? SnippetRowView)
            ?? {
                let v = SnippetRowView()
                v.identifier = Self.rowID
                v.copyButton.target = self
                v.copyButton.action = #selector(copyClicked(_:))
                return v
            }()
        cell.nameField.stringValue = snippets[row].displayName
        cell.copyButton.tag = row  // действие кнопки знает свою строку
        return cell
    }
}
