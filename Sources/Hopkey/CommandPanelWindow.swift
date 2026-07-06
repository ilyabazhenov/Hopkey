import AppKit
import CoreAudio
import HopkeyCore

/// Панель-палитра команд: тумблеры (плитки), разовые действия и сниппеты (строки) на одной
/// поверхности. Вызывается двойным тапом правого ⌘ или левым кликом по иконке. Неактивирующая
/// стеклянная панель в идиоме пикера сниппетов — фокус целевого приложения не теряется, поэтому
/// вставка сниппета/paste попадает туда, где стоял курсор.
private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
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

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
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
/// (красный — микрофон замьючен/тревога, янтарный — включённый тумблер, иначе нейтральный).
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
            // Янтарь для включённого тумблера — чтобы не конфликтовать с синей рамкой выделения.
            fill = NSColor.systemOrange.withAlphaComponent(0.16)
            stroke = .systemOrange
            fg = .systemOrange
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

    func configure(badge: String?, symbol: String, title: String, trailing: String?) {
        keycap.value = badge ?? ""
        let hasBadge = !(badge ?? "").isEmpty
        iconLeadingToBadge.isActive = hasBadge
        iconLeadingToEdge.isActive = !hasBadge
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
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

    /// Цвет заполненной части трека и процента по уровню: низко — красный (тревога), выше —
    /// оранжевый/жёлтый, норма — зелёный. Процент подсвечиваем только в тревожной зоне, иначе он
    /// остаётся приглушённым — чтобы «низко» било в глаза, а норма выглядела спокойно.
    private func applyLevelTint(_ value: Float) {
        guard reflectsLevel else { return }
        let color = Self.levelColor(value)
        slider.trackFillColor = color
        valueLabel.textColor = value < 0.40 ? color : .secondaryLabelColor
    }

    private static func levelColor(_ v: Float) -> NSColor {
        switch v {
        case ..<0.20: return .systemRed
        case ..<0.40: return .systemOrange
        case ..<0.60: return .systemYellow
        default:       return .systemGreen
        }
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


final class CommandPanelWindowController: NSWindowController, NSWindowDelegate {

    /// Действие над сниппетом: первичное (клик/Enter) или вторичное (кнопки в строке).
    var onSnippetActivation: ((Snippet, SnippetActivation) -> Void)?
    /// Панель закрылась (Esc/выбор/клик мимо) — вызывающий сбрасывает состояние жеста-триггера.
    var onClose: (() -> Void)?

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
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
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
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildChrome() {
        guard let window else { return }
        // Весь контент панели живёт в одном контейнере, который кладётся внутрь стекла.
        let content = panelContent
        installGlass(in: window, content: content)

        let header = Brand.makeHeaderView(title: L("panel.title"))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

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

        let hint = NSTextField(labelWithString: L("panel.footer.commands"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),

            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            listView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 6),
            contentStack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -6),
            contentStack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -6),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] index in self?.runIndex(index) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onCommandKey = { [weak self] keyCode in self?.runCommandKey(keyCode) ?? false }
        listView.onClose = { [weak self] in self?.window?.close() }
        listView.onHorizontal = { [weak self] delta in self?.horizontalOnSelection(delta) }
        listView.onSecondary = { [weak self] in self?.secondaryOnSelection() }
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
        // Микрофон в мьюте — тревожно-красный; остальные включённые тумблеры — янтарные.
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

    /// Тумблер остаётся в панели (обновляет плитку), лончеры/действия закрывают её.
    private func runCommand(_ command: ToolboxCommand, at index: Int) {
        if command.isOn() != nil {
            command.run()
            refreshTile(command, at: index)
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

    private func sizeToFit() {
        guard let window else { return }
        contentStack.layoutSubtreeIfNeeded()
        let content = contentStack.fittingSize.height + 12  // + верх/низ отступы listView
        let chrome: CGFloat = 36 + 6 + 11 + 10 + 6  // заголовок + зазоры + футер
        // Потолок — по высоте активного экрана (минус поля), чтобы фикс-часть + разумный список
        // сниппетов помещались без скролла; `maxHeight` остаётся фолбэком, если экрана нет.
        let ceiling = activeScreen().map { $0.visibleFrame.height - 40 } ?? Self.maxHeight
        let height = min(content + chrome, ceiling)
        // Ширина: контент может требовать больше `Self.width` (длинные имена устройств, длинный
        // футер-подсказка). Берём фактически необходимую ширину, иначе `centerOnActiveScreen`
        // посчитает центр по 470, а Auto Layout затем дорастит окно вправо → съезд от центра.
        panelContent.layoutSubtreeIfNeeded()
        let widthCeiling = activeScreen().map { $0.visibleFrame.width - 40 } ?? Self.width
        let width = min(max(Self.width, panelContent.fittingSize.width), widthCeiling)
        // Сохраняем верхнюю кромку окна — при разворачивании секции панель растёт вниз, не «прыгает».
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameTopLeftPoint(topLeft)
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
}

/// Однострочный обрезанный предпросмотр значения из истории буфера.
func historyPreview(_ text: String) -> String {
    let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
}

// MARK: - Обобщённое окно-список (пикер)

/// Обобщённое стеклянное окно-список: заголовок, прокручиваемый список строк с клавнавигацией
/// (стрелки/1–9/Enter/Esc), выделение, пустое состояние, опц. кнопка-корзина в заголовке.
/// Специфику строк (история/трансформации/аудио) дают статические билдеры `Item`.
final class GlassListWindowController: NSWindowController, NSWindowDelegate {

    struct Item {
        let view: NSView
        let digit: Int?
        /// Применимо ли (у трансформации с nil-результатом — false: сигнал, окно остаётся).
        let enabled: Bool
        let setSelected: (Bool) -> Void
        let setOnClick: (@escaping () -> Void) -> Void
        let run: () -> Void
    }

    private let titleKey: String
    private let emptyKey: String?
    private let rowHeight: CGFloat
    private let width: CGFloat
    private let maxHeight: CGFloat
    private var clearHandler: (() -> Void)?

    private var items: [Item] = []
    private var selectedIndex = 0
    private var finished = false
    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var clearButton: ClosureButton?

    init(titleKey: String, emptyKey: String? = nil, rowHeight: CGFloat = 40,
         width: CGFloat = 460, maxHeight: CGFloat = 560) {
        self.titleKey = titleKey
        self.emptyKey = emptyKey
        self.rowHeight = rowHeight
        self.width = width
        self.maxHeight = maxHeight
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 280),
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
        buildChrome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Включает кнопку-корзину в заголовке (напр. очистка истории). Клик — `handler` + закрыть.
    func enableClearButton(_ handler: @escaping () -> Void) {
        clearHandler = handler
    }

    private func buildChrome() {
        guard let window else { return }
        let content = NSView()
        installGlass(in: window, content: content)

        let header = Brand.makeHeaderView(title: L(titleKey))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let clear = ClosureButton(symbol: "trash", tooltip: L("panel.clipboard.clear")) { [weak self] in
            self?.clearHandler?()
            self?.window?.close()
        }
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.isHidden = true
        content.addSubview(clear)
        clearButton = clear

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

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            clear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

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

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onRun = { [weak self] _ in self?.runIndex(-1) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onClose = { [weak self] in self?.window?.close() }
    }

    func show(items: [Item], preselect: Int = 0) {
        finished = false
        self.items = items
        rebuild()
        selectedIndex = items.isEmpty ? -1 : min(max(preselect, 0), items.count - 1)
        updateSelection()
        emptyLabel.isHidden = !items.isEmpty
        clearButton?.isHidden = (clearHandler == nil || items.isEmpty)
        sizeToFit()
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(listView)
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
    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        guard items.indices.contains(target) else { NSSound.beep(); return }
        let item = items[target]
        guard item.enabled else { NSSound.beep(); return }
        finish { item.run() }
    }
    private func finish(_ action: @escaping () -> Void) {
        guard !finished else { return }
        finished = true
        window?.close()
        action()
    }
    func windowWillClose(_ notification: Notification) {}

    private func sizeToFit() {
        guard let window else { return }
        contentStack.layoutSubtreeIfNeeded()
        let inner = items.isEmpty ? 60 : contentStack.fittingSize.height + 12
        let chrome: CGFloat = 36 + 6 + 11 + 10 + 6
        let height = min(inner + chrome, maxHeight)
        window.setContentSize(NSSize(width: width, height: height))
    }
    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
