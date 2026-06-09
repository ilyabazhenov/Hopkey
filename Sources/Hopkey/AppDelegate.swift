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
            HotKeyManager.ensureAccessibility(prompt: false)
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
            matches = TicketParser.matches(in: text, projects: config.projects)
        case .clipboard:
            // Автонаблюдение: срабатываем, только если в буфере ровно ключ тикета.
            // Случайно скопированная ссылка или текст с ключом внутри не должны открывать браузер.
            matches = TicketParser.exactMatch(in: text, projects: config.projects).map { [$0] } ?? []
        }
        guard !matches.isEmpty else { return }

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

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

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
            button.toolTip = "Hopkey — открыть тикет по ключу"
        }
        // Меню статично: действия с буфером и служебные пункты. Все переключатели
        // (авто-открытие, хоткеи, запуск при входе) живут в окне «Настройки…».
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть тикет из буфера", action: #selector(openFromClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Скопировать ссылку из буфера", action: #selector(copyFromClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        // macOS сам опознаёт «Настройки…» как стандартный пункт и навешивает
        // шестерёнку (gearshape). Любая иконка у одного пункта заставляет NSMenu
        // зарезервировать колонку под картинки и сдвинуть текст всех пунктов вправо.
        // image = nil здесь не держится: система перерисовывает иконку при показе,
        // поэтому окончательно гасим её в menuNeedsUpdate (см. NSMenuDelegate ниже).
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Проверить обновления…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "")

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
              case let matches = TicketParser.matches(in: text, projects: config.projects),
              !matches.isEmpty else {
            NSSound.beep()
            return
        }
        perform(action, on: matches)
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
            HotKeyManager.ensureAccessibility(prompt: true)
            registerHotKeys()
        } else {
            hotKey.unregisterAll()
        }
    }

    private var anyHotKeyEnabled: Bool {
        config.openHotKeyEnabled || config.copyHotKeyEnabled
    }

    /// Перерегистрирует оба хоткея с актуальными комбинациями из конфига.
    /// Каждый регистрируется только если включён; id 1 — открыть, id 2 — скопировать.
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
