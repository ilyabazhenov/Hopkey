import AppKit
import ServiceManagement
import HopkeyCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = JiraConfig.shared
    private var statusItem: NSStatusItem!
    private let clipboard = ClipboardWatcher()
    private let hotKey = HotKeyManager()
    private let notifications = NotificationManager()
    private lazy var settings = SettingsWindowController(config: config)

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

        hotKey.onCapture = { [weak self] text in self?.handle(text, source: .hotkey) }
        if config.hotKeyEnabled {
            HotKeyManager.ensureAccessibility(prompt: false)
            registerHotKey()
        }

        settings.onSave = { [weak self] in self?.applyConfig() }

        // Первый запуск без настроек — сразу открываем окно настроек.
        if !config.isConfigured {
            settings.showWindow()
        }
    }

    // MARK: - Обработка текста

    private func handle(_ text: String, source: Source) {
        let matches = TicketParser.matches(in: text, prefixes: config.prefixes, baseURL: config.baseURL)
        guard !matches.isEmpty else { return }

        let joined = matches.map(\.id).joined(separator: ",")
        if joined == lastHandledText, Date().timeIntervalSince(lastHandledAt) < 2 {
            clipboard.syncChangeCount()
            return
        }
        lastHandledText = joined
        lastHandledAt = Date()

        // Хоткей — явное намерение пользователя, поэтому открываем сразу.
        if source == .hotkey || config.autoOpen {
            URLOpener.open(matches.map(\.url))
        } else {
            notifications.notify(matches: matches)
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
            button.image = NSImage(systemSymbolName: "ticket", accessibilityDescription: "Hopkey")
            button.image?.isTemplate = true
            button.toolTip = "Hopkey — открыть тикет по ключу"
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть тикет из буфера", action: #selector(openFromClipboard), keyEquivalent: "")
        menu.addItem(.separator())

        let autoOpenItem = NSMenuItem(title: "Открывать сразу", action: #selector(toggleAutoOpen), keyEquivalent: "")
        autoOpenItem.state = config.autoOpen ? .on : .off
        menu.addItem(autoOpenItem)

        let hotKeyTitle = "Глобальный хоткей \(hotKeyDisplayString(keyCode: UInt32(config.hotKeyKeyCode), modifiers: UInt32(config.hotKeyModifiers)))"
        let hotKeyItem = NSMenuItem(title: hotKeyTitle, action: #selector(toggleHotKey), keyEquivalent: "")
        hotKeyItem.state = config.hotKeyEnabled ? .on : .off
        menu.addItem(hotKeyItem)

        let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    // MARK: - Действия меню

    @objc private func openFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              case let matches = TicketParser.matches(in: text, prefixes: config.prefixes, baseURL: config.baseURL),
              !matches.isEmpty else {
            NSSound.beep()
            return
        }
        URLOpener.open(matches.map(\.url))
    }

    @objc private func toggleAutoOpen() {
        config.autoOpen.toggle()
        rebuildMenu()
    }

    @objc private func toggleHotKey() {
        if config.hotKeyEnabled {
            config.hotKeyEnabled = false
            hotKey.unregister()
        } else {
            config.hotKeyEnabled = true
            HotKeyManager.ensureAccessibility(prompt: true)
            registerHotKey()
        }
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login error: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func openSettings() {
        settings.showWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Применение настроек

    private func applyConfig() {
        if config.hotKeyEnabled {
            HotKeyManager.ensureAccessibility(prompt: true)
            registerHotKey()
        } else {
            hotKey.unregister()
        }
        rebuildMenu()
    }

    /// Перерегистрирует хоткей с актуальной комбинацией из конфига.
    private func registerHotKey() {
        hotKey.unregister()
        hotKey.register(keyCode: UInt32(config.hotKeyKeyCode),
                        modifiers: UInt32(config.hotKeyModifiers))
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
