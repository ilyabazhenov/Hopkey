import AppKit
import HopkeyCore

/// Окно настроек: таблица шаблонов (имя + regex + URL), переключатели и хоткеи.
/// Изменения сохраняются по кнопке «Сохранить» и сообщаются через `onSave`.
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate {

    private let config: JiraConfig
    /// Управление автообновлением (Sparkle): флаг живёт не в конфиге, а в апдейтере.
    private let updater: UpdaterController
    /// Вызывается после сохранения, чтобы AppDelegate применил изменения (хоткей и т.п.).
    var onSave: (() -> Void)?

    /// Рабочая копия шаблонов, которую редактирует таблица.
    private var templates: [LinkTemplate] = []

    private let tableView = NSTableView()
    private let removeButton = NSButton()
    private let emptyStateLabel = NSTextField(labelWithString: "Нажмите + или «Из пресета», чтобы добавить шаблон")
    private let autoOpenCheck = NSButton(checkboxWithTitle: "Выполнять действие сразу при копировании ключа (иначе — показать уведомление)", target: nil, action: nil)
    private let clipboardActionPopup = NSPopUpButton()

    /// Два независимых хоткея с фиксированным действием: открыть / скопировать.
    private let openHotKeyCheck = NSButton(checkboxWithTitle: "Открывать в браузере", target: nil, action: nil)
    private let openHotKeyRecorder = HotKeyRecorderView()
    private let copyHotKeyCheck = NSButton(checkboxWithTitle: "Копировать ссылку", target: nil, action: nil)
    private let copyHotKeyRecorder = HotKeyRecorderView()
    /// Отдельный хоткей: открыть окно ручного ввода тикета (Accessibility не нужен).
    private let showInputHotKeyCheck = NSButton(checkboxWithTitle: "Открыть окно ввода тикета", target: nil, action: nil)
    private let showInputHotKeyRecorder = HotKeyRecorderView()
    private let showInputHotKeyNote = NSTextField(labelWithString: "Открывает окно ввода. С Универсальным доступом подставит выделенный текст; без него — откроется пустым (или с числом из буфера).")

    /// Общая опция приложения: автозапуск при входе (через `SMAppService`, не хранится в конфиге).
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: "Запускать при входе", target: nil, action: nil)

    /// Автоматическая проверка обновлений (Sparkle) — флаг проброшен в `SPUUpdater`.
    private let autoUpdateCheck = NSButton(checkboxWithTitle: "Автоматически проверять обновления", target: nil, action: nil)

    /// Подпись поля, выровненного в колонку.
    private let clipboardActionLabel = NSTextField(labelWithString: "Действие при копировании ключа:")
    /// Заголовок блока хоткеев (с напоминанием про разрешение Accessibility).
    private let hotKeysHeader = NSTextField(labelWithString: "Глобальные хоткеи (нужен доступ в «Конфиденциальность и безопасность ▸ Универсальный доступ»):")

    /// Действия в порядке отображения в выпадающем списке.
    private let actions: [TicketAction] = TicketAction.allCases

    private enum Column {
        static let enabled = NSUserInterfaceItemIdentifier("enabled")
        static let wholeWord = NSUserInterfaceItemIdentifier("wholeWord")
        static let uppercase = NSUserInterfaceItemIdentifier("uppercase")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let pattern = NSUserInterfaceItemIdentifier("pattern")
        static let url = NSUserInterfaceItemIdentifier("url")
    }

    private func title(for action: TicketAction) -> String {
        switch action {
        case .openInBrowser: return "Открыть в браузере"
        case .copyURL: return "Скопировать ссылку"
        }
    }

    init(config: JiraConfig, updater: UpdaterController) {
        self.config = config
        self.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Hopkey"
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }

        // Вводная строка о механике приложения — окно открывается первым при первом запуске.
        let introLabel = label("Hopkey превращает ID в ссылки по шаблонам regex→URL: скопируйте ключ (например, PROJ-123) — и тикет откроется; либо выделите текст и нажмите хоткей. В URL подставляются группы совпадения ($1 — первая, $0 — всё совпадение).")
        introLabel.textColor = .secondaryLabelColor
        introLabel.font = .systemFont(ofSize: 11)
        introLabel.lineBreakMode = .byWordWrapping
        introLabel.maximumNumberOfLines = 0
        introLabel.preferredMaxLayoutWidth = 640

        let projectsLabel = label("Шаблоны распознавания:")

        // Таблица шаблонов: галочки (вкл/границы слова/верхний регистр) + имя, regex, URL.
        func textColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat,
                        minWidth: CGFloat, tooltip: String? = nil) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = minWidth
            c.headerToolTip = tooltip
            return c
        }
        func checkColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat,
                         tooltip: String) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = width
            c.maxWidth = width
            c.headerToolTip = tooltip
            return c
        }
        tableView.addTableColumn(checkColumn(Column.enabled, "Вкл", width: 40,
            tooltip: "Участвует ли шаблон в распознавании."))
        tableView.addTableColumn(checkColumn(Column.wholeWord, "Слово", width: 54,
            tooltip: "Границы слова: совпадение не приклеено к другим буквам/цифрам — PROJ-1 поймается, XPROJ-1 нет. Для #(\\d+) обычно выключают."))
        tableView.addTableColumn(checkColumn(Column.uppercase, "ВЕРХ", width: 54,
            tooltip: "Нормализовать найденный ключ в ВЕРХНИЙ регистр (нужно Jira-ключам: proj-7 → PROJ-7)."))
        tableView.addTableColumn(textColumn(Column.name, "Имя", width: 110, minWidth: 80,
            tooltip: "Произвольное имя — показывается в окне ручного ввода."))
        tableView.addTableColumn(textColumn(Column.pattern, "Шаблон (regex)", width: 170, minWidth: 120,
            tooltip: "Регулярное выражение. Группы доступны в URL как $1, $2…"))
        tableView.addTableColumn(textColumn(Column.url, "URL ($1 — номер)", width: 220, minWidth: 160,
            tooltip: "$1 — первая группа (номер), $0 — всё совпадение."))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Подсказка по центру таблицы, пока проектов нет. Лейбл оверлеится ПОВЕРХ
        // скролла (добавляется в `content` ниже), а не внутрь него: `NSScrollView`
        // сам тайлит свои подвью и прибивает постороннюю вью к верхнему краю —
        // тогда подсказка наезжает на заголовки колонок.
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        // Панель +/− под таблицей.
        let addButton = NSButton(title: "+", target: self, action: #selector(addRow))
        addButton.bezelStyle = .smallSquare
        addButton.setButtonType(.momentaryPushIn)
        removeButton.title = "−"
        removeButton.target = self
        removeButton.action = #selector(removeSelectedRow)
        removeButton.bezelStyle = .smallSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.isEnabled = false
        for b in [addButton, removeButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        // Кнопка «Из пресета ▾» — добавляет готовую заготовку (Jira/GitHub/CVE) для правки.
        let presetButton = NSButton(title: "Из пресета ▾", target: self, action: #selector(showPresetMenu))
        presetButton.bezelStyle = .rounded
        presetButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonBar = NSStackView(views: [addButton, removeButton, presetButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 0
        buttonBar.setCustomSpacing(8, after: removeButton)
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        autoOpenCheck.translatesAutoresizingMaskIntoConstraints = false

        // Строка «подпись + контрол» для действия буфера.
        clipboardActionLabel.translatesAutoresizingMaskIntoConstraints = false
        clipboardActionPopup.removeAllItems()
        clipboardActionPopup.addItems(withTitles: actions.map(title(for:)))
        clipboardActionPopup.translatesAutoresizingMaskIntoConstraints = false
        let clipboardActionRow = NSStackView(views: [clipboardActionLabel, clipboardActionPopup])
        clipboardActionRow.orientation = .horizontal
        clipboardActionRow.alignment = .centerY
        clipboardActionRow.spacing = 8
        clipboardActionRow.translatesAutoresizingMaskIntoConstraints = false

        // Блок хоткеев: приглушённый заголовок + две строки «галочка + рекордер».
        hotKeysHeader.translatesAutoresizingMaskIntoConstraints = false
        hotKeysHeader.textColor = .secondaryLabelColor
        hotKeysHeader.font = .systemFont(ofSize: 11)
        hotKeysHeader.lineBreakMode = .byWordWrapping
        hotKeysHeader.maximumNumberOfLines = 0
        hotKeysHeader.preferredMaxLayoutWidth = 500

        func hotKeyRow(_ check: NSButton, _ recorder: HotKeyRecorderView) -> NSStackView {
            check.translatesAutoresizingMaskIntoConstraints = false
            check.target = self
            check.action = #selector(updateDependentControls)
            recorder.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [check, recorder])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }
        let openHotKeyRow = hotKeyRow(openHotKeyCheck, openHotKeyRecorder)
        let copyHotKeyRow = hotKeyRow(copyHotKeyCheck, copyHotKeyRecorder)
        let showInputHotKeyRow = hotKeyRow(showInputHotKeyCheck, showInputHotKeyRecorder)

        showInputHotKeyNote.translatesAutoresizingMaskIntoConstraints = false
        showInputHotKeyNote.textColor = .secondaryLabelColor
        showInputHotKeyNote.font = .systemFont(ofSize: 11)
        showInputHotKeyNote.lineBreakMode = .byWordWrapping
        showInputHotKeyNote.maximumNumberOfLines = 0
        showInputHotKeyNote.preferredMaxLayoutWidth = 500

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"

        // Сброс всех настроек к значениям по умолчанию — в левом нижнем углу, подальше от «Сохранить».
        let resetButton = NSButton(title: "Сбросить настройки", target: self, action: #selector(resetToDefaults))
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        // Горизонтальные разделители делят окно на три блока:
        // проекты · реакция на копирование · глобальный хоткей.
        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            box.translatesAutoresizingMaskIntoConstraints = false
            return box
        }
        let clipboardSeparator = separator()
        let hotKeySeparator = separator()
        let loginSeparator = separator()

        launchAtLoginCheck.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            introLabel,
            projectsLabel,
            scroll,
            buttonBar,
            clipboardSeparator,
            autoOpenCheck, clipboardActionRow,
            hotKeySeparator,
            hotKeysHeader,
            openHotKeyRow,
            copyHotKeyRow,
            showInputHotKeyRow,
            showInputHotKeyNote,
            loginSeparator,
            launchAtLoginCheck,
            autoUpdateCheck,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: scroll)
        // Воздух вокруг разделителей, чтобы блоки читались как отдельные группы.
        stack.setCustomSpacing(16, after: buttonBar)
        stack.setCustomSpacing(16, after: clipboardSeparator)
        stack.setCustomSpacing(16, after: clipboardActionRow)
        stack.setCustomSpacing(16, after: hotKeySeparator)
        // Подсказку прижимаем к своей строке хоткея, а воздух даём уже после неё.
        stack.setCustomSpacing(4, after: showInputHotKeyRow)
        stack.setCustomSpacing(16, after: showInputHotKeyNote)
        stack.setCustomSpacing(16, after: loginSeparator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // Поверх скролла, чтобы подсказка пустого состояния висела по центру таблицы.
        content.addSubview(emptyStateLabel)
        content.addSubview(saveButton)
        content.addSubview(resetButton)

        // Галочки хоткеев — одинаковой ширины, чтобы рекордеры справа были на одной вертикали.
        let hotKeyCheckWidth = ceil(max(openHotKeyCheck.intrinsicContentSize.width,
                                        copyHotKeyCheck.intrinsicContentSize.width,
                                        showInputHotKeyCheck.intrinsicContentSize.width))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 160),
            clipboardSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hotKeySeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            openHotKeyCheck.widthAnchor.constraint(equalToConstant: hotKeyCheckWidth),
            copyHotKeyCheck.widthAnchor.constraint(equalToConstant: hotKeyCheckWidth),
            showInputHotKeyCheck.widthAnchor.constraint(equalToConstant: hotKeyCheckWidth),
            openHotKeyRecorder.widthAnchor.constraint(equalToConstant: 160),
            copyHotKeyRecorder.widthAnchor.constraint(equalToConstant: 160),
            showInputHotKeyRecorder.widthAnchor.constraint(equalToConstant: 160),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            // Нижняя панель кнопок не должна налезать на «Запускать при входе» — держим зазор.
            saveButton.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 20),
            resetButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            resetButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    // MARK: - Таблица

    func numberOfRows(in tableView: NSTableView) -> Int { templates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, templates.indices.contains(row) else { return nil }
        let template = templates[row]
        let id = tableColumn.identifier

        // Колонки-галочки: вкл / границы слова / верхний регистр.
        switch id {
        case Column.enabled, Column.wholeWord, Column.uppercase:
            let check = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton)
                ?? makeCheckbox(identifier: id)
            check.tag = row
            switch id {
            case Column.enabled: check.state = template.enabled ? .on : .off
            case Column.wholeWord: check.state = template.wholeWord ? .on : .off
            default: check.state = template.uppercase ? .on : .off
            }
            return check
        default:
            break
        }

        // Текстовые колонки: имя / regex / URL.
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? makeCellField(identifier: id)
        switch id {
        case Column.name:
            field.stringValue = template.name
            field.placeholderString = "Jira"
        case Column.pattern:
            field.stringValue = template.pattern
            field.placeholderString = "PROJ-(\\d+)"
            field.toolTip = "Регулярное выражение. Группы доступны в URL как $1, $2…"
        case Column.url:
            field.stringValue = template.url
            field.placeholderString = "https://jira.company.net/browse/PROJ-$1"
            field.toolTip = "$1 — первая группа (номер), $0 — всё совпадение."
        default:
            break
        }
        // Невалидный шаблон подсвечиваем красным в regex/URL.
        if id == Column.pattern || id == Column.url {
            field.textColor = template.isValid ? .labelColor : .systemRed
        }
        return field
    }

    /// Чекбокс-ячейка таблицы (вкл/границы/регистр). Без заголовка — он в шапке колонки.
    private func makeCheckbox(identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let action: Selector
        switch identifier {
        case Column.enabled: action = #selector(toggleEnabled(_:))
        case Column.wholeWord: action = #selector(toggleWholeWord(_:))
        default: action = #selector(toggleUppercase(_:))
        }
        let check = NSButton(checkboxWithTitle: "", target: self, action: action)
        check.identifier = identifier
        check.imagePosition = .imageOnly
        return check
    }

    private func makeCellField(identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let field = NSTextField()
        // Свой cell центрирует текст по вертикали: иначе в строке высотой 24 он
        // прижимается к верхнему краю. Замена cell сбрасывает дефолты — выставляем явно.
        field.cell = VerticallyCenteredTextFieldCell()
        field.identifier = identifier
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.target = self
        field.action = #selector(cellEdited(_:))
        // Делегат ловит завершение редактирования при ЛЮБОЙ потере фокуса
        // (клик мимо, Tab, программный `commitEditing`), а не только по Return —
        // `action` у `NSTextField` срабатывает лишь на Return, поэтому значения
        // последней правки терялись, и проект «уезжал» в фильтр невалидных при сохранении.
        field.delegate = self
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    /// Показывает подсказку по центру таблицы, только пока шаблонов нет.
    private func updateEmptyState() {
        emptyStateLabel.isHidden = !templates.isEmpty
    }

    /// Перекрашивает regex/URL в красный у невалидных строк, не дёргая `reloadData`
    /// (чтобы не пересоздавать редактируемое поле во время правки).
    private func refreshValidity() {
        let cols = [tableView.column(withIdentifier: Column.pattern),
                    tableView.column(withIdentifier: Column.url)]
        for row in templates.indices {
            let valid = templates[row].isValid
            for col in cols where col >= 0 {
                if let field = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? NSTextField {
                    field.textColor = valid ? .labelColor : .systemRed
                }
            }
        }
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard templates.indices.contains(sender.tag) else { return }
        templates[sender.tag].enabled = sender.state == .on
    }

    @objc private func toggleWholeWord(_ sender: NSButton) {
        guard templates.indices.contains(sender.tag) else { return }
        templates[sender.tag].wholeWord = sender.state == .on
    }

    @objc private func toggleUppercase(_ sender: NSButton) {
        guard templates.indices.contains(sender.tag) else { return }
        templates[sender.tag].uppercase = sender.state == .on
    }

    /// Каждый рекордер активен только при включённой своей галочке.
    /// «Действие при копировании ключа» не трогаем — оно применяется всегда:
    /// сразу при включённой галочке либо по клику на уведомление при выключенной.
    @objc private func updateDependentControls() {
        openHotKeyRecorder.isEnabled = openHotKeyCheck.state == .on
        copyHotKeyRecorder.isEnabled = copyHotKeyCheck.state == .on
        showInputHotKeyRecorder.isEnabled = showInputHotKeyCheck.state == .on
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        commitCell(sender)
    }

    /// Завершение редактирования ячейки по любой причине (Return, Tab, потеря
    /// фокуса при клике по «Сохранить»). На `action` полагаться нельзя — у
    /// `NSTextField` он шлётся только по Return.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commitCell(field)
    }

    /// Переносит значение ячейки в рабочую копию `templates`.
    private func commitCell(_ field: NSTextField) {
        let row = tableView.row(for: field)
        let col = tableView.column(for: field)
        guard templates.indices.contains(row), col >= 0 else { return }

        switch tableView.tableColumns[col].identifier {
        case Column.name:
            templates[row].name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case Column.pattern:
            templates[row].pattern = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case Column.url:
            templates[row].url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            break
        }
        refreshValidity()
    }

    /// Добавляет новый шаблон в таблицу, выделяет его и начинает правку имени.
    private func appendTemplate(_ template: LinkTemplate) {
        commitEditing()
        templates.append(template)
        tableView.reloadData()
        updateEmptyState()
        let newRow = templates.count - 1
        tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(newRow)
        // Правку начинаем с колонки «Имя» (индекс 3 — после трёх галочек).
        tableView.editColumn(tableView.column(withIdentifier: Column.name), row: newRow, with: nil, select: true)
    }

    @objc private func addRow() {
        appendTemplate(LinkTemplate(name: "", pattern: "", url: ""))
    }

    /// Показывает меню пресетов под кнопкой; выбор добавляет готовую заготовку.
    @objc private func showPresetMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (i, preset) in LinkTemplate.presets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(addPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func addPreset(_ sender: NSMenuItem) {
        guard LinkTemplate.presets.indices.contains(sender.tag) else { return }
        appendTemplate(LinkTemplate.presets[sender.tag])
    }

    @objc private func removeSelectedRow() {
        let row = tableView.selectedRow
        guard templates.indices.contains(row) else { return }
        commitEditing()
        templates.remove(at: row)
        tableView.reloadData()
        updateEmptyState()
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    /// Завершает активное редактирование ячейки, чтобы значение попало в модель.
    private func commitEditing() {
        window?.makeFirstResponder(tableView)
    }

    func loadValues() {
        templates = config.templates
        tableView.reloadData()
        updateEmptyState()
        refreshValidity()
        removeButton.isEnabled = false

        autoOpenCheck.state = config.autoOpen ? .on : .off
        if let index = actions.firstIndex(of: config.clipboardAction) {
            clipboardActionPopup.selectItem(at: index)
        }
        openHotKeyCheck.state = config.openHotKeyEnabled ? .on : .off
        openHotKeyRecorder.combo = (UInt32(config.openHotKeyKeyCode), UInt32(config.openHotKeyModifiers))
        copyHotKeyCheck.state = config.copyHotKeyEnabled ? .on : .off
        copyHotKeyRecorder.combo = (UInt32(config.copyHotKeyKeyCode), UInt32(config.copyHotKeyModifiers))
        showInputHotKeyCheck.state = config.showInputHotKeyEnabled ? .on : .off
        showInputHotKeyRecorder.combo = (UInt32(config.showInputHotKeyKeyCode), UInt32(config.showInputHotKeyModifiers))
        launchAtLoginCheck.state = LaunchAtLogin.isEnabled ? .on : .off
        autoUpdateCheck.state = updater.automaticallyChecksForUpdates ? .on : .off
        updateDependentControls()
    }

    func showWindow() {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func save() {
        commitEditing()
        config.templates = templates.filter(\.isValid)

        config.autoOpen = autoOpenCheck.state == .on
        let clipboardIndex = clipboardActionPopup.indexOfSelectedItem
        if actions.indices.contains(clipboardIndex) {
            config.clipboardAction = actions[clipboardIndex]
        }

        config.openHotKeyEnabled = openHotKeyCheck.state == .on
        config.openHotKeyKeyCode = Int(openHotKeyRecorder.combo.keyCode)
        config.openHotKeyModifiers = Int(openHotKeyRecorder.combo.modifiers)
        config.copyHotKeyEnabled = copyHotKeyCheck.state == .on
        config.copyHotKeyKeyCode = Int(copyHotKeyRecorder.combo.keyCode)
        config.copyHotKeyModifiers = Int(copyHotKeyRecorder.combo.modifiers)
        config.showInputHotKeyEnabled = showInputHotKeyCheck.state == .on
        config.showInputHotKeyKeyCode = Int(showInputHotKeyRecorder.combo.keyCode)
        config.showInputHotKeyModifiers = Int(showInputHotKeyRecorder.combo.modifiers)

        // Запуск при входе хранится не в конфиге, а в системе — синхронизируем по факту.
        LaunchAtLogin.setEnabled(launchAtLoginCheck.state == .on)
        // Автообновление — пробрасываем флаг в Sparkle (он сам персистит его в UserDefaults).
        updater.automaticallyChecksForUpdates = autoUpdateCheck.state == .on

        onSave?()
        window?.close()
    }

    /// Сбрасывает все настройки к значениям по умолчанию после подтверждения,
    /// перечитывает поля окна и применяет изменения (через `onSave`), не закрывая окно.
    @objc private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Сбросить настройки?"
        alert.informativeText = "Шаблоны, действие при копировании и хоткеи вернутся к значениям по умолчанию. Действие нельзя отменить."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.config.resetToDefaults()
            self.loadValues()
            self.onSave?()
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }
}

/// Текстовая ячейка, центрирующая содержимое по вертикали. Нужна в таблице проектов,
/// где высота строки (24) больше высоты текста, а `NSTextFieldCell` по умолчанию
/// прижимает текст к верхнему краю. Сдвиг применяется и при отрисовке, и при редактировании.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        let dy = (rect.height - textHeight) / 2
        guard dy > 0 else { return rect }
        var r = rect
        r.origin.y += dy
        r.size.height -= dy * 2
        return r
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: centered(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
