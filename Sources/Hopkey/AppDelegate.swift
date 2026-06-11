import AppKit
import HopkeyCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = JiraConfig.shared
    private let snippetStore = SnippetStore.shared
    private var statusItem: NSStatusItem!
    private let clipboard = ClipboardWatcher()
    private let hotKey = HotKeyManager()
    private let notifications = NotificationManager()
    private let updater = UpdaterController()
    private lazy var settings = SettingsWindowController(config: config, updater: updater)
    private lazy var quickTicket: QuickTicketWindowController = {
        let controller = QuickTicketWindowController(config: config)
        controller.onSubmit = { [weak self] matches, action in self?.perform(action, on: matches) }
        return controller
    }()
    private lazy var snippetPicker: SnippetPickerWindowController = {
        let controller = SnippetPickerWindowController(store: snippetStore)
        controller.onPick = { [weak self] snippet in self?.pasteSnippet(snippet) }
        controller.onCopy = { [weak self] snippet in self?.copySnippet(snippet) }
        return controller
    }()

    /// Приложение, которое было активным до показа пикера сниппетов — ему возвращаем
    /// фокус перед синтетическим Cmd+V (наш `NSApp.activate` крадёт фокус у него).
    private weak var snippetTargetApp: NSRunningApplication?

    // Защита от двойной обработки одного и того же текста
    // (наш синтетический Cmd+C виден и наблюдателю буфера тоже).
    private var lastHandledText: String?
    private var lastHandledAt: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Сниппеты НЕ читаем на старте: блоб из Keychain грузится лениво при первом
        // обращении (вкладка «Сниппеты» в настройках или первый показ пикера/вставка),
        // чтобы запрос доступа к связке не всплывал на запуске.
        notifications.requestAuthorization()
        setupMainMenu()
        setupStatusItem()

        clipboard.onChange = { [weak self] text in self?.handle(text) }
        clipboard.start()

        if anyHotKeyEnabled {
            if needsAccessibility { HotKeyManager.ensureAccessibility(prompt: false) }
            registerHotKeys()
        }

        settings.onSave = { [weak self] in self?.applyConfig() }

        // Первый запуск без настроек — сразу открываем окно настроек.
        if !config.isConfigured {
            settings.showWindow()
        }
    }

    // MARK: - Обработка текста

    /// Автонаблюдение за буфером: срабатываем, только если в буфере ровно ключ тикета
    /// (случайно скопированная ссылка или текст с ключом внутри не должны открывать браузер).
    private func handle(_ text: String) {
        guard let match = TicketParser.exactMatch(in: text, templates: config.templates) else { return }
        let matches = [match]

        let joined = matches.map(\.id).joined(separator: ",")
        if joined == lastHandledText, Date().timeIntervalSince(lastHandledAt) < 2 {
            clipboard.syncChangeCount()
            return
        }
        lastHandledText = joined
        lastHandledAt = Date()

        let action = config.clipboardAction
        if config.autoOpen {
            perform(action, on: matches)
        } else {
            // Авто-открытие выключено: спрашиваем кликом. Уведомление несёт то же
            // действие — клик по баннеру выполнит именно его (открыть или скопировать).
            notifications.notify(matches: matches, action: action)
            clipboard.syncChangeCount()
        }
    }

    /// Выполняет действие над найденными тикетами.
    /// Любая запись в буфер обязана сопровождаться `clipboard.syncChangeCount()`,
    /// иначе наблюдатель буфера увидит свою же запись с ID и зациклит обработку.
    private func perform(_ action: TicketAction, on matches: [TicketMatch]) {
        switch action {
        case .openInBrowser:
            URLOpener.open(matches.map(\.url))
        case .copyURL:
            URLOpener.copy(TicketAction.clipboardString(for: matches))
            notifications.confirmCopy(matches: matches)
        }
        clipboard.syncChangeCount()
    }

    // MARK: - Главное меню

    /// Приложение работает как `.accessory` без иконки в Dock, поэтому AppKit
    /// не создаёт стандартное меню. Без меню «Правка» системные сочетания
    /// ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z не доходят до текстовых полей через цепочку
    /// ответчиков — добавляем его явно, чтобы вставка работала в настройках.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Меню приложения. Первый пункт строки меню macOS всегда рисует как «жирное»
        // меню с именем приложения — оно нужно, когда приложение временно становится
        // .regular (открыто окно настроек): иначе первым в баре оказалась бы «Правка»,
        // и не было бы About/Скрыть/Завершить.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.app.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.app.hide"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.app.quit"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: L("menu.edit"))
        editMenu.addItem(withTitle: L("menu.edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("menu.edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("menu.edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("menu.edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("menu.edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("menu.edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Меню «Окно» — стандартные «Свернуть» / «Закрыть» и список окон, когда
        // приложение .regular. AppKit сам наполняет его открытыми окнами.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenu.addItem(withTitle: L("menu.window.minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("menu.window.close"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Строка меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "ticket", accessibilityDescription: "Hopkey")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = L("status.tooltip")
        }
        // Меню статично: действия с буфером и служебные пункты. Все переключатели
        // (авто-открытие, хоткеи, запуск при входе) живут в окне «Настройки…».
        let menu = NSMenu()
        menu.addItem(withTitle: L("status.openFromClipboard"), action: #selector(openFromClipboard), keyEquivalent: "")
        menu.addItem(withTitle: L("status.copyFromClipboard"), action: #selector(copyFromClipboard), keyEquivalent: "")
        menu.addItem(withTitle: L("status.openByKey"), action: #selector(openQuickTicket), keyEquivalent: "")
        menu.addItem(withTitle: L("status.pasteSnippet"), action: #selector(openSnippetPicker), keyEquivalent: "")
        menu.addItem(.separator())
        // macOS сам опознаёт «Настройки…» как стандартный пункт и навешивает
        // шестерёнку (gearshape). Любая иконка у одного пункта заставляет NSMenu
        // зарезервировать колонку под картинки и сдвинуть текст всех пунктов вправо.
        // image = nil здесь не держится: система перерисовывает иконку при показе,
        // поэтому окончательно гасим её в menuNeedsUpdate (см. NSMenuDelegate ниже).
        menu.addItem(withTitle: L("status.settings"), action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: L("status.checkUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("status.quit"), action: #selector(quit), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Действия меню

    @objc private func openFromClipboard() {
        actionFromClipboard(.openInBrowser)
    }

    @objc private func copyFromClipboard() {
        actionFromClipboard(.copyURL)
    }

    private func actionFromClipboard(_ action: TicketAction) {
        guard let text = NSPasteboard.general.string(forType: .string),
              case let matches = TicketParser.matches(in: text, templates: config.templates),
              !matches.isEmpty else {
            NSSound.beep()
            return
        }
        perform(action, on: matches)
    }

    @objc private func openQuickTicket() {
        // Из меню: префилл из буфера, если там голое число — без Accessibility (буфер читать можно).
        quickTicket.showWindow(prefill: clipboardBareNumber())
    }

    @objc private func openSnippetPicker() {
        showSnippetPicker()
    }

    /// Показывает окно-пикер сниппетов, запомнив активное приложение — чтобы после
    /// выбора вернуть ему фокус и вставить значение туда, где стоял курсор.
    private func showSnippetPicker() {
        snippetTargetApp = NSWorkspace.shared.frontmostApplication
        snippetPicker.show()
    }

    /// Вставляет выбранный сниппет в активное приложение: читает значение из Keychain
    /// и синтезирует Cmd+V. Пикер — неактивирующая панель, поэтому прежнее приложение
    /// фокус не теряло; целевое приложение поднимаем явно лишь для подстраховки. Короткая
    /// пауза — чтобы панель успела закрыться и вернуть ключевое окно цели. Запись в буфер
    /// «глушим» для наблюдателя.
    private func pasteSnippet(_ snippet: Snippet) {
        guard let value = snippetStore.value(for: snippet.id), !value.isEmpty else {
            NSSound.beep()
            return
        }
        let target = snippetTargetApp
        snippetTargetApp = nil

        // Без Универсального доступа синтетический Cmd+V молча не дойдёт до чужого поля.
        // Кладём значение в буфер (ручной ⌘V сработает) и показываем системный запрос
        // доступа — чтобы пользователь понимал, почему авто-вставка не случилась.
        guard HotKeyManager.ensureAccessibility(prompt: false) else {
            URLOpener.copy(value)
            clipboard.syncChangeCount()
            HotKeyManager.ensureAccessibility(prompt: true)
            return
        }

        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.hotKey.paste(value) { self.clipboard.syncChangeCount() }
        }
    }

    /// Копирует значение сниппета в буфер (без вставки). Наблюдателя буфера глушим,
    /// чтобы наша запись не считалась пользовательской.
    private func copySnippet(_ snippet: Snippet) {
        guard let value = snippetStore.value(for: snippet.id), !value.isEmpty else {
            NSSound.beep()
            return
        }
        URLOpener.copy(value)
        clipboard.syncChangeCount()
    }

    /// Хоткей окна ввода: сам снимает выделение (с сохранением буфера) и открывает окно
    /// с подставленным текстом. Если Accessibility не выдан или ничего не выделено —
    /// откатываемся к числу из буфера (или пустому окну).
    private func openQuickTicketFromSelection() {
        hotKey.captureSelection { [weak self] selection in
            guard let self else { return }
            let prefill = selection.flatMap(self.prefillToken) ?? self.clipboardBareNumber()
            // Наши манипуляции с буфером (Cmd+C + восстановление) не должны будить наблюдателя.
            self.clipboard.syncChangeCount()
            self.quickTicket.showWindow(prefill: prefill)
        }
    }

    /// Выделенный текст как кандидат на префилл: один «токен» без внутренних пробелов
    /// и не длиннее 40 символов (`PROJ-123`, `#42`, `12345`); иначе nil.
    private func prefillToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 40, !t.contains(where: \.isWhitespace) else { return nil }
        return t
    }

    /// Голое число из буфера обмена (для префилла окна ввода), иначе nil.
    private func clipboardBareNumber() -> String? {
        NSPasteboard.general.string(forType: .string).flatMap(bareNumber)
    }

    /// Текст, целиком состоящий из цифр (с обрезкой пробелов), иначе nil. Длину ограничиваем,
    /// чтобы случайная простыня цифр не считалась номером.
    private func bareNumber(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 18, t.allSatisfy(\.isNumber) else { return nil }
        return t
    }

    @objc private func openSettings() {
        settings.showWindow()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Применение настроек

    private func applyConfig() {
        if anyHotKeyEnabled {
            // Accessibility нужен только пикеру сниппетов (синтез Cmd+V в чужое поле),
            // не хоткею окна ввода — поэтому запрашиваем его лишь при необходимости.
            if needsAccessibility { HotKeyManager.ensureAccessibility(prompt: true) }
            registerHotKeys()
        } else {
            hotKey.unregisterAll()
        }
    }

    private var anyHotKeyEnabled: Bool {
        needsAccessibility || config.showInputHotKeyEnabled
    }

    /// Нужен ли Accessibility: его требует только пикер сниппетов (синтез Cmd+V при
    /// вставке в чужое поле). Хоткею окна ввода доступ не нужен — он лишь показывает окно.
    private var needsAccessibility: Bool {
        config.snippetsHotKeyEnabled
    }

    /// Перерегистрирует обе горячие клавиши с актуальными комбинациями из конфига.
    /// Каждая регистрируется только если включена; id 3 — окно ручного ввода,
    /// id 4 — пикер сниппетов.
    private func registerHotKeys() {
        hotKey.unregisterAll()
        // Регистрируем только включённый хоткей с валидной комбинацией (есть модификатор).
        if config.showInputHotKeyEnabled, config.showInputHotKeyModifiers != 0 {
            hotKey.register(id: 3,
                            keyCode: UInt32(config.showInputHotKeyKeyCode),
                            modifiers: UInt32(config.showInputHotKeyModifiers)) { [weak self] in
                self?.openQuickTicketFromSelection()
            }
        }
        if config.snippetsHotKeyEnabled, config.snippetsHotKeyModifiers != 0 {
            hotKey.register(id: 4,
                            keyCode: UInt32(config.snippetsHotKeyKeyCode),
                            modifiers: UInt32(config.snippetsHotKeyModifiers)) { [weak self] in
                self?.showSnippetPicker()
            }
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Вызывается прямо перед показом меню — последняя точка, где можно убрать
    /// авто-шестерёнку, которую macOS навешивает на пункт «Настройки…».
    /// Гасим иконки у всех пунктов, чтобы NSMenu не резервировал колонку под
    /// картинки и не сдвигал текст влево.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.image != nil {
            item.image = nil
        }
    }
}
