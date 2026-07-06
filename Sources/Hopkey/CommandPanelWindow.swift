import AppKit
import CoreAudio
import HopkeyCore

/// Панель-палитра команд: тумблеры (плитки), разовые действия и сниппеты (строки) на одной
/// поверхности. Вызывается двойным тапом правого ⌘ или левым кликом по иконке. Неактивирующая
/// стеклянная панель в идиоме пикера сниппетов — фокус целевого приложения не теряется, поэтому
/// вставка сниппета/paste попадает туда, где стоял курсор.
private final class CommandPanel: NSPanel {
    /// Esc: контроллер решает — выйти из модуля/поиска в корень или закрыть панель.
    var onCancel: (() -> Void)?
    /// ⌘↩ на уровне окна — форвардим активному модулю (напр. transform «применить»), независимо
    /// от того, где сейчас фокус (поле ввода модуля или его список).
    var onCommandReturn: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let onlyCommand = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask) == .command
        if onlyCommand, event.charactersIgnoringModifiers == "\r", onCommandReturn?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Самодостаточный контент, который палитра показывает вместо корневого списка (преобразование
/// текста, история буфера, аудио…). Модуль не владеет окном — только вьюхой; окно (размер, фокус,
/// навигация назад) держит палитра-хозяин. Так все инструменты живут в одном окне палитры.
protocol PaletteModule: AnyObject {
    /// Корневая вьюха модуля — палитра кладёт её в тело окна на всю доступную область под хедером.
    var contentView: NSView { get }
    /// Заголовок в общий хедер палитры, пока модуль открыт.
    var titleKey: String { get }
    /// Желаемая высота контента под ширину окна — палитра подгоняет окно (см. `sizeToFit`).
    func fittingHeight(forWidth width: CGFloat) -> CGFloat
    /// Вызывается при входе в режим: поставить фокус, пересчитать состояние.
    func moduleWillAppear(host: PaletteHost)
    /// Модуль сам разбирает командную клавишу (⌘↩ «применить» и т.п.); true — обработано.
    func handleCommandReturn() -> Bool
}

/// Палитра как хозяин модуля: вернуться в корень, закрыть окно, переразмерить под изменившийся контент.
protocol PaletteHost: AnyObject {
    func dismissModule()   // Esc внутри модуля → корневой список палитры
    func closePalette()    // закрыть окно палитры целиком
    func setNeedsResize()  // контент модуля изменил высоту
}

/// Контейнер списка: держит фокус клавиатуры, водит выделение (стрелки), выполняет по Enter /
/// цифре 1–9, закрывает по Esc. Индексы совпадают с массивом `entries` контроллера.
private final class CommandListView: NSView {
    var onRun: ((Int) -> Void)?
    var onDigit: ((Int) -> Void)?
    /// Буква-команда по физическому keyCode (US-ANSI): true — команда найдена и запущена, иначе
    /// событие уходит в `super`. По коду, а не по символу — иначе матч ломается под кириллицей.
    var onCommandKey: ((UInt16) -> Bool)?
    var onClose: (() -> Void)?
    var onMove: ((Int) -> Void)?
    /// ←/→ по текущему выделению: слайдер меняет уровень, сниппет с несколькими действиями —
    /// открывает панель действий (только →). Знак: -1 влево, +1 вправо.
    var onHorizontal: ((Int) -> Void)?
    /// Tab — панель вторичных действий текущего выделения (сниппет).
    var onSecondary: (() -> Void)?
    /// ⌘F — перевести фокус в строку поиска (палитра остаётся открытой).
    var onFocusSearch: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        // ⌘F — фокус в поиск (keyCode 3 = kVK_ANSI_F, матчим по коду ради раскладки).
        if event.modifierFlags.contains(.command), event.keyCode == 3 {
            onFocusSearch?(); return
        }
        switch Int(event.keyCode) {
        case 125: onMove?(1)         // ↓
        case 126: onMove?(-1)        // ↑
        case 123: onHorizontal?(-1)  // ←
        case 124: onHorizontal?(1)   // →
        case 48:  onSecondary?()     // Tab
        case 36, 76: onRun?(-1)  // Return — по текущему выделению
        case 53: onClose?()      // Esc
        default:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Цифра 1–9 — сниппет (по символу: цифры не зависят от раскладки). Иначе — буква-
            // команда по физическому keyCode. Оба пула — только без модификаторов.
            if mods.isEmpty, let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), digit >= 1, digit <= 9 {
                onDigit?(digit)
            } else if mods.isEmpty, onCommandKey?(event.keyCode) == true {
                // команда найдена и запущена
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// Крупная плитка-тумблер: иконка + номер + название + статус, цвет фона кодирует состояние
/// (красный — микрофон замьючен/тревога, акцент — включённый тумблер, иначе нейтральный).
private final class CommandTileView: NSView {
    enum State { case inactive, active, attention }

    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var state: State = .inactive
    var isSelected = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        iconView.imageScaling = .scaleProportionallyDown
        numberLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        numberLabel.alignment = .right
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)

        for field in [numberLabel, titleLabel, statusLabel] {
            field.isEditable = false; field.isBordered = false; field.drawsBackground = false
        }
        let top = NSStackView(views: [iconView, NSView(), numberLabel])
        top.orientation = .horizontal
        top.alignment = .centerY
        let stack = NSStackView(views: [top, titleLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 78),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func mouseUp(with event: NSEvent) { onClick?() }

    func configure(badge: String?, symbol: String, title: String, status: String, state: State) {
        self.state = state
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        numberLabel.stringValue = badge ?? ""
        titleLabel.stringValue = title
        statusLabel.stringValue = status
        setAccessibilityLabel("\(title). \(status)")
        refresh()
    }

    private func refresh() {
        let fill: NSColor
        let stroke: NSColor
        let fg: NSColor
        switch state {
        case .attention:
            fill = NSColor.systemRed.withAlphaComponent(0.14); stroke = .systemRed; fg = .systemRed
        case .active:
            // Включённый тумблер — системный акцент; при выделении рамка толще (2px), так что
            // выбор различим и на акцентной заливке.
            fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
            stroke = .controlAccentColor
            fg = .controlAccentColor
        case .inactive:
            fill = .clear; stroke = .separatorColor; fg = .secondaryLabelColor
        }
        layer?.backgroundColor = fill.cgColor
        iconView.contentTintColor = fg
        numberLabel.textColor = fg
        statusLabel.textColor = fg
        titleLabel.textColor = (state == .inactive) ? .labelColor : fg
        // Выделение с клавиатуры — акцентная рамка поверх состояния.
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : stroke).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
    }
}

/// Нейтральный бейдж номера быстрого выбора (без брендового янтаря) — под «чистое стекло».
private final class NumberBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    var value: String {
        get { label.stringValue }
        set { label.stringValue = newValue; isHidden = newValue.isEmpty }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14).cgColor
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
}

/// Кнопка-иконка с замыканием — вторичные действия сниппета в строке (открыть/скопировать).
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(symbol: String, tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .accessoryBarAction
        contentTintColor = .secondaryLabelColor
        toolTip = tooltip
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
    @objc private func fire() { handler() }
}

/// Строка (действие / лончер / сниппет): номер + иконка + название + трейлинг (хоткей действия
/// или тип сниппета). У сниппетов на hover/выборе трейлинг сменяется кнопками действий.
/// Выделение — нейтральная акцентная заливка, hover — слабая серая.
final class CommandRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let keycap = NumberBadge()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private var hasActions = false
    private var actionsData: [(symbol: String, tooltip: String, run: () -> Void)] = []
    private var tracking: NSTrackingArea?
    /// Привязка иконки: к бейджу (когда номер есть) либо к левому краю (когда бейджа нет —
    /// не резервируем пустую колонку под номер).
    private var iconLeadingToBadge: NSLayoutConstraint!
    private var iconLeadingToEdge: NSLayoutConstraint!

    var isSelected = false { didSet { refreshBackground(); updateActionsVisibility() } }
    private var isHovered = false { didSet { refreshBackground(); updateActionsVisibility() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        keycap.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor

        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        titleLabel.usesSingleLineMode = true; titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        trailingLabel.isEditable = false; trailingLabel.isBordered = false; trailingLabel.drawsBackground = false
        trailingLabel.usesSingleLineMode = true
        trailingLabel.font = .systemFont(ofSize: 12)
        trailingLabel.textColor = .secondaryLabelColor
        trailingLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

        actionsStack.orientation = .horizontal
        actionsStack.spacing = 2
        actionsStack.isHidden = true
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(keycap); addSubview(iconView); addSubview(titleLabel)
        addSubview(trailingLabel); addSubview(actionsStack)
        iconLeadingToBadge = iconView.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 10)
        iconLeadingToEdge = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 20),
            keycap.heightAnchor.constraint(equalToConstant: 20),
            iconLeadingToBadge,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// `image` (напр. настоящая иконка приложения) перекрывает SF-символ, если задан.
    /// `attributedTitle` (напр. выражение калькулятора с акцентом на результате) перекрывает `title`.
    func configure(badge: String?, symbol: String, title: String, trailing: String?,
                   image: NSImage? = nil, attributedTitle: NSAttributedString? = nil) {
        keycap.value = badge ?? ""
        let hasBadge = !(badge ?? "").isEmpty
        iconLeadingToBadge.isActive = hasBadge
        iconLeadingToEdge.isActive = !hasBadge
        iconView.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        if let attributedTitle {
            titleLabel.attributedStringValue = attributedTitle
            setAccessibilityLabel(attributedTitle.string)
        } else {
            titleLabel.stringValue = title
            setAccessibilityLabel(title)
        }
        trailingLabel.stringValue = trailing ?? ""
    }

    /// Вторичные действия строки (кнопки-иконки), показываются на hover/выборе вместо трейлинга.
    func setActions(_ actions: [(symbol: String, tooltip: String, run: () -> Void)]) {
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            actionsStack.addArrangedSubview(
                ClosureButton(symbol: action.symbol, tooltip: action.tooltip, handler: action.run))
        }
        actionsData = actions
        hasActions = !actions.isEmpty
        updateActionsVisibility()
    }

    /// Есть ли вторичные действия — контроллер решает, вешать ли на строку клавиатурный вызов (→/Tab).
    var hasSecondaryActions: Bool { hasActions }

    /// Клавиатурный вызов панели вторичных действий (→/Tab): одно действие — выполняем сразу,
    /// несколько — открываем нативное меню у правого края строки.
    func triggerActionPanel() {
        guard !actionsData.isEmpty else { NSSound.beep(); return }
        if actionsData.count == 1 { actionsData[0].run(); return }
        let menu = NSMenu()
        for (index, action) in actionsData.enumerated() {
            let item = NSMenuItem(title: action.tooltip, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.width - 40, y: bounds.height), in: self)
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard actionsData.indices.contains(sender.tag) else { return }
        actionsData[sender.tag].run()
    }

    private func updateActionsVisibility() {
        let show = hasActions && (isSelected || isHovered)
        actionsStack.isHidden = !show
        trailingLabel.isHidden = show
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private func refreshBackground() {
        let color: NSColor
        if isSelected { color = NSColor.controlAccentColor.withAlphaComponent(0.20) }
        else if isHovered { color = NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
        else { color = .clear }
        layer?.backgroundColor = color.cgColor
    }
}

/// Выбор аудиоустройства: текущее имя для подписи + список для выпадашки.
struct SliderDevice {
    struct Option { let id: AudioDeviceID; let name: String; let isCurrent: Bool }
    let currentName: String
    let options: [Option]
    let onPick: (AudioDeviceID) -> Void
}

/// Кнопка-выпадашка выбора устройства: текущее имя + шеврон, клик — нативное меню со списком
/// (галочка на текущем). Живёт в строке устройств над ползунками (колонка выхода/входа).
private final class DeviceMenuButton: NSButton {
    private var options: [SliderDevice.Option] = []
    private var onPick: ((AudioDeviceID) -> Void)?

    init(device: SliderDevice) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        imagePosition = .imageRight
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        font = .systemFont(ofSize: 11, weight: .medium)
        alignment = .right
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(showMenu)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        options = device.options
        onPick = device.onPick
        title = device.currentName
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    @objc private func showMenu() {
        guard !options.isEmpty else { return }
        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: option.id)
            item.state = option.isCurrent ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
    @objc private func pick(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        title = sender.title
        options = options.map { .init(id: $0.id, name: $0.name, isCurrent: $0.id == id) }
        onPick?(id)
    }
}

/// NSSlider, помнящий, что его сейчас тащат мышью: во время трекинга внешний опрос громкости не
/// должен перебивать позицию ползунка (иначе он дёргается под курсором). `mouseDown` у NSSlider
/// крутит собственный цикл трекинга до отпускания — флаг живёт весь перетаск.
private final class TrackingSlider: NSSlider {
    private(set) var isTracking = false
    override func mouseDown(with event: NSEvent) {
        isTracking = true
        defer { isTracking = false }
        super.mouseDown(with: event)
    }
}

/// Строка-слайдер (одна на направление): иконка + ползунок (0…1) с живым процентом. Живёт в
/// половине ширины (две колонки в ряд — выход/вход), поэтому отступы компактные; выбор устройства
/// вынесен в отдельную строку над ползунками (см. `rebuild`). Панель не закрывается.
/// Выделяется стрелками (фон-подсветка), ←/→ меняют уровень (`nudge`).
private final class SliderRowView: NSView {
    var onChange: ((Float) -> Void)?

    private let iconView = NSImageView()
    private let slider = TrackingSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    /// Красить трек и процент по уровню (см. `VolumeSlider.reflectsLevel`).
    private var reflectsLevel = false

    var isSelected = false { didSet { refreshBackground() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        // Живой процент справа — иначе по одному положению ползунка уровень не считать.
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.isEditable = false; valueLabel.isBordered = false; valueLabel.drawsBackground = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView); addSubview(slider); addSubview(valueLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(symbol: String, value: Float, reflectsLevel: Bool = false) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.reflectsLevel = reflectsLevel
        slider.floatValue = value
        valueLabel.stringValue = Self.percent(value)
        applyLevelTint(value)
    }

    /// ←/→ на выделенной строке: шаг 5 %, с обрезкой в [0…1] и живым колбэком.
    func nudge(_ delta: Int) {
        let step: Float = 0.05
        let value = max(0, min(1, slider.floatValue + Float(delta) * step))
        slider.floatValue = value
        valueLabel.stringValue = Self.percent(value)
        applyLevelTint(value)
        onChange?(value)
    }

    /// Внешнее обновление уровня (опрос системной громкости): двигаем ползунок, процент и цвет.
    /// НЕ во время перетаскивания мышью — иначе ползунок прыгает под курсором. `onChange` не
    /// дёргаем: значение и так пришло от системы, писать его обратно незачем.
    func externalUpdate(_ value: Float) {
        guard !slider.isTracking else { return }
        let v = max(0, min(1, value))
        // Микродрожание округления игнорируем — иначе перерисовка на ровном месте.
        guard abs(v - slider.floatValue) > 0.001 else { return }
        slider.floatValue = v
        valueLabel.stringValue = Self.percent(v)
        applyLevelTint(v)
    }

    /// Заполненная часть трека — системный акцент, без цветового кодирования уровня (единый
    /// системный вид со всем приложением). Процент — приглушённый.
    private func applyLevelTint(_ value: Float) {
        guard reflectsLevel else { return }
        slider.trackFillColor = .controlAccentColor
        valueLabel.textColor = .secondaryLabelColor
    }

    private func refreshBackground() {
        layer?.backgroundColor = (isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.clear).cgColor
    }

    @objc private func changed() {
        valueLabel.stringValue = Self.percent(slider.floatValue)
        applyLevelTint(slider.floatValue)
        onChange?(slider.floatValue)
    }

    private static func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Строка окна истории буфера: номер быстрого выбора + предпросмотр текста, паста-глиф на hover.
private final class HistoryRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let keycap = NumberBadge()
    private let textLabel = NSTextField(labelWithString: "")
    private let pasteIcon = NSImageView()
    private var tracking: NSTrackingArea?

    var isSelected = false { didSet { refresh() } }
    private var isHovered = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        keycap.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.usesSingleLineMode = true
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isEditable = false; textLabel.isBordered = false; textLabel.drawsBackground = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        pasteIcon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        pasteIcon.contentTintColor = .secondaryLabelColor
        pasteIcon.isHidden = true
        pasteIcon.translatesAutoresizingMaskIntoConstraints = false

        addSubview(keycap); addSubview(textLabel); addSubview(pasteIcon)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 20),
            keycap.heightAnchor.constraint(equalToConstant: 20),
            textLabel.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 10),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: pasteIcon.leadingAnchor, constant: -8),
            pasteIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pasteIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pasteIcon.widthAnchor.constraint(equalToConstant: 15),
            pasteIcon.heightAnchor.constraint(equalToConstant: 15),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(digit: Int?, text: String) {
        keycap.value = digit.map(String.init) ?? ""
        textLabel.stringValue = text
        setAccessibilityLabel(text)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private func refresh() {
        let color: NSColor
        if isSelected { color = NSColor.controlAccentColor.withAlphaComponent(0.20) }
        else if isHovered { color = NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
        else { color = .clear }
        layer?.backgroundColor = color.cgColor
        pasteIcon.isHidden = !(isSelected || isHovered)
    }
}


/// Плоское поле поиска в идиоме панели: лупа + borderless-текст + кнопка-крестик, тонкий бортик и
/// лёгкая полупрозрачная заливка вместо стокового безеля `NSSearchField` (тот рвёт «стекло» плотной
/// белой пилюлей и громким синим кольцом фокуса). Фокус показываем акцентным бортиком — как
/// выделение строки/плитки. Делегат/ввод вешаются на внутренний `textField`.
private final class PaletteSearchField: NSView {
    let textField = NSTextField()
    private let iconView = NSImageView()
    private let clearButton = NSButton()

    /// Текст очищен крестиком (фокус остаётся) — контроллер пересобирает список.
    var onClear: (() -> Void)?

    var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue; updateClearVisibility() }
    }
    var placeholderString: String? {
        get { textField.placeholderString }
        set { textField.placeholderString = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.translatesAutoresizingMaskIntoConstraints = false

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.setButtonType(.momentaryChange)
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView); addSubview(textField); addSubview(clearButton)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 6),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var acceptsFirstResponder: Bool { true }
    // ⌘F/клик переводят фокус на контейнер — форвардим на текстовое поле (там живёт редактор).
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(textField) ?? false }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(textField) }

    /// Фокус — акцентный бортик потолще (в тон выделению), потеря фокуса — нейтральный.
    func setFocused(_ focused: Bool) {
        layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = focused ? 2 : 1
    }

    func updateClearVisibility() {
        clearButton.isHidden = textField.stringValue.isEmpty
    }

    @objc private func clear() {
        textField.stringValue = ""
        updateClearVisibility()
        onClear?()
        window?.makeFirstResponder(textField)
    }
}

final class CommandPanelWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
                                          PaletteHost {

    /// Действие над сниппетом: первичное (клик/Enter) или вторичное (кнопки в строке).
    var onSnippetActivation: ((Snippet, SnippetActivation) -> Void)?
    /// Панель закрылась (Esc/выбор/клик мимо) — вызывающий сбрасывает состояние жеста-триггера.
    var onClose: (() -> Void)?

    /// Поиск приложений по запросу (владелец индекса — AppDelegate); nil → приложения не ищем.
    var searchApps: ((String) -> [AppEntry])?
    /// Запустить приложение по URL (выбор в результатах поиска).
    var onLaunchApp: ((URL) -> Void)?
    /// Скопировать значение (результат калькулятора) — вызывающий даёт обратную связь HUD-тостом.
    var onCopyValue: ((String) -> Void)?

    /// Команда просит показать свой инструмент внутри палитры (модуль), а не закрывать её. Вернуть
    /// true, если команда обработана как модуль (вызывающий сам сделал `enterModule`, возможно
    /// асинхронно после захвата выделения); иначе false — команда исполняется обычным путём.
    var onPresentCommandModule: ((ToolboxCommand) -> Bool)?

    /// Слайдер громкости в панели: иконка, стартовое значение (0…1), живой колбэк изменения и
    /// опциональное аудиоустройство для встроенной выпадашки выбора.
    struct VolumeSlider {
        let title: String       // заголовок направления («Выход»/«Вход»)
        let symbol: String
        let value: Float
        let device: SliderDevice?
        /// Красить заполненную часть трека по уровню (низко — красный … норма — зелёный). Включаем
        /// для входа: низкая чувствительность = «меня не слышно», это надо ловить глазом сразу.
        let reflectsLevel: Bool
        /// Опрос текущей системной громкости, пока панель открыта (nil — не опрашивать). Позволяет
        /// подхватывать изменения громкости извне (клавиши, Системные настройки).
        let readValue: (() -> Float?)?
        let onChange: (Float) -> Void
        init(title: String, symbol: String, value: Float, device: SliderDevice? = nil,
             reflectsLevel: Bool = false, readValue: (() -> Float?)? = nil,
             onChange: @escaping (Float) -> Void) {
            self.title = title
            self.symbol = symbol
            self.value = value
            self.device = device
            self.reflectsLevel = reflectsLevel
            self.readValue = readValue
            self.onChange = onChange
        }
    }

    /// Одна выбираемая позиция панели (плитка или строка) в визуальном порядке.
    /// Быстрый выбор разведён на два непересекающихся пула: команды — по букве (`commandKey`,
    /// физический keyCode), сниппеты — по цифре (`digit`, 1–9). `badge` — то, что нарисовано
    /// на плитке/строке (буква или цифра); nil у слайдеров/истории — они номера не расходуют.
    private struct Entry {
        let view: NSView
        let badge: String?
        /// Цифра быстрого выбора сниппета (1–9); nil у команд и слайдеров.
        let digit: Int?
        /// Физический keyCode буквы команды; nil у сниппетов и слайдеров.
        let commandKey: UInt16?
        let setSelected: (Bool) -> Void
        let run: () -> Void
        /// ←/→ на выделении (слайдер меняет уровень); nil у обычных строк.
        var adjust: ((Int) -> Void)? = nil
        /// →/Tab на выделении (вторичные действия сниппета); nil если их нет.
        var secondary: (() -> Void)? = nil
    }
    private var entries: [Entry] = []
    private var selectedIndex = 0
    private var finished = false
    /// Счётчик присвоенных сниппетам цифр 1–9.
    private var snippetDigitCounter = 0

    /// Опрос системной громкости, пока панель открыта: ряды слайдеров с их геттером уровня.
    private var pollSliders: [(row: SliderRowView, read: () -> Float?)] = []
    private var pollTimer: Timer?

    private let listView = CommandListView()
    private let searchField = PaletteSearchField()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()

    /// Текущий режим окна. `.root` — корневой список (в т.ч. живой поиск внутри него, см.
    /// `currentQuery`); `.module` — инструмент, показанный на месте списка (transform и пр.).
    private enum Mode { case root, module(PaletteModule) }
    private var mode: Mode = .root
    /// Тело корневого режима (поиск + список + футер) и тело модуля — свапаем видимость между ними.
    private let rootBody = NSView()
    private let moduleBody = NSView()
    /// Общий хедер: заголовок обновляется под активный модуль, в корне — «panel.title».
    private var headerLabel: NSTextField?

    /// Последний показанный набор — чтобы возвращаться к обычной панели при очистке поиска.
    private var lastCommands: [ToolboxCommand] = []
    private var lastSnippets: [Snippet] = []
    private var lastSliders: [VolumeSlider] = []
    /// Текущий (тримленный) запрос поиска; пустой — обычный режим панели.
    private var currentQuery = ""
    /// Корневой контент-вью панели (внутри «стекла»). Нужен, чтобы замерить фактически требуемую
    /// ширину окна перед центрированием — контент (длинные имена устройств/футер) может распирать
    /// окно шире `Self.width`, и если центрировать по 470, окно потом уезжает вправо.
    private let panelContent = NSView()

    private static let width: CGFloat = 470
    private static let maxHeight: CGFloat = 620

    init() {
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.handleCancel() }
        panel.onCommandReturn = { [weak self] in
            guard let self, case .module(let module) = self.mode else { return false }
            return module.handleCommandReturn()
        }
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildChrome() {
        guard let window else { return }
        // Весь контент панели живёт в одном контейнере, который кладётся внутрь стекла.
        let content = panelContent
        installGlass(in: window, content: content)

        // Тело корневого режима (поиск + список + футер) заполняет весь контент; тело модуля живёт
        // под хедером и по умолчанию скрыто — режимы свапаются видимостью этих двух контейнеров.
        rootBody.translatesAutoresizingMaskIntoConstraints = false
        moduleBody.translatesAutoresizingMaskIntoConstraints = false
        moduleBody.isHidden = true
        content.addSubview(rootBody)
        content.addSubview(moduleBody)

        // Строка поиска: приложения + команды + калькулятор. Не в автофокусе — первый респондер
        // остаётся список (буквы/цифры-шорткаты работают как раньше); в поиск заходят ⌘F или кликом.
        searchField.placeholderString = L("panel.search.placeholder")
        searchField.textField.delegate = self
        searchField.onClear = { [weak self] in self?.applyQuery() }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        rootBody.addSubview(searchField)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(contentStack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listView
        rootBody.addSubview(scroll)

        let hint = NSTextField(labelWithString: L("panel.footer.commands"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        rootBody.addSubview(hint)

        // Хедер добавляем последним — поверх тел (в корне его перекрывать нечему, у модуля тело
        // начинается ниже). Label держим, чтобы менять заголовок под активный модуль.
        let (header, label) = Brand.makeHeader(title: L("panel.title"))
        header.translatesAutoresizingMaskIntoConstraints = false
        headerLabel = label
        content.addSubview(header)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),

            // rootBody совпадает с контентом — отступы поиска/списка/футера остаются прежними.
            rootBody.topAnchor.constraint(equalTo: content.topAnchor),
            rootBody.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootBody.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootBody.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            // moduleBody — под хедером на всю оставшуюся область.
            moduleBody.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            moduleBody.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            moduleBody.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            moduleBody.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: rootBody.topAnchor, constant: 32),
            searchField.leadingAnchor.constraint(equalTo: rootBody.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: rootBody.trailingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: rootBody.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: rootBody.trailingAnchor, constant: -8),

            listView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -6),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: rootBody.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: rootBody.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: rootBody.bottomAnchor, constant: -10),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] index in self?.runIndex(index) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onCommandKey = { [weak self] keyCode in self?.runCommandKey(keyCode) ?? false }
        listView.onClose = { [weak self] in self?.handleCancel() }
        listView.onHorizontal = { [weak self] delta in self?.horizontalOnSelection(delta) }
        listView.onSecondary = { [weak self] in self?.secondaryOnSelection() }
        listView.onFocusSearch = { [weak self] in self?.focusSearch() }
    }

    // MARK: Режимы (root ↔ module)

    /// Показать модуль на месте корневого списка: вставить его вьюху в тело модуля, свапнуть
    /// видимость, подогнать окно и передать фокус модулю. Опрос громкости на время модуля глушим.
    func enterModule(_ module: PaletteModule) {
        stopVolumePolling()
        moduleBody.subviews.forEach { $0.removeFromSuperview() }
        let view = module.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        moduleBody.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: moduleBody.topAnchor),
            view.leadingAnchor.constraint(equalTo: moduleBody.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: moduleBody.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: moduleBody.bottomAnchor),
        ])
        headerLabel?.stringValue = L(module.titleKey)
        mode = .module(module)
        rootBody.isHidden = true
        moduleBody.isHidden = false
        sizeToFit()
        module.moduleWillAppear(host: self)
    }

    /// Вернуться из модуля в корневой список: сбросить поиск, пересобрать корень, вернуть фокус и
    /// опрос громкости. Тело модуля очищаем (вьюха модуля отвязывается).
    private func enterRoot() {
        guard case .module = mode else { return }
        mode = .root
        headerLabel?.stringValue = L("panel.title")
        moduleBody.isHidden = true
        moduleBody.subviews.forEach { $0.removeFromSuperview() }
        rootBody.isHidden = false
        searchField.stringValue = ""
        currentQuery = ""
        rebuild(commands: lastCommands, snippets: lastSnippets, sliders: lastSliders)
        sizeToFit()
        window?.makeFirstResponder(listView)
        startVolumePolling()
    }

    /// Единая точка Esc: из модуля → корень; из поиска → очистить и вернуться в список; из
    /// «пустого» корня → закрыть окно. Так Esc везде значит «на шаг назад, из корня — закрыть».
    private func handleCancel() {
        if case .module = mode { enterRoot(); return }
        if !currentQuery.isEmpty {
            searchField.stringValue = ""
            applyQuery()
            window?.makeFirstResponder(listView)
        } else {
            window?.close()
        }
    }

    // MARK: - PaletteHost

    func dismissModule() { enterRoot() }
    func closePalette() { window?.close() }
    func setNeedsResize() { sizeToFit() }

    // MARK: Поиск

    /// ⌘F — перевести фокус в строку поиска (палитра остаётся, обычный режим сохраняется).
    private func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    /// Живой ввод в строке поиска: пусто → обычная панель (+ опрос громкости), иначе → результаты.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField.textField else { return }
        applyQuery()
    }

    /// Фокус в поле (⌘F/клик/начало правки) — акцентный бортик; потеря фокуса — нейтральный.
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField.textField else { return }
        searchField.setFocused(true)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField.textField else { return }
        searchField.setFocused(false)
    }

    /// Пересобрать по текущему тексту поля: пусто → обычная панель, иначе → плоский список.
    private func applyQuery() {
        currentQuery = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        searchField.updateClearVisibility()
        if currentQuery.isEmpty {
            rebuild(commands: lastCommands, snippets: lastSnippets, sliders: lastSliders)
            startVolumePolling()
        } else {
            stopVolumePolling()
            rebuildSearch(query: currentQuery)
        }
        sizeToFit()
    }

    /// Навигация из строки поиска: ↑/↓ водят выделение, ↩ запускает, Esc очищает и возвращает
    /// фокус в список (второй Esc — уже в списке — закрывает панель).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            runIndex(-1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            applyQuery()
            window?.makeFirstResponder(listView)
            return true
        default:
            return false
        }
    }

    /// ←/→ по выделению: слайдер меняет уровень; сниппет (только →) открывает вторичные действия.
    private func horizontalOnSelection(_ delta: Int) {
        guard entries.indices.contains(selectedIndex) else { return }
        let entry = entries[selectedIndex]
        if let adjust = entry.adjust {
            adjust(delta)
        } else if delta > 0, let secondary = entry.secondary {
            secondary()
        }
    }

    /// Tab по выделению: вторичные действия сниппета (если есть).
    private func secondaryOnSelection() {
        guard entries.indices.contains(selectedIndex) else { return }
        entries[selectedIndex].secondary?()
    }

    /// Показывает панель. `commands` — команды тулбокса (без лончера сниппетов; сами сниппеты
    /// идут построчно в `snippets`).
    func show(commands: [ToolboxCommand], snippets: [Snippet], sliders: [VolumeSlider] = []) {
        finished = false
        lastCommands = commands
        lastSnippets = snippets
        lastSliders = sliders
        // Всегда открываемся в корне: сбрасываем возможный застрявший режим модуля прошлого показа.
        mode = .root
        moduleBody.subviews.forEach { $0.removeFromSuperview() }
        moduleBody.isHidden = true
        rootBody.isHidden = false
        headerLabel?.stringValue = L("panel.title")
        searchField.stringValue = ""
        currentQuery = ""
        rebuild(commands: commands, snippets: snippets, sliders: sliders)
        sizeToFit()
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(listView)
        startVolumePolling()
    }

    /// Пока панель открыта — раз в ~0.3с читаем системную громкость и подтягиваем ползунки, чтобы
    /// подхватить изменения извне (клавиши, Системные настройки). `.common` — чтобы тикало и во
    /// время модального цикла трекинга ползунка (там `externalUpdate` сам себя пропустит по флагу).
    private func startVolumePolling() {
        stopVolumePolling()
        guard !pollSliders.isEmpty else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            for item in self.pollSliders {
                if let value = item.read() { item.row.externalUpdate(value) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopVolumePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func rebuild(commands: [ToolboxCommand], snippets: [Snippet], sliders: [VolumeSlider]) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
        pollSliders.removeAll()
        snippetDigitCounter = 0

        let toggles = commands.filter { $0.id.section == .toggles }
        let actions = commands.filter { $0.id.section == .actions || $0.id.section == .launchers }

        // Зона «переключатели» — плитки по две в ряд.
        if !toggles.isEmpty {
            addHeader(L("panel.section.toggles"), trailing: nil)
            var pair: [NSView] = []
            for command in toggles {
                let tile = makeTile(command)
                pair.append(tile)
                if pair.count == 2 { addTileRow(pair); pair = [] }
            }
            if !pair.isEmpty { addTileRow(pair) }
        }

        // Громкость: обе направления в одном ряду двумя колонками (выход | вход). Сверху — строка
        // выбора устройства (по колонке на направление), под ней — ползунки. Иконка (динамик/
        // микрофон) задаёт направление, ползунок с живым процентом. Выбор устройства вынесен
        // наверх, чтобы в узкой колонке хватило места ползунку. Слайдеры выбираются стрелками
        // (без номера 1–9), ←/→ на выделении меняют уровень.
        if !sliders.isEmpty {
            addHeader(L("panel.section.volume"), trailing: nil)
            addTwoColumnRow(sliders.map { makeDeviceCell($0.device) })
            var sliderRows: [NSView] = []
            for spec in sliders {
                let row = SliderRowView()
                row.configure(symbol: spec.symbol, value: spec.value, reflectsLevel: spec.reflectsLevel)
                row.onChange = spec.onChange
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 30).isActive = true
                sliderRows.append(row)
                if let read = spec.readValue { pollSliders.append((row, read)) }
                entries.append(Entry(view: row, badge: nil, digit: nil, commandKey: nil,
                                     setSelected: { [weak row] in row?.isSelected = $0 },
                                     run: {},
                                     adjust: { [weak row] delta in row?.nudge(delta) }))
            }
            addTwoColumnRow(sliderRows)
        }

        // Зона «действия» — компактные строки по две в ряд. Колонки делим по центральной оси
        // (см. addTwoColumnRow), а не через fillEqually: у строки с трейлинг-хоткеем ширина
        // контента иная, и fillEqually сдвигал правую колонку — центр же стоит на месте всегда.
        if !actions.isEmpty {
            addHeader(L("panel.section.actions"), trailing: nil)
            var pair: [NSView] = []
            for command in actions {
                let row = makeCommandRow(command)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 34).isActive = true
                pair.append(row)
                if pair.count == 2 { addTwoColumnRow(pair); pair = [] }
            }
            if !pair.isEmpty { addTwoColumnRow(pair) }
        }

        // Зона «сниппеты» — каждый в один клик.
        if !snippets.isEmpty {
            addHeader(L("panel.section.snippets"), trailing: L("panel.snippets.all"))
            for snippet in snippets { addRow(makeSnippetRow(snippet)) }
        }

        // Команды помечены буквами (см. makeTile/makeCommandRow), сниппеты — цифрами 1–9
        // (см. nextSnippetDigit); слайдеры/история номера не расходуют.
        selectedIndex = entries.isEmpty ? -1 : 0
        updateSelection()
    }

    /// Режим поиска: единый плоский список результатов по убыванию оценки совпадения. Калькулятор
    /// (если запрос вычислим) закреплён сверху; команды/приложения/сниппеты ранжируются вместе.
    private func rebuildSearch(query: String) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
        pollSliders.removeAll()
        snippetDigitCounter = 0

        if let value = Calculator.evaluate(query) {
            // Самодостаточная строка «выражение = ответ»: выражение приглушённым моноширинным,
            // результат — акцентным (жирнее/крупнее), чтобы ответ читался как ответ.
            let attr = NSMutableAttributedString(
                string: "\(query) = ",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor])
            attr.append(NSAttributedString(
                string: value,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                             .foregroundColor: NSColor.labelColor]))
            addResultRow(symbol: "plus.forwardslash.minus", title: "\(query) = \(value)",
                         trailing: L("panel.search.type.calc"), image: nil, attributedTitle: attr,
                         run: { [weak self] in self?.finish { self?.onCopyValue?(value) } })
        }

        struct Ranked { let score: Int; let build: () -> Void }
        var ranked: [Ranked] = []

        for command in lastCommands {
            guard let score = FuzzyMatch.score(query: query, candidate: command.title()) else { continue }
            ranked.append(Ranked(score: score) { [weak self] in
                self?.addResultRow(symbol: command.symbol(), title: command.title(),
                                   trailing: L("panel.search.type.command"), image: nil,
                                   run: { self?.finish { command.run() } })
            })
        }

        for app in (searchApps?(query) ?? []) {
            let score = FuzzyMatch.bestScore(query: query, candidates: app.searchNames) ?? 0
            ranked.append(Ranked(score: score) { [weak self] in
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                self?.addResultRow(symbol: "app", title: app.name,
                                   trailing: L("panel.search.type.app"), image: icon,
                                   run: { self?.finish { self?.onLaunchApp?(app.url) } })
            })
        }

        for snippet in lastSnippets {
            guard let score = FuzzyMatch.score(query: query, candidate: snippet.displayName) else { continue }
            ranked.append(Ranked(score: score) { [weak self] in
                self?.addResultRow(symbol: Self.snippetSymbol(snippet.kind), title: snippet.displayName,
                                   trailing: Self.snippetTypeLabel(snippet.kind), image: nil,
                                   run: { self?.runSnippet(snippet) })
            })
        }

        ranked.sort { $0.score > $1.score }
        for item in ranked.prefix(12) { item.build() }

        if entries.isEmpty { addInfoRow(L("panel.search.empty")) }
        selectedIndex = entries.isEmpty ? -1 : 0
        updateSelection()
    }

    /// Строка результата поиска (одна колонка на всю ширину). `image` — настоящая иконка приложения.
    private func addResultRow(symbol: String, title: String, trailing: String?,
                              image: NSImage?, attributedTitle: NSAttributedString? = nil,
                              run: @escaping () -> Void) {
        let row = CommandRowView()
        row.configure(badge: nil, symbol: symbol, title: title, trailing: trailing,
                      image: image, attributedTitle: attributedTitle)
        row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
        row.onClick = run
        entries.append(Entry(view: row, badge: nil, digit: nil, commandKey: nil,
                             setSelected: { [weak row] in row?.isSelected = $0 },
                             run: run))
        addRow(row)
    }

    /// Пустое состояние поиска — невыбираемая строка по центру (в `entries` не попадает).
    private func addInfoRow(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        contentStack.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 40),
            container.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    /// Выдаёт следующую цифру 1–9 сниппету (или nil за пределами девяти). Инструменты цифры не
    /// расходуют — они на буквах, поэтому весь ряд 1–9 достаётся сниппетам.
    private func nextSnippetDigit() -> Int? {
        guard snippetDigitCounter < 9 else { return nil }
        snippetDigitCounter += 1
        return snippetDigitCounter
    }

    // MARK: Плитки-тумблеры

    private func makeTile(_ command: ToolboxCommand) -> CommandTileView {
        let tile = CommandTileView()
        let on = command.isOn() == true
        // Микрофон в мьюте — тревожно-красный; остальные включённые тумблеры — акцентные.
        let state: CommandTileView.State = on
            ? (command.id == .micToggle ? .attention : .active)
            : .inactive
        let key = command.id.panelKeyCode
        let badge = keyName(forKeyCode: UInt32(key))
        tile.configure(badge: badge, symbol: command.symbol(), title: command.title(),
                       status: command.trailing() ?? "", state: state)
        let idx = entries.count
        tile.onClick = { [weak self] in self?.runCommand(command, at: idx) }
        entries.append(Entry(view: tile, badge: badge, digit: nil, commandKey: key,
                             setSelected: { [weak tile] in tile?.isSelected = $0 },
                             run: { [weak self] in self?.runCommand(command, at: idx) }))
        return tile
    }

    private func addTileRow(_ tiles: [NSView]) {
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// Ряд из двух колонок, делённый по центральной оси контейнера: правая колонка всегда
    /// начинается на середине (+полузазор), поэтому её левый край стоит на одном X во всех рядах —
    /// в отличие от fillEqually, который при разной ширине контента колонки разъезжается. Высоту
    /// ряда задаёт height-констрейнт самих вложенных строк.
    private func addTwoColumnRow(_ views: [NSView]) {
        guard let left = views.first else { return }
        let gap: CGFloat = 10
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        left.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            left.trailingAnchor.constraint(equalTo: container.centerXAnchor, constant: -gap / 2),
        ])
        if views.count > 1 {
            let right = views[1]
            right.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(right)
            NSLayoutConstraint.activate([
                right.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: gap / 2),
                right.topAnchor.constraint(equalTo: container.topAnchor),
                right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                right.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }

    /// Колонка строки устройств над ползунками: выпадашка текущего устройства, выровненная влево
    /// (имя стоит над иконкой ползунка, усекается с хвоста при нехватке ширины). Пустая колонка,
    /// если направление без выбора устройства.
    private func makeDeviceCell(_ device: SliderDevice?) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        guard let device else { return cell }
        let button = DeviceMenuButton(device: device)
        button.alignment = .left
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Строки

    private func makeCommandRow(_ command: ToolboxCommand) -> CommandRowView {
        let row = CommandRowView()
        let key = command.id.panelKeyCode
        let badge = keyName(forKeyCode: UInt32(key))
        row.configure(badge: badge, symbol: command.symbol(), title: command.title(),
                      trailing: command.trailing())
        let idx = entries.count
        row.onClick = { [weak self] in self?.runCommand(command, at: idx) }
        row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
        entries.append(Entry(view: row, badge: badge, digit: nil, commandKey: key,
                             setSelected: { [weak row] in row?.isSelected = $0 },
                             run: { [weak self] in self?.runCommand(command, at: idx) }))
        return row
    }

    private func makeSnippetRow(_ snippet: Snippet) -> CommandRowView {
        let row = CommandRowView()
        let digit = nextSnippetDigit()
        let badge = digit.map(String.init)
        row.configure(badge: badge, symbol: Self.snippetSymbol(snippet.kind),
                      title: snippet.displayName, trailing: Self.snippetTypeLabel(snippet.kind))
        // Вторичные действия = доступные, кроме первичного (первичное — по клику/Enter).
        let secondary = snippet.availableActivations.filter { $0 != snippet.primaryActivation }
        row.setActions(secondary.map { activation in
            (symbol: Self.activationSymbol(activation),
             tooltip: Self.activationTooltip(activation),
             run: { [weak self] in self?.finish { self?.onSnippetActivation?(snippet, activation) } })
        })
        row.onClick = { [weak self] in self?.runSnippet(snippet) }
        row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
        entries.append(Entry(view: row, badge: badge, digit: digit, commandKey: nil,
                             setSelected: { [weak row] in row?.isSelected = $0 },
                             run: { [weak self] in self?.runSnippet(snippet) },
                             secondary: row.hasSecondaryActions ? { [weak row] in row?.triggerActionPanel() } : nil))
        return row
    }

    private func addRow(_ row: CommandRowView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// Добавляет заголовок секции в стек и только ПОТОМ вешает ширину (иначе констрейнт с
    /// `contentStack` активируется до появления общего предка → Auto Layout exception).
    private func addHeader(_ text: String, trailing: String?) {
        let header = makeHeader(text, trailing: trailing)
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func makeHeader(_ text: String, trailing: String?) -> NSView {
        let left = NSTextField(labelWithString: text.lowercased())
        left.font = .systemFont(ofSize: 11); left.textColor = .secondaryLabelColor
        left.isEditable = false; left.isBordered = false; left.drawsBackground = false
        left.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(left)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        if let trailing {
            let right = NSTextField(labelWithString: trailing)
            right.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            right.textColor = .secondaryLabelColor
            right.isEditable = false; right.isBordered = false; right.drawsBackground = false
            right.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(right)
            NSLayoutConstraint.activate([
                right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
                right.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            ])
        }
        return container
    }

    // MARK: Выделение и запуск

    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + entries.count) % entries.count
        updateSelection()
        entries[selectedIndex].view.scrollToVisible(entries[selectedIndex].view.bounds)
    }

    private func updateSelection() {
        for (i, entry) in entries.enumerated() { entry.setSelected(i == selectedIndex) }
    }

    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        guard entries.indices.contains(target) else { NSSound.beep(); return }
        entries[target].run()
    }

    /// Быстрый выбор цифрой 1–9: запускаем сниппет с этим номером (команды на буквах, история
    /// номеров не имеет).
    private func runDigit(_ digit: Int) {
        guard let entry = entries.first(where: { $0.digit == digit }) else { NSSound.beep(); return }
        entry.run()
    }

    /// Быстрый выбор буквой команды по физическому keyCode. Возвращает true, если команда с таким
    /// кодом есть (тогда событие поглощено); иначе false — незанятая буква уходит в `super`.
    private func runCommandKey(_ keyCode: UInt16) -> Bool {
        guard let entry = entries.first(where: { $0.commandKey == keyCode }) else { return false }
        entry.run()
        return true
    }

    /// Тумблер остаётся в панели (обновляет плитку); команда-модуль разворачивается на месте (панель
    /// не закрываем); прочие лончеры/действия закрывают панель.
    private func runCommand(_ command: ToolboxCommand, at index: Int) {
        if command.isOn() != nil {
            command.run()
            refreshTile(command, at: index)
        } else if onPresentCommandModule?(command) == true {
            // команда открыла модуль внутри палитры — панель остаётся открытой
        } else {
            finish { command.run() }
        }
    }

    private func refreshTile(_ command: ToolboxCommand, at index: Int) {
        guard let tile = entries[safe: index]?.view as? CommandTileView else { return }
        let on = command.isOn() == true
        let state: CommandTileView.State = on
            ? (command.id == .micToggle ? .attention : .active)
            : .inactive
        tile.configure(badge: entries[safe: index]?.badge, symbol: command.symbol(),
                       title: command.title(), status: command.trailing() ?? "", state: state)
        tile.isSelected = (index == selectedIndex)
    }

    private func runSnippet(_ snippet: Snippet) {
        finish { [weak self] in self?.onSnippetActivation?(snippet, snippet.primaryActivation) }
    }

    private func finish(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        window?.close()
        action()
    }

    func windowWillClose(_ notification: Notification) {
        stopVolumePolling()
        onClose?()
    }

    // MARK: Геометрия

    /// Подгоняет окно под текущий режим, сохраняя верхнюю кромку (панель растёт вниз, не «прыгает»).
    /// Используется при живом ресайзе в корне (разворачивание секций/результаты поиска).
    private func sizeToFit() {
        guard let window else { return }
        let size = contentSizeForCurrentMode()
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
        clampIntoActiveScreen()
    }

    /// Минимально сдвигает окно, чтобы оно целиком помещалось на активном экране (корень, растущий
    /// вниз в модуль, может выйти за нижнюю кромку). Двигаем только при выходе за край — иначе
    /// верхняя кромка (наш якорь) остаётся на месте.
    private func clampIntoActiveScreen() {
        guard let window, let area = activeScreen()?.visibleFrame else { return }
        var origin = window.frame.origin
        let size = window.frame.size
        if origin.x + size.width > area.maxX { origin.x = area.maxX - size.width }
        if origin.x < area.minX { origin.x = area.minX }
        if origin.y + size.height > area.maxY { origin.y = area.maxY - size.height }
        if origin.y < area.minY { origin.y = area.minY }
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// Требуемый размер контента под текущий режим (без изменения позиции окна) — единый источник
    /// для `sizeToFit` (по верхней кромке) и `resizeKeepingCenter` (по центру).
    private func contentSizeForCurrentMode() -> NSSize {
        if case .module(let module) = mode { return moduleContentSize(module) }
        contentStack.layoutSubtreeIfNeeded()
        let content = contentStack.fittingSize.height + 12  // + верх/низ отступы listView
        // заголовок+поиск (66) + зазор + футер(11) + низ. 66 = searchTop 32 + height 28 + gap 6.
        let chrome: CGFloat = 66 + 6 + 11 + 10 + 6
        // Потолок — по высоте активного экрана (минус поля), чтобы фикс-часть + разумный список
        // сниппетов помещались без скролла; `maxHeight` остаётся фолбэком, если экрана нет.
        let ceiling = activeScreen().map { $0.visibleFrame.height - 40 } ?? Self.maxHeight
        let height = min(content + chrome, ceiling)
        // Ширина: контент может требовать больше `Self.width` (длинные имена устройств, длинный
        // футер-подсказка). Берём фактически необходимую ширину, иначе центр посчитается по 470,
        // а Auto Layout затем дорастит окно вправо → съезд от центра.
        panelContent.layoutSubtreeIfNeeded()
        let widthCeiling = activeScreen().map { $0.visibleFrame.width - 40 } ?? Self.width
        let width = min(max(Self.width, panelContent.fittingSize.width), widthCeiling)
        return NSSize(width: width, height: height)
    }

    /// Требуемый размер контента под модуль: хедер (top 9 + марка 18 + зазор 8 до тела) + желаемая
    /// высота контента модуля + нижний отступ, с тем же экранным потолком, что у корня.
    private func moduleContentSize(_ module: PaletteModule) -> NSSize {
        let width = Self.width
        let headerAllowance: CGFloat = 9 + 18 + 8
        let ceiling = activeScreen().map { $0.visibleFrame.height - 40 } ?? Self.maxHeight
        let height = min(headerAllowance + module.fittingHeight(forWidth: width) + 10, ceiling)
        return NSSize(width: width, height: height)
    }

    /// Экран под курсором (или основной) — общая опора для потолка высоты и центрирования.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func centerOnActiveScreen() {
        guard let window else { return }
        guard let area = activeScreen()?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    // MARK: Сниппеты — иконки/типы

    private static func snippetSymbol(_ kind: SnippetKind) -> String {
        switch kind {
        case .secret: return "key.fill"
        case .text:   return "text.alignleft"
        case .link:   return "link"
        }
    }

    private static func snippetTypeLabel(_ kind: SnippetKind) -> String {
        switch kind {
        case .secret: return L("snippet.kind.secret")
        case .text:   return L("snippet.kind.text")
        case .link:   return L("snippet.kind.link")
        }
    }

    private static func activationSymbol(_ activation: SnippetActivation) -> String {
        switch activation {
        case .paste: return "arrow.down.doc"
        case .open:  return "arrow.up.right.square"
        case .copy:  return "doc.on.doc"
        }
    }

    private static func activationTooltip(_ activation: SnippetActivation) -> String {
        switch activation {
        case .paste: return L("snippet.picker.paste")
        case .open:  return L("snippet.picker.open")
        case .copy:  return L("snippet.picker.copy")
        }
    }
}

// MARK: - Общее стекло и предпросмотр

/// Оборачивает контент окна в Liquid Glass (macOS 26) или матовое стекло (фолбэк). Переиспользуют
/// панель команд и окно истории буфера.
func installGlass(in window: NSWindow, content: NSView) {
    window.isOpaque = false
    window.backgroundColor = .clear
    content.translatesAutoresizingMaskIntoConstraints = false
    let container: NSView
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        glass.style = .regular
        glass.tintColor = nil
        glass.contentView = content
        container = glass
    } else {
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.addSubview(content)
        container = backdrop
    }
    window.contentView = container
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        content.topAnchor.constraint(equalTo: container.topAnchor),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    // Нейтральная подложка под стекло (в самом низу `content`, под будущим UI) — гасит
    // избыточную прозрачность. Прозрачна для мыши, перетаскивание за фон не ломает.
    Brand.addGlassTint(to: content)
}

/// Однострочный обрезанный предпросмотр значения из истории буфера.
func historyPreview(_ text: String) -> String {
    let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
}

// MARK: - Общие строки-пикеры (Item + билдеры)

/// Неймспейс общих строк-пикеров (история буфера, аудиоустройства): тип `Item` и статические
/// билдеры строк. Окно-список теперь живёт внутри палитры как `GlassListModule` — отдельного окна нет.
enum GlassListWindowController {

    struct Item {
        let view: NSView
        let digit: Int?
        /// Применимо ли (у трансформации с nil-результатом — false: сигнал, окно остаётся).
        let enabled: Bool
        let setSelected: (Bool) -> Void
        let setOnClick: (@escaping () -> Void) -> Void
        let run: () -> Void
    }

    // MARK: - Билдеры Item

    static func historyItems(_ history: [String], onPaste: @escaping (String) -> Void) -> [Item] {
        history.enumerated().map { index, text in
            let digit = index < 9 ? index + 1 : nil
            let row = HistoryRowView()
            row.configure(digit: digit, text: historyPreview(text))
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            return Item(view: row, digit: digit, enabled: true,
                        setSelected: { [weak row] in row?.isSelected = $0 },
                        setOnClick: { [weak row] handler in row?.onClick = handler },
                        run: { onPaste(text) })
        }
    }

    static func audioItems(_ devices: [AudioDevice], currentID: AudioDeviceID?,
                           onPick: @escaping (AudioDeviceID) -> Void) -> (items: [Item], preselect: Int) {
        var preselect = 0
        let items = devices.enumerated().map { index, device -> Item in
            let digit = index < 9 ? index + 1 : nil
            let isCurrent = device.id == currentID
            if isCurrent { preselect = index }
            let row = CommandRowView()
            row.configure(badge: digit.map(String.init), symbol: audioSymbol(device.transport),
                          title: device.name, trailing: isCurrent ? L("audio.current") : nil)
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            return Item(view: row, digit: digit, enabled: true,
                        setSelected: { [weak row] in row?.isSelected = $0 },
                        setOnClick: { [weak row] handler in row?.onClick = handler },
                        run: { onPick(device.id) })
        }
        return (items, preselect)
    }

    static func transformSymbol(_ t: TextTransform) -> String {
        switch t {
        case .upper, .lower, .title, .camel, .snake, .kebab, .constant, .slug: return "textformat"
        case .trim, .collapseSpaces, .removeEmptyLines, .joinLines: return "wand.and.stars"
        case .jsonPretty, .jsonMinify: return "curlybraces"
        case .urlEncode, .urlDecode: return "link"
        case .base64Encode, .base64Decode: return "barcode"
        case .jwtDecode: return "key.horizontal"
        case .sortLines, .sortLinesDesc, .dedupeLines, .reverseLines: return "arrow.up.arrow.down"
        case .appendPeriod, .appendComma, .appendSemicolon: return "text.append"
        }
    }
    private static func audioSymbol(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Обобщённый список как модуль палитры

/// Тот же список-пикер, что `GlassListWindowController`, но как `PaletteModule` — живёт внутри окна
/// палитры (история буфера, аудиоустройства). Переиспользует `Item` и статические билдеры того
/// контроллера. Хедер рисует палитра (по `titleKey`); опц. кнопка-корзина — в футере модуля.
final class GlassListModule: NSObject, PaletteModule {
    typealias Item = GlassListWindowController.Item

    let titleKey: String
    private let emptyKey: String?
    private let rowHeight: CGFloat
    private let maxContentHeight: CGFloat
    private var clearHandler: (() -> Void)?

    private var items: [Item] = []
    private var selectedIndex = 0
    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var clearButton: ClosureButton?
    private weak var host: PaletteHost?

    private var window: NSWindow? { contentView.window }

    init(titleKey: String, emptyKey: String? = nil, rowHeight: CGFloat = 40, maxContentHeight: CGFloat = 520) {
        self.titleKey = titleKey
        self.emptyKey = emptyKey
        self.rowHeight = rowHeight
        self.maxContentHeight = maxContentHeight
        super.init()
    }

    /// Включает кнопку-корзину в футере (напр. очистка истории): клик — `handler` + закрыть палитру.
    func enableClearButton(_ handler: @escaping () -> Void) {
        clearHandler = handler
    }

    /// Задаёт содержимое списка перед `enterModule` (аналог `prefill` у transform). Форсит сборку
    /// ленивой вьюхи, чтобы `contentStack`/`emptyLabel` уже существовали.
    func configure(items: [Item], preselect: Int = 0) {
        _ = contentView
        self.items = items
        rebuild()
        selectedIndex = items.isEmpty ? -1 : min(max(preselect, 0), items.count - 1)
        updateSelection()
        emptyLabel.isHidden = !items.isEmpty
        clearButton?.isHidden = (clearHandler == nil || items.isEmpty)
    }

    // MARK: PaletteModule

    private(set) lazy var contentView: NSView = buildContent()

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        contentStack.layoutSubtreeIfNeeded()
        let inner = items.isEmpty ? 60 : contentStack.fittingSize.height + 12
        // футер: зазор до подсказки (6) + подсказка (~14) + нижний отступ (10) + верхний отступ (6).
        let footer: CGFloat = 6 + 14 + 10 + 6
        return min(inner + footer, maxContentHeight)
    }

    func moduleWillAppear(host: PaletteHost) {
        self.host = host
        window?.makeFirstResponder(listView)
    }

    func handleCommandReturn() -> Bool { false }  // Enter обрабатывает список; ⌘↩ семантики нет

    private func buildContent() -> NSView {
        let content = NSView()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(contentStack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listView
        content.addSubview(scroll)

        emptyLabel.stringValue = emptyKey.map { L($0) } ?? ""
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        let hint = NSTextField(labelWithString: L("panel.footer"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        // Кнопка-корзина в футере (справа), видна только когда включена и список непустой.
        let clear = ClosureButton(symbol: "trash", tooltip: L("panel.clipboard.clear")) { [weak self] in
            self?.clearHandler?()
            self?.host?.closePalette()
        }
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.isHidden = true
        content.addSubview(clear)
        clearButton = clear

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            listView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -8),
            hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            clear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clear.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] _ in self?.runIndex(-1) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onClose = { [weak self] in self?.host?.dismissModule() }
        return content
    }

    private func rebuild() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            item.setOnClick { [weak self] in self?.runIndex(index) }
            item.view.translatesAutoresizingMaskIntoConstraints = false
            item.view.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            contentStack.addArrangedSubview(item.view)
            item.view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        updateSelection()
        items[selectedIndex].view.scrollToVisible(items[selectedIndex].view.bounds)
    }
    private func updateSelection() {
        for (i, item) in items.enumerated() { item.setSelected(i == selectedIndex) }
    }
    private func runDigit(_ digit: Int) {
        guard let index = items.firstIndex(where: { $0.digit == digit }) else { NSSound.beep(); return }
        runIndex(index)
    }
    /// Выбор строки закрывает палитру целиком (как вставка сниппета/transform) и выполняет действие.
    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        guard items.indices.contains(target) else { NSSound.beep(); return }
        let item = items[target]
        guard item.enabled else { NSSound.beep(); return }
        host?.closePalette()
        item.run()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
