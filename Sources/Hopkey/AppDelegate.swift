import AppKit
import CoreAudio
import HopkeyCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = JiraConfig.shared
    private let snippetStore = SnippetStore.shared
    private var statusItem: NSStatusItem!
    private let clipboard = ClipboardWatcher()
    private let hotKey = HotKeyManager()
    private let notifications = NotificationManager()
    private let updater = UpdaterController()
    private let mic = MicrophoneController()
    private let keepAwake = KeepAwakeController()
    private let audio = AudioDeviceController()
    private let ocr = OCRController()
    private let hud = HUDWindowController()
    /// История буфера обмена (только в памяти), для быстрой повторной вставки из панели.
    private let clipboardHistory = ClipboardHistory()
    /// Индекс установленных приложений для строки поиска палитры (сканируется лениво в фоне).
    private let appIndex = AppSearchIndex()
    /// Монитор нажатий модификаторов + детектор двойного тапа для вызова панели.
    /// Пересоздаются при смене триггера (см. `setupPaletteTrigger`).
    private var flagsMonitor: FlagsChangedMonitor?
    private var doubleTapDetector: DoubleTapDetector?
    private lazy var commandPanel: CommandPanelWindowController = {
        let controller = CommandPanelWindowController()
        // Действие над сниппетом из панели (первичное по клику, вторичное по кнопкам).
        controller.onSnippetActivation = { [weak self] snippet, activation in
            self?.dispatchSnippet(snippet, activation)
        }
        // При закрытии панели сбрасываем состояние жеста-триггера: пока панель была ключевой,
        // монитор не видел отпускание правого ⌘ — иначе следующий двойной тап не сработает.
        controller.onClose = { [weak self] in
            self?.panelIsOpen = false
            self?.flagsMonitor?.resetGesture()
        }
        // Строка поиска палитры: приложения ищем через индекс, запуск — NSWorkspace, результат
        // калькулятора копируем в буфер + историю с HUD-обратной связью.
        controller.searchApps = { [weak self] query in self?.appIndex.search(query) ?? [] }
        controller.onLaunchApp = { url in NSWorkspace.shared.open(url) }
        controller.onCopyValue = { [weak self] value in
            guard let self else { return }
            URLOpener.copy(value)
            self.clipboard.syncChangeCount()
            self.clipboardHistory.record(value)
            self.hud.show(symbol: "equal.circle.fill", message: L("panel.search.copied", value))
        }
        // Команды-инструменты, разворачивающиеся внутри палитры (transform и др.) — панель остаётся.
        controller.onPresentCommandModule = { [weak self] command in
            self?.presentCommandModule(command) ?? false
        }
        return controller
    }()

    /// Модуль преобразования текста внутри палитры (см. `presentTransformModule`). Тот же результат
    /// вставляет `pasteTransform`, что и у fallback-окна.
    private lazy var transformModule: TransformModule = {
        let module = TransformModule()
        module.onApply = { [weak self] result in self?.pasteTransform(result) }
        return module
    }()

    /// Разворачивает инструмент команды прямо в палитре. Возвращает true, если команда — модульная.
    private func presentCommandModule(_ command: ToolboxCommand) -> Bool {
        switch command.id {
        case .textTransform:    presentTransformModule(); return true
        case .clipboardHistory: presentClipboardHistory(); return true
        case .audioOutput:      presentAudioOutput(); return true
        case .audioInput:       presentAudioInput(); return true
        default: return false
        }
    }

    /// Показывает transform как модуль палитры (палитра уже открыта и ключевая). Захват выделения —
    /// как в `openTextTransforms`: палитра неактивирующая, фронтовым остаётся целевое приложение,
    /// поэтому синтетический Cmd+C уходит туда. Приложение НЕ активируем — фокус уже у палитры.
    private func presentTransformModule() {
        snippetTargetApp = NSWorkspace.shared.frontmostApplication
        guard HotKeyManager.ensureAccessibility(prompt: false) else {
            transformModule.prefill(NSPasteboard.general.string(forType: .string) ?? "")
            commandPanel.enterModule(transformModule)
            HotKeyManager.ensureAccessibility(prompt: true)
            return
        }
        hotKey.captureSelection { [weak self] selection in
            guard let self else { return }
            self.clipboard.syncChangeCount()
            self.transformModule.prefill(selection ?? "")
            self.commandPanel.enterModule(self.transformModule)
        }
    }
    /// Реестр команд тулбокса — единый источник для меню, панели и хоткеев.
    private lazy var commands: [ToolboxCommand] = buildCommands()
    /// Команды, чью прямую комбинацию не удалось зарегистрировать (занята).
    private var failedCommandHotKeys: Set<CommandID> = []
    /// Открыта ли сейчас панель команд (для toggle двойным тапом: открыть/закрыть).
    private var panelIsOpen = false
    private lazy var settings: SettingsWindowController = {
        let controller = SettingsWindowController(config: config, updater: updater)
        // Окно настроек само опрашивает статус регистрации, чтобы показать предупреждение
        // под рекордером, если комбинация занята. Pull-модель: не дёргаем (ленивое) окно
        // из AppDelegate, оно само спросит после применения изменений.
        controller.hotKeyStatus = { [weak self] in self?.failedCommandHotKeys ?? [] }
        return controller
    }()
    private lazy var quickTicket: QuickTicketWindowController = {
        let controller = QuickTicketWindowController(config: config)
        controller.onSubmit = { [weak self] matches, action in self?.perform(action, on: matches) }
        return controller
    }()
    private lazy var snippetPicker: SnippetPickerWindowController = {
        let controller = SnippetPickerWindowController(store: snippetStore)
        controller.onPick = { [weak self] snippet in self?.pasteSnippet(snippet) }
        controller.onCopy = { [weak self] snippet in self?.copySnippet(snippet) }
        controller.onOpen = { [weak self] snippet in self?.openSnippet(snippet) }
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

        // Иконка статус-бара отражает мьют микрофона (перечёркнутый микрофон при мьюте).
        mic.onStateChange = { [weak self] _ in self?.updateStatusIcon() }

        clipboard.onChange = { [weak self] text in self?.handle(text) }
        clipboard.start()

        if anyHotKeyEnabled {
            if needsAccessibility { HotKeyManager.ensureAccessibility(prompt: false) }
            registerHotKeys()
        }
        setupPaletteTrigger()

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
        // Пишем в историю буфера все пользовательские копии, кроме «скрытых» (пароль-менеджеры).
        if !clipboardIsConcealed() { clipboardHistory.record(text) }

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
        // Меню НЕ вешаем на statusItem: левый клик открывает панель команд, правый / ⌥-клик —
        // меню (см. `statusItemClicked`). Иначе AppKit сам открывал бы меню на любой клик.
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = L("status.tooltip")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusIcon()
    }

    /// Иконка статус-бара: перечёркнутый микрофон при мьюте (индикатор состояния без открытия
    /// панели), иначе штатная брендовая марка. Меню-бар рисует template-иконку монохромно.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let image: NSImage?
        if mic.isMuted {
            image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: L("status.micMuted"))
        } else {
            image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "ticket", accessibilityDescription: "Hopkey")
        }
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
    }

    /// Левый клик — панель команд; правый или ⌥-клик — меню со служебными пунктами.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.option) ?? false)
        if wantsMenu {
            showStatusMenu()
        } else {
            openCommandPanel()
        }
    }

    /// Показывает меню под иконкой нативно: временно вешаем его на statusItem и «кликаем».
    private func showStatusMenu() {
        let menu = buildStatusMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // снимаем, чтобы левый клик снова открывал панель
    }

    /// Меню статус-бара строится из реестра команд (с состоянием тумблеров) + служебные пункты.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self  // menuNeedsUpdate переустанавливает иконку «Настройки…» (macOS её затирает)
        addStatusItem(menu, L("status.openFromClipboard"), #selector(openFromClipboard), symbol: "arrow.up.forward.app")
        addStatusItem(menu, L("status.copyFromClipboard"), #selector(copyFromClipboard), symbol: "doc.on.clipboard")
        menu.addItem(.separator())
        for command in commands {
            let item = menu.addItem(withTitle: command.title(),
                                    action: #selector(runCommandFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.id.rawValue
            let image = NSImage(systemSymbolName: command.symbol(), accessibilityDescription: command.title())
            image?.isTemplate = true
            item.image = image
            if command.isOn() == true { item.state = .on }
        }
        menu.addItem(.separator())
        addStatusItem(menu, L("status.settings"), #selector(openSettings), symbol: "gearshape")
        addStatusItem(menu, L("status.checkUpdates"), #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath")
        menu.addItem(.separator())
        addStatusItem(menu, L("status.quit"), #selector(quit), symbol: "power")
        return menu
    }

    @objc private func runCommandFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = CommandID(rawValue: raw),
              let command = commands.first(where: { $0.id == id }) else { return }
        command.run()
    }

    /// Открывает панель команд с актуальным набором. Неактивирующая панель не крадёт фокус
    /// у переднего приложения — важно для вставки/сниппетов.
    /// Двойной тап: если панель открыта — закрыть, иначе открыть.
    private func togglePanel() {
        if panelIsOpen {
            commandPanel.close()
        } else {
            openCommandPanel()
        }
    }

    private func openCommandPanel() {
        // Прогреваем индекс приложений (однократно, в фоне) — к первому вводу в поиск он готов.
        appIndex.warmUp()
        // Сбрасываем состояние жеста: нажатие, открывшее панель, оставило правый ⌘ «зажатым»
        // в трекере (отпускание уйдёт уже в ключевую панель, мимо монитора).
        flagsMonitor?.resetGesture()
        // Запоминаем активное приложение — сниппет/paste вставятся туда, где стоял курсор.
        snippetTargetApp = NSWorkspace.shared.frontmostApplication
        // Сниппеты показываем построчно (каждый в один клик), поэтому лончер сниппетов из
        // панели убираем; ⌃⌥V по-прежнему открывает полный пикер. Аудиовыход/вход в панели живут
        // выпадашкой прямо в слайдерах, поэтому одноимённые действия из грида тоже убираем (в
        // меню-баре и по хоткею они остаются).
        let panelCommands = commands.filter {
            $0.id != .snippets && $0.id != .audioOutput && $0.id != .audioInput
        }
        commandPanel.show(commands: panelCommands, snippets: snippetStore.snippets,
                          sliders: volumeSliders())
        panelIsOpen = true
    }

    /// Слайдеры громкости в панели: выход и вход микрофона — только те, что устройство
    /// реально поддерживает (иначе значение nil и слайдер не показываем).
    private func volumeSliders() -> [CommandPanelWindowController.VolumeSlider] {
        var result: [CommandPanelWindowController.VolumeSlider] = []
        if let out = audio.outputVolume() {
            let device = sliderDevice(audio.outputDevices(), currentID: audio.currentOutputDeviceID()) {
                [weak self] id in self?.audio.setOutput(id)
            }
            result.append(.init(title: L("panel.section.output"), symbol: "speaker.wave.2.fill",
                                value: out, device: device, reflectsLevel: true,
                                readValue: { [weak self] in self?.audio.outputVolume() }) { [weak self] v in
                self?.audio.setOutputVolume(v)
            })
        }
        if let input = audio.inputVolume() {
            let device = sliderDevice(audio.inputDevices(), currentID: audio.currentInputDeviceID()) {
                [weak self] id in self?.audio.setInput(id)
            }
            result.append(.init(title: L("panel.section.input"), symbol: "mic.fill",
                                value: input, device: device, reflectsLevel: true,
                                readValue: { [weak self] in self?.audio.inputVolume() }) { [weak self] v in
                self?.audio.setInputVolume(v)
            })
        }
        return result
    }

    /// Собирает встроенную выпадашку выбора устройства для слайдера; nil — если устройств нет.
    private func sliderDevice(_ devices: [AudioDevice], currentID: AudioDeviceID?,
                              onPick: @escaping (AudioDeviceID) -> Void) -> SliderDevice? {
        guard !devices.isEmpty else { return nil }
        let options = devices.map {
            SliderDevice.Option(id: $0.id, name: $0.name, isCurrent: $0.id == currentID)
        }
        let currentName = devices.first { $0.id == currentID }?.name ?? devices[0].name
        return SliderDevice(currentName: currentName, options: options, onPick: onPick)
    }

    // Прямой вызов команды (меню/глобальный хоткей, вне палитры): открываем палитру и разворачиваем
    // соответствующий модуль — тот же единый вид, что при выборе команды внутри палитры. Отдельных
    // окон (transform/буфер/аудио) больше нет — всё живёт в одном окне палитры.

    private func openClipboardHistory() {
        if !panelIsOpen { openCommandPanel() }
        presentClipboardHistory()
    }
    private func openTextTransforms() {
        if !panelIsOpen { openCommandPanel() }
        presentTransformModule()
    }
    private func openAudioOutput() {
        if !panelIsOpen { openCommandPanel() }
        presentAudioOutput()
    }
    private func openAudioInput() {
        if !panelIsOpen { openCommandPanel() }
        presentAudioInput()
    }

    // MARK: Списки как модули палитры (билдеры строк — статические в GlassListWindowController)

    private lazy var clipboardHistoryModule: GlassListModule = {
        let module = GlassListModule(titleKey: "clipboard.title", emptyKey: "clipboard.empty", rowHeight: 34)
        module.enableClearButton { [weak self] in self?.clipboardHistory.clear() }
        return module
    }()
    private lazy var audioOutputModule = GlassListModule(titleKey: "audio.output.title", emptyKey: "audio.empty")
    private lazy var audioInputModule = GlassListModule(titleKey: "audio.input.title", emptyKey: "audio.empty")

    private func presentClipboardHistory() {
        snippetTargetApp = NSWorkspace.shared.frontmostApplication
        let items = GlassListWindowController.historyItems(clipboardHistory.entries) { [weak self] text in
            self?.pasteHistory(text)
        }
        clipboardHistoryModule.configure(items: items)
        commandPanel.enterModule(clipboardHistoryModule)
    }
    private func presentAudioOutput() {
        let (items, preselect) = GlassListWindowController.audioItems(
            audio.outputDevices(), currentID: audio.currentOutputDeviceID()) { [weak self] id in
            self?.audio.setOutput(id)
        }
        audioOutputModule.configure(items: items, preselect: preselect)
        commandPanel.enterModule(audioOutputModule)
    }
    private func presentAudioInput() {
        let (items, preselect) = GlassListWindowController.audioItems(
            audio.inputDevices(), currentID: audio.currentInputDeviceID()) { [weak self] id in
            self?.audio.setInput(id)
        }
        audioInputModule.configure(items: items, preselect: preselect)
        commandPanel.enterModule(audioInputModule)
    }

    /// Вставляет результат преобразования на место выделения (синтез Cmd+V). Требует Accessibility.
    /// Возвращаем фокус целевому приложению: при ручном вводе окно ввода активировало Hopkey,
    /// иначе Cmd+V ушёл бы не в то поле (в обычном пути пикер не забирает фокус — activate no-op).
    private func pasteTransform(_ text: String) {
        let target = snippetTargetApp
        snippetTargetApp = nil
        guard HotKeyManager.ensureAccessibility(prompt: false) else {
            URLOpener.copy(text); clipboard.syncChangeCount(); return
        }
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.hotKey.paste(text) { self.clipboard.syncChangeCount() }
        }
    }

    /// Маршрутизирует конкретное действие сниппета из панели (первичное или вторичное).
    private func dispatchSnippet(_ snippet: Snippet, _ activation: SnippetActivation) {
        switch activation {
        case .paste: pasteSnippet(snippet)
        case .open:  openSnippet(snippet)
        case .copy:  copySnippet(snippet)
        }
    }

    /// Вставляет запись истории буфера в активное поле (как paste-plain). Требует Accessibility.
    private func pasteHistory(_ text: String) {
        guard !text.isEmpty else { NSSound.beep(); return }
        guard HotKeyManager.ensureAccessibility(prompt: false) else {
            HotKeyManager.ensureAccessibility(prompt: true); return
        }
        hotKey.paste(text) { [weak self] in self?.clipboard.syncChangeCount() }
    }

    /// «Скрытая» ли текущая копия: пароль-менеджеры и т.п. помечают буфер служебными типами,
    /// такие значения в историю не пишем.
    private func clipboardIsConcealed() -> Bool {
        let concealed: Set<String> = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
        ]
        return (NSPasteboard.general.types ?? []).contains { concealed.contains($0.rawValue) }
    }

    /// Добавляет пункт меню статус-бара с SF Symbol-иконкой и таргетом на self.
    @discardableResult
    private func addStatusItem(_ menu: NSMenu, _ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image?.isTemplate = true
        item.image = image
        return item
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
        // Копирование в буфер не видно глазу (в отличие от вставки, где значение
        // появляется в поле) — даём короткое подтверждение баннером.
        notifications.confirmSnippetCopied()
    }

    /// Открывает значение сниппета-ссылки в браузере. Значение нормализуется в http(s)-URL
    /// той же логикой, что валидирует ссылку в редакторе.
    private func openSnippet(_ snippet: Snippet) {
        guard let value = snippetStore.value(for: snippet.id),
              let url = Snippet.url(forValue: value) else {
            NSSound.beep()
            return
        }
        URLOpener.open([url])
    }

    /// Хоткей окна ввода: сам снимает выделение (с сохранением буфера) и открывает окно
    /// с подставленным текстом. Если Accessibility не выдан или ничего не выделено —
    /// откатываемся к числу из буфера (или пустому окну).
    private func openQuickTicketFromSelection() {
        // Подстановка выделения требует синтеза Cmd+C (Accessibility). Без доступа окно
        // открываем как обычно (по числу из буфера), но разово объясняем, почему выделение
        // не подставилось — иначе пустой ввод выглядит как баг. Захват не запускаем: без
        // доступа Cmd+C ничего не даст, только лишняя пауза.
        guard HotKeyManager.ensureAccessibility(prompt: false) else {
            showSelectionAccessibilityHintIfNeeded()
            quickTicket.showWindow(prefill: clipboardBareNumber())
            return
        }
        // Доступ есть — «перевзводим» подсказку: если позже он слетит (типичный случай —
        // пересборка меняет cdhash и TCC сбрасывает грант), мы снова один раз объясним причину.
        if UserDefaults.standard.bool(forKey: Self.selectionHintKey) {
            UserDefaults.standard.set(false, forKey: Self.selectionHintKey)
        }
        hotKey.captureSelection { [weak self] selection in
            guard let self else { return }
            let prefill = selection.flatMap(self.prefillToken) ?? self.clipboardBareNumber()
            // Наши манипуляции с буфером (Cmd+C + восстановление) не должны будить наблюдателя.
            self.clipboard.syncChangeCount()
            self.quickTicket.showWindow(prefill: prefill)
        }
    }

    /// Флаг «подсказку про Accessibility для подстановки выделения уже показывали».
    /// Сбрасывается, как только доступ снова появляется (см. `openQuickTicketFromSelection`),
    /// поэтому при повторной потере доступа подсказка покажется снова — ровно один раз.
    private static let selectionHintKey = "selectionAccessibilityHintShown"

    /// Разово (до следующей потери доступа) объясняет, что подстановка выделения в окно
    /// ввода требует Универсального доступа, и предлагает открыть нужный раздел настроек.
    /// Окно ввода при этом всё равно открывается — подсказка не блокирует основной путь.
    private func showSelectionAccessibilityHintIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.selectionHintKey) else { return }
        defaults.set(true, forKey: Self.selectionHintKey)

        let alert = NSAlert()
        alert.messageText = L("hint.selectionAccess.title")
        alert.informativeText = L("hint.selectionAccess.body")
        alert.addButton(withTitle: L("hint.selectionAccess.openSettings"))
        alert.addButton(withTitle: L("notif.denied.later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Выделенный текст как кандидат на префилл. Сначала пытаемся вытащить ключ по
    /// включённым шаблонам — тогда срабатывают и «грязные» строки: `…/browse/PROJ-123`
    /// (полный URL) и `PROJ-123 (https://…/browse/PROJ-123)` — именно так копирование
    /// masked-ссылки отдаёт нативный Telegram (версия с сайта, не из App Store).
    /// Иначе — один «токен» без внутренних пробелов и не длиннее 40 символов
    /// (`#42`, `12345`); иначе nil.
    private func prefillToken(_ raw: String) -> String? {
        if let match = TicketParser.matches(in: raw, templates: config.templates).first {
            return match.id
        }
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

    // MARK: - Реестр команд

    /// Собирает команды тулбокса. Замыкания читают живое состояние (мьют/awake) при каждом
    /// вызове, поэтому массив строится один раз, а меню/панель всегда показывают актуальное.
    private func buildCommands() -> [ToolboxCommand] {
        CommandID.allCases.map { command(for: $0) }
    }

    private func command(for id: CommandID) -> ToolboxCommand {
        switch id {
        case .quickInput:
            return ToolboxCommand(
                id: id, needsAccessibility: false,
                title: { L("cmd.quickInput") }, symbol: { "magnifyingglass" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.openQuickTicketFromSelection() })
        case .snippets:
            return ToolboxCommand(
                id: id, needsAccessibility: true,
                title: { L("cmd.snippets") }, symbol: { "text.badge.plus" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.showSnippetPicker() })
        case .micToggle:
            return ToolboxCommand(
                id: id, needsAccessibility: false,
                // Предмет, а не действие: «Микрофон» + статус (как keep-awake), «выключить»
                // подразумевается кликом. В меню — галка при мьюте.
                title: { L("cmd.mic") },
                symbol: { [weak self] in (self?.mic.isMuted ?? false) ? "mic.slash.fill" : "mic.fill" },
                // «Активное» состояние тумблера = замьючен (привлекает внимание).
                isOn: { [weak self] in self?.mic.isMuted ?? false },
                trailing: { [weak self] in
                    L((self?.mic.isMuted ?? false) ? "cmd.mic.status.muted" : "cmd.mic.status.live") },
                run: { [weak self] in self?.mic.toggle() })
        case .keepAwake:
            return ToolboxCommand(
                id: id, needsAccessibility: false,
                title: { L("cmd.keepAwake") },
                symbol: { [weak self] in (self?.keepAwake.isOn ?? false) ? "cup.and.saucer.fill" : "cup.and.saucer" },
                isOn: { [weak self] in self?.keepAwake.isOn ?? false },
                trailing: { [weak self] in
                    L((self?.keepAwake.isOn ?? false) ? "panel.toggle.on" : "panel.toggle.off") },
                run: { [weak self] in self?.keepAwake.toggle() })
        case .pastePlain:
            return ToolboxCommand(
                id: id, needsAccessibility: true,
                title: { L("cmd.pastePlain") }, symbol: { "doc.on.clipboard" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.pastePlainText() })
        case .clipboardHistory:
            return ToolboxCommand(
                id: id, needsAccessibility: true,
                title: { L("cmd.clipboardHistory") }, symbol: { "clock.arrow.circlepath" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.openClipboardHistory() })
        case .textTransform:
            return ToolboxCommand(
                id: id, needsAccessibility: true,
                title: { L("cmd.textTransform") }, symbol: { "textformat" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.openTextTransforms() })
        case .audioOutput:
            return ToolboxCommand(
                id: id, needsAccessibility: false,
                title: { L("cmd.audioOutput") }, symbol: { "hifispeaker" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.openAudioOutput() })
        case .audioInput:
            return ToolboxCommand(
                id: id, needsAccessibility: false,
                title: { L("cmd.audioInput") }, symbol: { "mic" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.openAudioInput() })
        case .ocr:
            return ToolboxCommand(
                id: id, needsAccessibility: false,
                title: { L("cmd.ocr") }, symbol: { "text.viewfinder" },
                isOn: { nil }, trailing: { [weak self] in self?.hotKeyHint(for: id) },
                run: { [weak self] in self?.runOCR() })
        }
    }

    /// Команда OCR: захватывает область экрана, распознаёт текст (Vision, на устройстве) и кладёт
    /// в буфер + историю. Обратную связь даём HUD-тостом (не зависит от разрешения на уведомления).
    /// Копирование не требует Accessibility, а интерактивный screencapture — Screen Recording,
    /// поэтому команда беспермишенная. Наблюдателя буфера глушим, чтобы наша запись не запускала
    /// тикет-матчинг/авто-открытие.
    private func runOCR() {
        ocr.capture { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                break  // пользователь отменил выделение — молчим
            case .empty:
                NSSound.beep()
                self.hud.show(symbol: "text.viewfinder", message: L("ocr.hud.empty"))
            case .text(let text):
                URLOpener.copy(text)
                self.clipboard.syncChangeCount()
                self.clipboardHistory.record(text)
                self.hud.show(symbol: "checkmark.circle.fill", message: L("ocr.hud.copied"))
            }
        }
    }

    /// Строка прямого хоткея команды для трейлинга в панели (nil, если комбинация не задана).
    private func hotKeyHint(for id: CommandID) -> String? {
        let binding = config.binding(for: id)
        guard binding.isRegisterable else { return nil }
        return hotKeyDisplayString(keyCode: UInt32(binding.keyCode), modifiers: UInt32(binding.modifiers))
    }

    /// Вставляет содержимое буфера как обычный текст (без форматирования): кладём в буфер голую
    /// строку и синтезируем ⌘V в поле, где стоит курсор (переиспользуя гейт модификаторов и
    /// восстановление буфера `hotKey.paste`). Требует Accessibility.
    private func pastePlainText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep(); return
        }
        guard HotKeyManager.ensureAccessibility(prompt: false) else {
            HotKeyManager.ensureAccessibility(prompt: true); return
        }
        hotKey.paste(text) { [weak self] in self?.clipboard.syncChangeCount() }
    }

    // MARK: - Триггер панели (двойной тап)

    /// Включён ли вызов панели двойным тапом (нужен глобальный монитор → Accessibility).
    private var paletteEnabled: Bool {
        if case .disabled = config.paletteTrigger { return false }
        return true
    }

    /// (Пере)создаёт детектор двойного тапа и монитор под текущий триггер из конфига.
    private func setupPaletteTrigger() {
        flagsMonitor?.stop()
        flagsMonitor = nil
        doubleTapDetector = nil
        guard case .doubleTap(let side) = config.paletteTrigger else { return }

        let detector = DoubleTapDetector(targetKeyCode: side.keyCode)
        detector.onTrigger = { [weak self] in
            DispatchQueue.main.async { self?.togglePanel() }
        }
        let monitor = FlagsChangedMonitor(detector: detector)
        monitor.start()
        doubleTapDetector = detector
        flagsMonitor = monitor
    }

    // MARK: - Применение настроек

    private func applyConfig() {
        if anyHotKeyEnabled {
            if needsAccessibility { HotKeyManager.ensureAccessibility(prompt: true) }
            registerHotKeys()
        } else {
            hotKey.unregisterAll()
        }
        setupPaletteTrigger()
    }

    private var anyHotKeyEnabled: Bool {
        paletteEnabled || commands.contains { config.binding(for: $0.id).isRegisterable }
    }

    /// Нужен ли Accessibility: требуется командам с синтезом ⌘C/⌘V (сниппеты, paste-plain) и
    /// монитору двойного тапа (глобальный перехват модификаторов). Окну ввода доступ не нужен.
    private var needsAccessibility: Bool {
        if paletteEnabled { return true }
        return commands.contains { $0.needsAccessibility && config.binding(for: $0.id).isRegisterable }
    }

    /// Перерегистрирует прямые хоткеи по реестру: каждая включённая команда с валидной
    /// комбинацией получает свой хоткей (id = `CommandID.hotKeyID`). Занятые комбинации
    /// запоминаем, чтобы настройки показали предупреждение.
    private func registerHotKeys() {
        hotKey.unregisterAll()
        failedCommandHotKeys.removeAll()
        for command in commands {
            let binding = config.binding(for: command.id)
            guard binding.isRegisterable else { continue }
            let ok = hotKey.register(id: command.id.hotKeyID,
                                     keyCode: UInt32(binding.keyCode),
                                     modifiers: UInt32(binding.modifiers)) {
                // `command` захвачен по значению; его `run` уже держит self слабо — цикла нет.
                HotKeySoundFeedback.playIfEnabled()
                command.run()
            }
            if !ok { failedCommandHotKeys.insert(command.id) }
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Вызывается прямо перед показом меню. macOS опознаёт пункт «Настройки…» как
    /// стандартный и при каждом показе перерисовывает на нём свою авто-шестерёнку,
    /// затирая нашу. Переустанавливаем собственную gearshape, чтобы стиль иконки
    /// был единым со всеми остальными пунктами.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(openSettings) {
            let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: item.title)
            image?.isTemplate = true
            item.image = image
        }
    }
}
