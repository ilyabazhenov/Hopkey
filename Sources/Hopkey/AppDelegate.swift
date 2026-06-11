import AppKit
import HopkeyCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = JiraConfig.shared
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

    // Защита от двойной обработки одного и того же текста
    // (наш синтетический Cmd+C виден и наблюдателю буфера тоже).
    private var lastHandledText: String?
    private var lastHandledAt: Date = .distantPast

    private enum Source { case clipboard, hotkey }

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications.requestAuthorization()
        setupMainMenu()
        setupStatusItem()

        clipboard.onChange = { [weak self] text in self?.handle(text, source: .clipboard) }
        clipboard.start()

        hotKey.onCapture = { [weak self] text, action in
            self?.handle(text, source: .hotkey, hotKeyAction: action)
        }
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

    private func handle(_ text: String, source: Source, hotKeyAction: TicketAction? = nil) {
        let matches: [TicketMatch]
        switch source {
        case .hotkey:
            // Хоткей — явное намерение: извлекаем ключи из произвольного выделенного текста.
            matches = TicketParser.matches(in: text, templates: config.templates)
        case .clipboard:
            // Автонаблюдение: срабатываем, только если в буфере ровно ключ тикета.
            // Случайно скопированная ссылка или текст с ключом внутри не должны открывать браузер.
            matches = TicketParser.exactMatch(in: text, templates: config.templates).map { [$0] } ?? []
        }
        guard !matches.isEmpty else {
            // Хоткей над голым числом ничего не сматчил (у шаблонов нужен префикс),
            // но это похоже на номер тикета — открываем окно ввода с подставленным
            // числом и выбором шаблона. Выделение уже прочитано, новых разрешений не нужно.
            if source == .hotkey { offerQuickInputForBareNumber(text) }
            return
        }

        let joined = matches.map(\.id).joined(separator: ",")
        if joined == lastHandledText, Date().timeIntervalSince(lastHandledAt) < 2 {
            clipboard.syncChangeCount()
            return
        }
        lastHandledText = joined
        lastHandledAt = Date()

        // Хоткей — явное намерение пользователя, поэтому выполняем действие сразу.
        // Для хоткея действие приходит от сработавшей комбинации, для буфера — из настроек.
        let action = source == .hotkey ? (hotKeyAction ?? .openInBrowser) : config.clipboardAction
        if source == .hotkey || config.autoOpen {
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

    /// Если хоткей над выделением ничего не сматчил, но выделено голое число —
    /// открываем окно ввода с этим числом (используем уже прочитанное выделение).
    private func offerQuickInputForBareNumber(_ text: String) {
        guard let number = bareNumber(text),
              !QuickTicketInput.fillableTemplates(in: config.templates).isEmpty else { return }
        clipboard.syncChangeCount()  // наш синтетический Cmd+C не должен будить наблюдателя
        quickTicket.showWindow(prefill: number)
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
            // Accessibility нужен только хоткеям над выделением (синтез Cmd+C),
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

    /// Включён ли хоть один хоткей, которому требуется Accessibility (синтез Cmd+C
    /// над выделением). Хоткей окна ввода сюда не входит — он лишь показывает окно.
    private var needsAccessibility: Bool {
        config.openHotKeyEnabled || config.copyHotKeyEnabled
    }

    /// Перерегистрирует все хоткеи с актуальными комбинациями из конфига.
    /// Каждый регистрируется только если включён; id 1 — открыть, id 2 — скопировать,
    /// id 3 — окно ручного ввода.
    private func registerHotKeys() {
        hotKey.unregisterAll()
        // Регистрируем только включённый хоткей с валидной комбинацией (есть модификатор).
        if config.openHotKeyEnabled, config.openHotKeyModifiers != 0 {
            hotKey.register(id: 1, action: .openInBrowser,
                            keyCode: UInt32(config.openHotKeyKeyCode),
                            modifiers: UInt32(config.openHotKeyModifiers))
        }
        if config.copyHotKeyEnabled, config.copyHotKeyModifiers != 0 {
            hotKey.register(id: 2, action: .copyURL,
                            keyCode: UInt32(config.copyHotKeyKeyCode),
                            modifiers: UInt32(config.copyHotKeyModifiers))
        }
        if config.showInputHotKeyEnabled, config.showInputHotKeyModifiers != 0 {
            hotKey.register(id: 3,
                            keyCode: UInt32(config.showInputHotKeyKeyCode),
                            modifiers: UInt32(config.showInputHotKeyModifiers)) { [weak self] in
                self?.openQuickTicketFromSelection()
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
