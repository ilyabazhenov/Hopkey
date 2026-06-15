import AppKit
import HopkeyCore

/// Окно настроек с тремя вкладками в тулбаре (Шаблоны · Хоткеи · Общие).
/// Настройки применяются мгновенно (как в системных «Настройках»): каждое изменение
/// сразу пишется в конфиг и применяется через `onSave` — кнопки «Сохранить» нет.
/// Шаблоны по-прежнему создаются/редактируются в отдельном модальном окне
/// (`TemplateEditorWindowController`), таблица остаётся списком «для опознания».
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSToolbarDelegate {

    private let config: JiraConfig
    /// Управление автообновлением (Sparkle): флаг живёт не в конфиге, а в апдейтере.
    private let updater: UpdaterController
    /// Вызывается после любого изменения, чтобы AppDelegate переприменил конфиг (хоткеи и т.п.).
    var onSave: (() -> Void)?
    /// Опрашивает AppDelegate, удалось ли зарегистрировать хоткеи при последнем применении
    /// (комбинация могла быть занята). Читается после `onSave?()`, чтобы показать
    /// предупреждение под нужным рекордером.
    var hotKeyStatus: (() -> (input: Bool, snippets: Bool))?

    /// Рабочая копия шаблонов, которую редактирует список.
    private var templates: [LinkTemplate] = []
    /// Удерживает редактор шаблона, пока открыт его sheet.
    private var templateEditor: TemplateEditorWindowController?

    /// Хранилище сниппетов (метаданные в UserDefaults, значения в Keychain).
    private let snippetStore = SnippetStore.shared
    /// Рабочая копия списка сниппетов.
    private var snippets: [Snippet] = []
    /// Удерживает редактор сниппета, пока открыт его sheet.
    private var snippetEditor: SnippetEditorWindowController?

    /// Фиксированная ширина контента окна (вкладки сами задают высоту).
    private let contentWidth: CGFloat = 540
    /// Ширина переноса для многострочных подписей (контент минус поля 20+20).
    private var wrapWidth: CGFloat { contentWidth - 40 }

    // MARK: Вкладки

    private enum Tab: String, CaseIterable {
        case templates, snippets, hotkeys, general, about

        var label: String {
            switch self {
            case .templates: return L("settings.tab.templates")
            case .snippets: return L("settings.tab.snippets")
            case .hotkeys: return L("settings.tab.hotkeys")
            case .general: return L("settings.tab.general")
            case .about: return L("settings.tab.about")
            }
        }
        var symbol: String {
            switch self {
            case .templates: return "list.bullet.rectangle"
            case .snippets: return "text.badge.plus"
            case .hotkeys: return "keyboard"
            case .general: return "gearshape"
            case .about: return "info.circle"
            }
        }
        var itemID: NSToolbarItem.Identifier { .init(rawValue) }
    }

    /// Контейнер, в который кладётся вью активной вкладки.
    private let container = NSView()
    private var tabViews: [Tab: NSView] = [:]
    /// Кастомные кнопки-вкладки в тулбаре (для ручной подсветки выбранной).
    private var tabButtons: [Tab: TabButton] = [:]
    private var currentTab: Tab = .templates

    /// Единая ширина всех вкладок: по самой длинной подписи + поля. Так «О приложении»
    /// и «Общие» получают одинаковую ширину, а не подгоняются каждая под свой текст.
    private lazy var tabItemWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 11)
        let widest = Tab.allCases
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 60
        return ceil(widest) + 20
    }()

    // MARK: Контролы вкладки «Шаблоны»

    private let tableView = NSTableView()
    private let removeButton = NSButton()
    private let editButton = NSButton()
    private let emptyStateLabel = NSTextField(labelWithString: L("settings.templates.empty"))

    // MARK: Контролы вкладки «Сниппеты»

    private let snippetsTableView = NSTableView()
    private let snippetRemoveButton = NSButton()
    private let snippetEditButton = NSButton()
    private let snippetsEmptyLabel = NSTextField(labelWithString: L("settings.snippets.empty"))

    // MARK: Контролы вкладки «Хоткеи»

    /// Хоткей окна ввода (Accessibility не требует) + хоткей пикера сниппетов
    /// (авто-вставка требует Accessibility).
    private let showInputHotKeyCheck = NSButton(checkboxWithTitle: L("settings.hotkey.input"), target: nil, action: nil)
    private let showInputHotKeyRecorder = HotKeyRecorderView()
    private let snippetsHotKeyCheck = NSButton(checkboxWithTitle: L("settings.hotkey.snippets"), target: nil, action: nil)
    private let snippetsHotKeyRecorder = HotKeyRecorderView()
    /// Предупреждения «комбинация занята» под каждым рекордером (скрыты, пока всё ок).
    private let showInputHotKeyWarning = NSTextField(labelWithString: L("settings.hotkey.conflict"))
    private let snippetsHotKeyWarning = NSTextField(labelWithString: L("settings.hotkey.conflict"))
    private let hotKeySoundsCheck = NSButton(checkboxWithTitle: L("settings.hotkey.sounds"), target: nil, action: nil)
    private let hotKeySoundPopup = NSPopUpButton()

    /// Пункты попапа выбора звука хоткея.
    private struct HotKeySoundOption { let sound: HotKeySound; let title: String }
    private let hotKeySoundOptions: [HotKeySoundOption] = HotKeySound.allCases.map {
        .init(sound: $0, title: L($0.localizationKey))
    }

    // MARK: Контролы вкладки «Общие»

    /// Объединяет прежний чекбокс `autoOpen` и попап действия: один список из 4 состояний.
    private let clipboardActionPopup = NSPopUpButton()
    /// Выбор языка интерфейса (поверх системного); порядок пунктов = `languageOrder`.
    private let languagePopup = NSPopUpButton()
    private let languageOrder = AppLanguage.allCases
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: L("settings.general.launchAtLogin"), target: nil, action: nil)
    private let autoUpdateCheck = NSButton(checkboxWithTitle: L("settings.general.autoUpdate"), target: nil, action: nil)

    /// Пункт попапа «при копировании» ↔ пара (авто-открытие, действие).
    private struct ClipboardOption { let autoOpen: Bool; let action: TicketAction; let title: String }
    private let clipboardOptions: [ClipboardOption] = [
        .init(autoOpen: false, action: .openInBrowser, title: L("settings.clipboard.notifyOpen")),
        .init(autoOpen: false, action: .copyURL,       title: L("settings.clipboard.notifyCopy")),
        .init(autoOpen: true,  action: .openInBrowser, title: L("settings.clipboard.autoOpen")),
        .init(autoOpen: true,  action: .copyURL,       title: L("settings.clipboard.autoCopy")),
    ]

    private enum Column {
        static let enabled = NSUserInterfaceItemIdentifier("enabled")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let pattern = NSUserInterfaceItemIdentifier("pattern")
    }

    private enum SnippetColumn {
        static let name = NSUserInterfaceItemIdentifier("snippetName")
        static let value = NSUserInterfaceItemIdentifier("snippetValue")
    }

    init(config: JiraConfig, updater: UpdaterController) {
        self.config = config
        self.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("settings.window.title")
        // Ниже — начинает обрезать контролы; больше — растягивается список шаблонов.
        window.minSize = NSSize(width: 540, height: 420)
        super.init(window: window)
        window.delegate = self
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container
        setupToolbar()
        buildTabs()
        show(.templates)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    // MARK: - Тулбар-вкладки

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        // Иконку и подпись рисует сама кнопка-вкладка (`TabButton`), поэтому тулбару
        // запрещаем дублировать подпись снизу.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .preference
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.label  // для меню переполнения и Accessibility (визуально не рисуется)
        let button = TabButton(symbol: tab.symbol, title: tab.label, width: tabItemWidth) { [weak self] in
            self?.show(tab)
        }
        item.view = button
        tabButtons[tab] = button
        return item
    }

    private var tabIdentifiers: [NSToolbarItem.Identifier] { Tab.allCases.map(\.itemID) }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabIdentifiers }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabIdentifiers }
    // Подсветку выбранной вкладки рисуем сами (см. `TabButton`), системная не нужна.
    func toolbarSelectableItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    /// Кладёт вью вкладки в контейнер и подгоняет высоту окна под её содержимое.
    private func show(_ tab: Tab) {
        currentTab = tab
        guard let view = tabViews[tab] else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        // Вкладка заполняет контейнер целиком; лишнее место по вертикали поглощает
        // гибкий элемент вкладки (список шаблонов) или невидимый спейсер (см. `tabView`).
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for (t, button) in tabButtons { button.isSelected = (t == tab) }
        // Список сниппетов читаем из Keychain лениво — только когда открыли их вкладку.
        if tab == .snippets { refreshSnippetsTab() }
    }

    // MARK: - Сборка вкладок

    private func label(_ text: String, secondary: Bool = false, wraps: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.translatesAutoresizingMaskIntoConstraints = false
        if secondary {
            l.textColor = .secondaryLabelColor
            l.font = .systemFont(ofSize: 11)
        }
        if wraps {
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 0
            l.preferredMaxLayoutWidth = wrapWidth
        }
        return l
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// Оборачивает вертикальный стек контента в вью вкладки с полями 20pt по краям.
    /// - Parameter flexibleContent: у вкладки уже есть свой растягивающийся по высоте
    ///   элемент (список шаблонов). Если `false`, добавляем невидимый спейсер снизу,
    ///   чтобы при увеличении окна контент держался у верхнего края.
    private func tabView(_ stack: NSStackView, flexibleContent: Bool = false,
                         extraSetup: (NSView) -> Void = { _ in }) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        if !flexibleContent {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
            stack.addArrangedSubview(spacer)
        }
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),
        ])
        extraSetup(v)
        return v
    }

    private func buildTabs() {
        tabViews[.templates] = buildTemplatesTab()
        tabViews[.snippets] = buildSnippetsTab()
        tabViews[.hotkeys] = buildHotKeysTab()
        tabViews[.general] = buildGeneralTab()
        tabViews[.about] = buildAboutTab()
    }

    // MARK: Вкладка «Шаблоны»

    private func buildTemplatesTab() -> NSView {
        let intro = label(L("settings.templates.intro"), secondary: true, wraps: true)

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat,
                    minWidth: CGFloat, fixed: Bool = false, tooltip: String? = nil) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = minWidth
            if fixed { c.maxWidth = width }
            c.headerToolTip = tooltip
            return c
        }
        tableView.addTableColumn(column(Column.enabled, L("settings.templates.col.enabled"), width: 40, minWidth: 40, fixed: true,
            tooltip: L("settings.templates.col.enabled.tooltip")))
        tableView.addTableColumn(column(Column.name, L("settings.templates.col.name"), width: 150, minWidth: 100))
        tableView.addTableColumn(column(Column.pattern, L("settings.templates.col.pattern"), width: 290, minWidth: 160))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24
        tableView.target = self
        tableView.doubleAction = #selector(editSelectedRow)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Список — гибкий по высоте элемент вкладки: при росте окна всё лишнее место
        // достаётся ему (видно больше шаблонов), внутри — прокрутка для длинных списков.
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        // Подсказка пустого состояния висит ПОВЕРХ скролла по центру (см. прежний коммент:
        // внутрь скролла её класть нельзя — он прибьёт её к шапке колонок).
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        // Панель под таблицей: +, −, Изменить, Из пресета. Все кнопки в едином
        // скруглённом стиле (.rounded); +/− держим тесной парой как add/remove.
        let addButton = NSButton(title: "+", target: self, action: #selector(addRow))
        addButton.bezelStyle = .rounded
        removeButton.title = "−"
        removeButton.target = self
        removeButton.action = #selector(removeSelectedRow)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false
        for b in [addButton, removeButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        editButton.title = L("settings.templates.edit")
        editButton.target = self
        editButton.action = #selector(editSelectedRow)
        editButton.bezelStyle = .rounded
        editButton.isEnabled = false
        editButton.translatesAutoresizingMaskIntoConstraints = false
        let presetButton = NSButton(title: L("settings.templates.preset"), target: self, action: #selector(showPresetMenu))
        presetButton.bezelStyle = .rounded
        presetButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonBar = NSStackView(views: [addButton, removeButton, editButton, presetButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 4  // тесный зазор внутри пары +/−
        buttonBar.setCustomSpacing(10, after: removeButton)
        buttonBar.setCustomSpacing(8, after: editButton)
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [intro, label(L("settings.templates.listLabel")), scroll, buttonBar])
        stack.spacing = 8
        stack.setCustomSpacing(10, after: scroll)

        return tabView(stack, flexibleContent: true) { [self] v in
            v.addSubview(emptyStateLabel)
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
                emptyStateLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                emptyStateLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ])
        }
    }

    // MARK: Вкладка «Сниппеты»

    private func buildSnippetsTab() -> NSView {
        let intro = label(L("settings.snippets.intro"), secondary: true, wraps: true)

        let nameCol = NSTableColumn(identifier: SnippetColumn.name)
        nameCol.title = L("settings.snippets.col.name")
        nameCol.width = 200
        nameCol.minWidth = 120
        let valueCol = NSTableColumn(identifier: SnippetColumn.value)
        valueCol.title = L("settings.snippets.col.value")
        valueCol.width = 280
        valueCol.minWidth = 120
        snippetsTableView.addTableColumn(nameCol)
        snippetsTableView.addTableColumn(valueCol)
        snippetsTableView.dataSource = self
        snippetsTableView.delegate = self
        snippetsTableView.usesAlternatingRowBackgroundColors = true
        snippetsTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        snippetsTableView.allowsMultipleSelection = false
        snippetsTableView.rowHeight = 24
        snippetsTableView.target = self
        snippetsTableView.doubleAction = #selector(editSelectedSnippet)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = snippetsTableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        snippetsEmptyLabel.textColor = .secondaryLabelColor
        snippetsEmptyLabel.font = .systemFont(ofSize: 12)
        snippetsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "+", target: self, action: #selector(addSnippet))
        addButton.bezelStyle = .rounded
        snippetRemoveButton.title = "−"
        snippetRemoveButton.target = self
        snippetRemoveButton.action = #selector(removeSelectedSnippet)
        snippetRemoveButton.bezelStyle = .rounded
        snippetRemoveButton.isEnabled = false
        for b in [addButton, snippetRemoveButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        snippetEditButton.title = L("settings.templates.edit")
        snippetEditButton.target = self
        snippetEditButton.action = #selector(editSelectedSnippet)
        snippetEditButton.bezelStyle = .rounded
        snippetEditButton.isEnabled = false
        snippetEditButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonBar = NSStackView(views: [addButton, snippetRemoveButton, snippetEditButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 4
        buttonBar.setCustomSpacing(10, after: snippetRemoveButton)
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [intro, label(L("settings.snippets.listLabel")), scroll, buttonBar])
        stack.spacing = 8
        stack.setCustomSpacing(10, after: scroll)

        return tabView(stack, flexibleContent: true) { [self] v in
            v.addSubview(snippetsEmptyLabel)
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
                snippetsEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                snippetsEmptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ])
        }
    }

    // MARK: Вкладка «Хоткеи»

    private func buildHotKeysTab() -> NSView {
        let header = label(L("settings.hotkeys.header"), secondary: true, wraps: true)

        // Галочки одинаковой ширины — чтобы рекордеры справа были на одной вертикали.
        let checkWidth = ceil(max(showInputHotKeyCheck.intrinsicContentSize.width,
                                  snippetsHotKeyCheck.intrinsicContentSize.width))

        func group(_ check: NSButton, _ recorder: HotKeyRecorderView,
                   hint: String, warning: NSTextField) -> NSView {
            check.translatesAutoresizingMaskIntoConstraints = false
            check.target = self
            check.action = #selector(hotKeyEnabledChanged)
            recorder.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [check, recorder])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            let hintLabel = label(hint, secondary: true, wraps: true)
            warning.textColor = .systemRed
            warning.font = .systemFont(ofSize: 11)
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 0
            warning.preferredMaxLayoutWidth = wrapWidth
            warning.isHidden = true
            warning.translatesAutoresizingMaskIntoConstraints = false
            let box = NSStackView(views: [row, hintLabel, warning])
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 2
            box.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                check.widthAnchor.constraint(equalToConstant: checkWidth),
                recorder.widthAnchor.constraint(equalToConstant: 160),
            ])
            return box
        }

        showInputHotKeyRecorder.onChange = { [weak self] k, m in
            self?.config.showInputHotKeyKeyCode = Int(k); self?.config.showInputHotKeyModifiers = Int(m)
            self?.onSave?(); self?.refreshHotKeyWarnings()
        }
        snippetsHotKeyRecorder.onChange = { [weak self] k, m in
            self?.config.snippetsHotKeyKeyCode = Int(k); self?.config.snippetsHotKeyModifiers = Int(m)
            self?.onSave?(); self?.refreshHotKeyWarnings()
        }

        let inputGroup = group(showInputHotKeyCheck, showInputHotKeyRecorder,
            hint: L("settings.hotkey.input.hint"), warning: showInputHotKeyWarning)
        let snippetsGroup = group(snippetsHotKeyCheck, snippetsHotKeyRecorder,
            hint: L("settings.hotkey.snippets.hint"), warning: snippetsHotKeyWarning)

        let accessNote = label(L("settings.hotkeys.accessNote"), secondary: true, wraps: true)

        hotKeySoundsCheck.target = self
        hotKeySoundsCheck.action = #selector(hotKeySoundsChanged)
        hotKeySoundsCheck.translatesAutoresizingMaskIntoConstraints = false

        hotKeySoundPopup.removeAllItems()
        hotKeySoundPopup.addItems(withTitles: hotKeySoundOptions.map(\.title))
        hotKeySoundPopup.target = self
        hotKeySoundPopup.action = #selector(hotKeySoundChanged)
        hotKeySoundPopup.translatesAutoresizingMaskIntoConstraints = false

        let soundsRow = NSStackView(views: [hotKeySoundsCheck, hotKeySoundPopup])
        soundsRow.orientation = .horizontal
        soundsRow.alignment = .centerY
        soundsRow.spacing = 8
        soundsRow.translatesAutoresizingMaskIntoConstraints = false

        let sep = separator()
        let soundsSep = separator()
        let stack = NSStackView(views: [header, inputGroup, snippetsGroup, sep, soundsRow, soundsSep, accessNote])
        stack.spacing = 14
        stack.setCustomSpacing(16, after: snippetsGroup)
        stack.setCustomSpacing(12, after: sep)
        stack.setCustomSpacing(12, after: soundsRow)
        stack.setCustomSpacing(12, after: soundsSep)
        return tabView(stack) { _ in
            sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            soundsSep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: Вкладка «Общие»

    private func buildGeneralTab() -> NSView {
        clipboardActionPopup.removeAllItems()
        clipboardActionPopup.addItems(withTitles: clipboardOptions.map(\.title))
        clipboardActionPopup.target = self
        clipboardActionPopup.action = #selector(clipboardOptionChanged)
        clipboardActionPopup.translatesAutoresizingMaskIntoConstraints = false

        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: languageOrder.map(\.title))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.translatesAutoresizingMaskIntoConstraints = false

        launchAtLoginCheck.target = self
        launchAtLoginCheck.action = #selector(launchAtLoginChanged)
        launchAtLoginCheck.translatesAutoresizingMaskIntoConstraints = false
        autoUpdateCheck.target = self
        autoUpdateCheck.action = #selector(autoUpdateChanged)
        autoUpdateCheck.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: L("settings.general.reset"), target: self, action: #selector(resetToDefaults))
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        let intro = label(L("settings.general.description"), secondary: true, wraps: true)

        let sep0 = separator()
        let sep1 = separator()
        let sep2 = separator()
        let stack = NSStackView(views: [
            intro,
            sep0,
            label(L("settings.general.clipboardLabel")),
            clipboardActionPopup,
            label(L("settings.general.languageLabel")),
            languagePopup,
            sep1,
            launchAtLoginCheck,
            autoUpdateCheck,
            sep2,
            resetButton,
        ])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(16, after: sep0)
        stack.setCustomSpacing(16, after: clipboardActionPopup)
        stack.setCustomSpacing(16, after: languagePopup)
        stack.setCustomSpacing(16, after: sep1)
        stack.setCustomSpacing(16, after: autoUpdateCheck)
        stack.setCustomSpacing(16, after: sep2)
        return tabView(stack) { _ in
            sep0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            sep1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            sep2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: Вкладка «О приложении»

    /// Ссылка на репозиторий проекта (открывается в браузере).
    private static let repositoryURL = URL(string: "https://github.com/ilyabazhenov/Hopkey")!

    private func buildAboutTab() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let name = NSTextField(labelWithString: "Hopkey")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        name.translatesAutoresizingMaskIntoConstraints = false

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionLabel = label(version.isEmpty ? "" : L("settings.about.version", version), secondary: true)

        let tagline = label(L("settings.about.tagline"), secondary: true)

        let updateButton = NSButton(title: L("settings.about.checkUpdates"), target: self, action: #selector(checkForUpdates))
        updateButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: L("settings.about.checkUpdates"))
        updateButton.imagePosition = .imageLeading
        updateButton.translatesAutoresizingMaskIntoConstraints = false

        let gitButton = NSButton(title: L("settings.about.github"), target: self, action: #selector(openRepository))
        gitButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: L("settings.about.github"))
        gitButton.imagePosition = .imageLeading
        gitButton.translatesAutoresizingMaskIntoConstraints = false

        let copyright = label(L("settings.about.copyright"), secondary: true)

        let stack = NSStackView(views: [icon, name, versionLabel, tagline, updateButton, gitButton, copyright])
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(16, after: tagline)
        stack.setCustomSpacing(8, after: updateButton)
        stack.setCustomSpacing(16, after: gitButton)
        let view = tabView(stack)
        stack.alignment = .centerX  // центрируем «визитку» по горизонтали
        return view
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    // MARK: - Таблица

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === snippetsTableView ? snippets.count : templates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === snippetsTableView {
            return snippetCell(tableColumn: tableColumn, row: row)
        }
        guard let tableColumn, templates.indices.contains(row) else { return nil }
        let template = templates[row]
        let id = tableColumn.identifier

        if id == Column.enabled {
            let check = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton)
                ?? makeCheckbox()
            check.tag = row
            check.state = template.enabled ? .on : .off
            return check
        }

        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? makeLabelCell(identifier: id)
        switch id {
        case Column.name:
            field.stringValue = template.displayName
        case Column.pattern:
            field.stringValue = template.pattern
            // Невалидный шаблон подсвечиваем красным (на случай ручной правки конфига).
            field.textColor = template.isValid ? .secondaryLabelColor : .systemRed
        default:
            break
        }
        return field
    }

    /// Чекбокс-ячейка «вкл». Без заголовка — он в шапке колонки.
    private func makeCheckbox() -> NSButton {
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
        check.identifier = Column.enabled
        check.imagePosition = .imageOnly
        return check
    }

    /// Ячейка строки сниппета: имя обычным цветом, значение — приглушёнными точками
    /// (значение в Keychain не показываем; увидеть/изменить — в редакторе).
    private func snippetCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, snippets.indices.contains(row) else { return nil }
        let id = tableColumn.identifier
        let field = (snippetsTableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? makeLabelCell(identifier: id)
        if id == SnippetColumn.name {
            field.stringValue = snippets[row].displayName
            field.textColor = .labelColor
        } else {
            field.stringValue = "••••••"
            field.textColor = .secondaryLabelColor
        }
        return field
    }

    /// Текстовая ячейка-метка (только для показа; правка — в редакторе).
    private func makeLabelCell(identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let field = NSTextField()
        // Свой cell центрирует текст по вертикали: иначе в строке высотой 24 он
        // прижимается к верхнему краю. Замена cell сбрасывает дефолты — выставляем явно.
        field.cell = VerticallyCenteredTextFieldCell()
        field.identifier = identifier
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.font = identifier == Column.pattern ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                                                  : .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === snippetsTableView {
            let hasSelection = snippetsTableView.selectedRow >= 0
            snippetRemoveButton.isEnabled = hasSelection
            snippetEditButton.isEnabled = hasSelection
            return
        }
        let hasSelection = tableView.selectedRow >= 0
        removeButton.isEnabled = hasSelection
        editButton.isEnabled = hasSelection
    }

    /// Показывает подсказку по центру таблицы, только пока шаблонов нет.
    private func updateEmptyState() {
        emptyStateLabel.isHidden = !templates.isEmpty
    }

    /// Показывает подсказку по центру списка сниппетов, пока он пуст.
    private func updateSnippetsEmptyState() {
        snippetsEmptyLabel.isHidden = !snippets.isEmpty
    }

    /// Подгружает список сниппетов в таблицу. Первый вызов лениво читает блоб из Keychain
    /// (возможен запрос доступа к связке) — поэтому зовём его при показе вкладки «Сниппеты»,
    /// а не при открытии окна настроек.
    private func refreshSnippetsTab() {
        snippets = snippetStore.snippets
        snippetsTableView.reloadData()
        updateSnippetsEmptyState()
        snippetRemoveButton.isEnabled = false
        snippetEditButton.isEnabled = false
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard templates.indices.contains(sender.tag) else { return }
        templates[sender.tag].enabled = sender.state == .on
        commitTemplates()
    }

    /// Каждый рекордер активен только при включённой своей галочке.
    private func updateDependentControls() {
        showInputHotKeyRecorder.isEnabled = showInputHotKeyCheck.state == .on
        snippetsHotKeyRecorder.isEnabled = snippetsHotKeyCheck.state == .on
        hotKeySoundPopup.isEnabled = hotKeySoundsCheck.state == .on
    }

    // MARK: - Мгновенное применение

    /// Сохраняет рабочий список шаблонов в конфиг и переприменяет настройки.
    private func commitTemplates() {
        config.templates = templates.filter(\.isValid)
        onSave?()
    }

    @objc private func hotKeyEnabledChanged() {
        config.showInputHotKeyEnabled = showInputHotKeyCheck.state == .on
        config.snippetsHotKeyEnabled = snippetsHotKeyCheck.state == .on
        updateDependentControls()
        onSave?()
        refreshHotKeyWarnings()
    }

    @objc private func hotKeySoundsChanged() {
        config.hotKeySoundsEnabled = hotKeySoundsCheck.state == .on
        updateDependentControls()
    }

    @objc private func hotKeySoundChanged() {
        let index = hotKeySoundPopup.indexOfSelectedItem
        guard hotKeySoundOptions.indices.contains(index) else { return }
        let sound = hotKeySoundOptions[index].sound
        config.hotKeySound = sound
        HotKeySoundFeedback.play(sound)
    }

    /// Обновляет предупреждения под рекордерами. Два источника: (1) система отказала в
    /// регистрации — комбинация реально занята; (2) эвристика «опасной по конструкции»
    /// комбинации без ⌃/⌥ (Carbon регистрирует и `⌘C`, не сообщая о конфликте, поэтому
    /// её ловим сами). Выключенный хоткей предупреждения не показывает.
    private func refreshHotKeyWarnings() {
        let status = hotKeyStatus?() ?? (input: false, snippets: false)
        applyHotKeyWarning(showInputHotKeyWarning,
                           enabled: showInputHotKeyCheck.state == .on,
                           failed: status.input,
                           modifiers: UInt32(config.showInputHotKeyModifiers))
        applyHotKeyWarning(snippetsHotKeyWarning,
                           enabled: snippetsHotKeyCheck.state == .on,
                           failed: status.snippets,
                           modifiers: UInt32(config.snippetsHotKeyModifiers))
    }

    private func applyHotKeyWarning(_ label: NSTextField, enabled: Bool,
                                    failed: Bool, modifiers: UInt32) {
        guard enabled else { label.isHidden = true; return }
        if failed {
            label.stringValue = L("settings.hotkey.conflict")
            label.isHidden = false
        } else if hotKeyLikelyConflicts(modifiers: modifiers) {
            label.stringValue = L("settings.hotkey.risky")
            label.isHidden = false
        } else {
            label.isHidden = true
        }
    }

    @objc private func clipboardOptionChanged() {
        let i = clipboardActionPopup.indexOfSelectedItem
        guard clipboardOptions.indices.contains(i) else { return }
        config.autoOpen = clipboardOptions[i].autoOpen
        config.clipboardAction = clipboardOptions[i].action
        onSave?()
    }

    @objc private func launchAtLoginChanged() {
        LaunchAtLogin.setEnabled(launchAtLoginCheck.state == .on)
    }

    /// Применяет выбранный язык к домену приложения и предлагает перезапуск
    /// (AppKit читает язык только при старте). Выбор того же языка — ничего не делаем.
    @objc private func languageChanged() {
        let index = languagePopup.indexOfSelectedItem
        guard languageOrder.indices.contains(index) else { return }
        let language = languageOrder[index]
        guard language != AppLanguage.current else { return }
        language.apply()
        promptLanguageRestart()
    }

    /// Спрашивает, перезапустить ли сейчас, чтобы новый язык вступил в силу.
    private func promptLanguageRestart() {
        let alert = NSAlert()
        alert.messageText = L("settings.language.restartTitle")
        alert.informativeText = L("settings.language.restartMessage")
        alert.addButton(withTitle: L("settings.language.restartNow"))
        alert.addButton(withTitle: L("settings.language.later"))

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Self.relaunch()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    /// Перезапускает приложение: запускает новый экземпляр `.app` и завершает текущий.
    /// В dev-сборке без бандла (.app нет) просто завершаемся — перезапуск вручную/через watch.
    private static func relaunch() {
        if Bundle.main.bundleIdentifier != nil {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", Bundle.main.bundleURL.path]
            try? task.run()
        }
        NSApp.terminate(nil)
    }

    @objc private func autoUpdateChanged() {
        updater.automaticallyChecksForUpdates = autoUpdateCheck.state == .on
    }

    // MARK: - Создание/редактирование шаблонов

    /// Открывает модальный редактор; по «Сохранить» отдаёт готовый шаблон в `onSave`.
    private func presentEditor(for template: LinkTemplate?, onSave: @escaping (LinkTemplate) -> Void) {
        guard let window else { return }
        let editor = TemplateEditorWindowController(template: template)
        guard let sheet = editor.window else { return }
        templateEditor = editor
        window.beginSheet(sheet) { [weak self] response in
            defer { self?.templateEditor = nil }
            guard response == .OK, let result = editor.result else { return }
            onSave(result)
        }
    }

    @objc private func addRow() {
        presentEditor(for: nil) { [weak self] template in self?.appendTemplate(template) }
    }

    @objc private func editSelectedRow() {
        let row = tableView.selectedRow
        guard templates.indices.contains(row) else { return }
        presentEditor(for: templates[row]) { [weak self] template in
            guard let self, self.templates.indices.contains(row) else { return }
            self.templates[row] = template
            self.tableView.reloadData()
            self.commitTemplates()
        }
    }

    /// Показывает меню пресетов под кнопкой; выбор открывает редактор с заготовкой.
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
        presentEditor(for: LinkTemplate.presets[sender.tag]) { [weak self] template in
            self?.appendTemplate(template)
        }
    }

    /// Добавляет шаблон в список, выделяет его и сохраняет.
    private func appendTemplate(_ template: LinkTemplate) {
        templates.append(template)
        tableView.reloadData()
        updateEmptyState()
        let row = templates.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        commitTemplates()
    }

    @objc private func removeSelectedRow() {
        let row = tableView.selectedRow
        guard templates.indices.contains(row) else { return }
        let name = templates[row].displayName
        confirmDelete(title: L("settings.templates.deleteTitle", name),
                      message: L("settings.templates.deleteMessage")) { [weak self] in
            guard let self, self.templates.indices.contains(row) else { return }
            self.templates.remove(at: row)
            self.tableView.reloadData()
            self.updateEmptyState()
            let hasSelection = self.tableView.selectedRow >= 0
            self.removeButton.isEnabled = hasSelection
            self.editButton.isEnabled = hasSelection
            self.commitTemplates()
        }
    }

    /// Спрашивает подтверждение перед необратимым удалением. По умолчанию активна кнопка
    /// «Отмена» (Enter не удаляет случайно), деструктивная кнопка — слева.
    private func confirmDelete(title: String, message: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: L("common.delete"))
        let cancelButton = alert.addButton(withTitle: L("common.cancel"))
        if #available(macOS 11.0, *) { deleteButton.hasDestructiveAction = true }
        // Дефолт (Enter) — «Отмена», а не «Удалить»: безопаснее для деструктивного действия.
        deleteButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    // MARK: - Создание/редактирование сниппетов

    /// Открывает модальный редактор сниппета; по «Сохранить» сразу пишет результат
    /// (метаданные + значение) в `SnippetStore` и обновляет список.
    private func presentSnippetEditor(for snippet: Snippet?) {
        guard let window else { return }
        let currentValue = snippet.flatMap { snippetStore.value(for: $0.id) } ?? ""
        let editor = SnippetEditorWindowController(snippet: snippet, value: currentValue)
        guard let sheet = editor.window else { return }
        snippetEditor = editor
        window.beginSheet(sheet) { [weak self] response in
            defer { self?.snippetEditor = nil }
            guard let self, response == .OK, let result = editor.result else { return }
            self.snippetStore.upsert(result.snippet, value: result.value)
            self.snippets = self.snippetStore.snippets
            self.snippetsTableView.reloadData()
            self.updateSnippetsEmptyState()
            if let row = self.snippets.firstIndex(where: { $0.id == result.snippet.id }) {
                self.snippetsTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.snippetsTableView.scrollRowToVisible(row)
            }
            self.onSave?()
        }
    }

    @objc private func addSnippet() {
        presentSnippetEditor(for: nil)
    }

    @objc private func editSelectedSnippet() {
        let row = snippetsTableView.selectedRow
        guard snippets.indices.contains(row) else { return }
        presentSnippetEditor(for: snippets[row])
    }

    @objc private func removeSelectedSnippet() {
        let row = snippetsTableView.selectedRow
        guard snippets.indices.contains(row) else { return }
        let snippet = snippets[row]
        confirmDelete(title: L("settings.snippets.deleteTitle", snippet.displayName),
                      message: L("settings.snippets.deleteMessage")) { [weak self] in
            guard let self else { return }
            self.snippetStore.delete(id: snippet.id)
            self.snippets = self.snippetStore.snippets
            self.snippetsTableView.reloadData()
            self.updateSnippetsEmptyState()
            let hasSelection = self.snippetsTableView.selectedRow >= 0
            self.snippetRemoveButton.isEnabled = hasSelection
            self.snippetEditButton.isEnabled = hasSelection
            self.onSave?()
        }
    }

    // MARK: - Загрузка / показ

    func loadValues() {
        templates = config.templates
        tableView.reloadData()
        updateEmptyState()
        removeButton.isEnabled = false
        editButton.isEnabled = false

        // Список сниппетов НЕ читаем здесь: он подгружается лениво при показе вкладки
        // «Сниппеты» (см. `refreshSnippetsTab`), чтобы открытие других вкладок не дёргало
        // запрос доступа к связке ключей.

        let i = clipboardOptions.firstIndex { $0.autoOpen == config.autoOpen && $0.action == config.clipboardAction } ?? 0
        clipboardActionPopup.selectItem(at: i)

        languagePopup.selectItem(at: languageOrder.firstIndex(of: AppLanguage.current) ?? 0)

        showInputHotKeyCheck.state = config.showInputHotKeyEnabled ? .on : .off
        showInputHotKeyRecorder.combo = (UInt32(config.showInputHotKeyKeyCode), UInt32(config.showInputHotKeyModifiers))
        snippetsHotKeyCheck.state = config.snippetsHotKeyEnabled ? .on : .off
        snippetsHotKeyRecorder.combo = (UInt32(config.snippetsHotKeyKeyCode), UInt32(config.snippetsHotKeyModifiers))
        hotKeySoundsCheck.state = config.hotKeySoundsEnabled ? .on : .off
        let soundIndex = hotKeySoundOptions.firstIndex { $0.sound == config.hotKeySound } ?? 0
        hotKeySoundPopup.selectItem(at: soundIndex)
        launchAtLoginCheck.state = LaunchAtLogin.isEnabled ? .on : .off
        autoUpdateCheck.state = updater.automaticallyChecksForUpdates ? .on : .off
        updateDependentControls()
        refreshHotKeyWarnings()
    }

    func showWindow() {
        loadValues()
        // Если повторно открываемся уже на вкладке «Сниппеты» (show(_:) при этом не
        // вызывается) — подгрузим её данные сами.
        if currentTab == .snippets { refreshSnippetsTab() }
        // Пока открыто окно настроек, приложение становится обычным (.regular):
        // появляется иконка в Dock и оно участвует в Cmd+Tab. При закрытии окна
        // (`windowWillClose`) возвращаемся к .accessory — снова только строка меню.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Сбрасывает все настройки к значениям по умолчанию после подтверждения,
    /// перечитывает поля окна и применяет изменения (через `onSave`), не закрывая окно.
    @objc private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = L("settings.reset.title")
        alert.informativeText = L("settings.reset.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("settings.reset.confirm"))
        alert.addButton(withTitle: L("common.cancel"))

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

/// Текстовая ячейка, центрирующая содержимое по вертикали. Нужна в списке шаблонов,
/// где высота строки (24) больше высоты текста, а `NSTextFieldCell` по умолчанию
/// прижимает текст к верхнему краю.
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
}

/// Кнопка-вкладка в тулбаре: иконка над подписью, фиксированная ширина (чтобы все
/// вкладки были одинаковой ширины независимо от длины текста) и подсветка выбранной.
/// Стандартный `NSToolbarItem` так не умеет — он подгоняет ширину под свой текст,
/// поэтому длинная «О приложении» оказывалась заметно шире остальных.
private final class TabButton: NSView {
    /// Подложка-подсветка: скруглённый прямоугольник с отступами от краёв кнопки —
    /// чтобы на крайней вкладке выделение не упиралось углами в «пилюлю» тулбара
    /// (та скруглена сильнее), а плавало внутри, как в системных «Настройках».
    private let highlightView = NSView()
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let onClick: () -> Void

    var isSelected = false { didSet { updateAppearance() } }

    init(symbol: String, title: String, width: CGFloat, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 6
        highlightView.translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlightView)  // под иконкой и подписью
        addSubview(imageView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            // Подсветка с отступами от краёв кнопки.
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func mouseDown(with event: NSEvent) { onClick() }

    /// Цвета зависят от системной акцентной/темы — перечитываем при их смене.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let tint: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        imageView.contentTintColor = tint
        titleLabel.textColor = tint
        highlightView.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
    }
}
