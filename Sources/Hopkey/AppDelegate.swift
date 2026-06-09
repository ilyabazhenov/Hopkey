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
        setupStatusItem()

        clipboard.onChange = { [weak self] text in self?.handle(text, source: .clipboard) }
        clipboard.start()

        hotKey.onCapture = { [weak self] text in self?.handle(text, source: .hotkey) }
        if config.hotKeyEnabled {
            HotKeyManager.ensureAccessibility(prompt: false)
            hotKey.register()
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

        let hotKeyItem = NSMenuItem(title: "Глобальный хоткей ⌃⌥J", action: #selector(toggleHotKey), keyEquivalent: "")
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
            hotKey.register()
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
            hotKey.register()
        } else {
            hotKey.unregister()
        }
        rebuildMenu()
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
