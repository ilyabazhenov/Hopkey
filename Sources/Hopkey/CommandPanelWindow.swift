import AppKit
import Carbon.HIToolbox
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
    /// ⌫ / Fn+⌫ — удалить текущее выделение (напр. запись истории). Палитра остаётся открытой.
    var onDelete: (() -> Void)?

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
        case 51, 117: onDelete?()    // ⌫ (backspace) / ⌦ (forward delete) — удалить выделение
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
/// SF-символ на мягкой тонированной подложке (скруглённый квадрат) — цветовой «якорь» команды.
/// Подложка бледная (~14 %), сам символ насыщенный. При `tint == nil` подложка прозрачна, а символ
/// красится нейтрально (серым) — так строки-результаты и полноцветные иконки приложений выглядят
/// как раньше, без цветного квадрата под ними.
private final class IconChip: NSView {
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    var image: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }

    /// `tint == nil` → прозрачная подложка + нейтральный символ. Полноцветные картинки (иконки
    /// приложений) `contentTintColor` не перекрашивает, так что для них tint не важен.
    func apply(tint: NSColor?) {
        if let tint {
            layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
            iconView.contentTintColor = tint
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            iconView.contentTintColor = .secondaryLabelColor
        }
    }
}

private final class CommandTileView: NSView {
    enum State { case inactive, active, attention }

    var onClick: (() -> Void)?

    private let chip = IconChip()
    private let numberLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private var state: State = .inactive
    var isSelected = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        chip.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        // Заголовок переносится в две строки: в ряду по три плитки длинные имена («Не давать
        // засыпать») в одну строку не влезают и раньше усекались.
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        for field in [numberLabel, titleLabel, statusLabel] {
            field.isEditable = false; field.isBordered = false; field.drawsBackground = false
        }
        // Статус-пилюля: подложка красится по состоянию (см. refresh), «вкл»/«выкл» сидит с отступами.
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 9
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)

        addSubview(chip); addSubview(numberLabel); addSubview(titleLabel); addSubview(statusPill)
        // Статус-пилюля прижата к нижней кромке, заголовок центрируется в зоне между чипом и пилюлей:
        // так «вкл»/«выкл» всех плиток (и стат-строка карточки «Звук») стоят на одной нижней линии, а
        // одно- и двухстрочные названия смотрятся сбалансированно, без «верхо-тяжёлой» пустоты снизу.
        let titleZone = NSLayoutGuide()
        addLayoutGuide(titleZone)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            chip.widthAnchor.constraint(equalToConstant: 26),
            chip.heightAnchor.constraint(equalToConstant: 26),
            numberLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            numberLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            numberLabel.leadingAnchor.constraint(greaterThanOrEqualTo: chip.trailingAnchor, constant: 6),

            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -2),
            statusPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusPill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            statusPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            titleZone.topAnchor.constraint(equalTo: chip.bottomAnchor),
            titleZone.bottomAnchor.constraint(equalTo: statusPill.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: titleZone.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 98),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func mouseUp(with event: NSEvent) { onClick?() }

    func configure(badge: String?, symbol: String, title: String, status: String, state: State) {
        self.state = state
        chip.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        numberLabel.stringValue = badge ?? ""
        titleLabel.stringValue = title
        statusLabel.stringValue = status
        statusPill.isHidden = status.isEmpty
        setAccessibilityLabel("\(title). \(status)")
        refresh()
    }

    private func refresh() {
        // Один «тон» состояния красит чип, номер, заголовок и пилюлю: мьют — красный, включённый
        // тумблер — системный акцент, выключенный — нейтральный серый.
        let tone: NSColor
        let tileFill: NSColor
        let stroke: NSColor
        switch state {
        case .attention:
            tone = .systemRed
            tileFill = NSColor.systemRed.withAlphaComponent(0.14); stroke = .systemRed
        case .active:
            tone = .controlAccentColor
            tileFill = NSColor.controlAccentColor.withAlphaComponent(0.16); stroke = .controlAccentColor
        case .inactive:
            tone = .secondaryLabelColor
            tileFill = .clear; stroke = .separatorColor
        }
        layer?.backgroundColor = tileFill.cgColor
        chip.apply(tint: tone)
        numberLabel.textColor = tone
        titleLabel.textColor = (state == .inactive) ? .labelColor : tone
        statusLabel.textColor = tone
        statusPill.layer?.backgroundColor = tone.withAlphaComponent(state == .inactive ? 0.10 : 0.18).cgColor
        // Выделение с клавиатуры — акцентная рамка поверх состояния.
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : stroke).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
    }
}

/// Компактная карточка «Звук» в ряду переключателей: показывает только текущие уровни (выход/вход)
/// и шеврон-намёк. Клик/буква проваливают в отдельный экран уровней (`LevelsModule`) — там уже
/// живут ползунки и выбор устройства. Нейтральная плитка (как выключенный тумблер), при выделении —
/// акцентная рамка; своих состояний on/off у неё нет.
private final class SoundCardView: NSView {
    var onClick: (() -> Void)?

    private let chip = IconChip()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let outIcon = NSImageView()
    private let outLabel = NSTextField(labelWithString: "")
    private let inIcon = NSImageView()
    private let inLabel = NSTextField(labelWithString: "")

    var isSelected = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        // Карточка «Звук» ведёт в drill-in экран «Уровни» — синий чип завязывает её на этот переход.
        chip.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        chip.apply(tint: .systemBlue)
        chip.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .right

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.imageScaling = .scaleProportionallyDown
        chevron.translatesAutoresizingMaskIntoConstraints = false

        for (view, symbol) in [(outIcon, "speaker.wave.1"), (inIcon, "mic")] {
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            view.contentTintColor = .secondaryLabelColor
            view.imageScaling = .scaleProportionallyDown
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for label in [outLabel, inLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
        }
        for field in [badgeLabel, titleLabel, outLabel, inLabel] {
            field.isEditable = false; field.isBordered = false; field.drawsBackground = false
        }

        let stats = NSStackView(views: [outIcon, outLabel, inIcon, inLabel])
        stats.orientation = .horizontal
        stats.spacing = 4
        stats.setCustomSpacing(10, after: outLabel)
        stats.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip); addSubview(badgeLabel); addSubview(titleLabel)
        addSubview(chevron); addSubview(stats)
        // Та же раскладка, что у плиток-тумблеров (см. CommandTileView): стат-строка прижата к низу,
        // заголовок «Звук» центрируется в зоне между иконкой и статами — уровни встают на одну линию
        // с «вкл»/«выкл» соседних плиток.
        let titleZone = NSLayoutGuide()
        addLayoutGuide(titleZone)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            chip.widthAnchor.constraint(equalToConstant: 26),
            chip.heightAnchor.constraint(equalToConstant: 26),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badgeLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            stats.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stats.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stats.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            outIcon.widthAnchor.constraint(equalToConstant: 14),
            outIcon.heightAnchor.constraint(equalToConstant: 14),
            inIcon.widthAnchor.constraint(equalToConstant: 14),
            inIcon.heightAnchor.constraint(equalToConstant: 14),

            titleZone.topAnchor.constraint(equalTo: chip.bottomAnchor),
            titleZone.bottomAnchor.constraint(equalTo: stats.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: titleZone.centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
            heightAnchor.constraint(equalToConstant: 98),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func mouseUp(with event: NSEvent) { onClick?() }

    func configure(badge: String, output: Float?, input: Float?) {
        badgeLabel.stringValue = badge
        titleLabel.stringValue = L("panel.sound.title")
        updateLevels(output: output, input: input)
    }

    /// Обновляет проценты (стартово и при опросе системной громкости). Направление, которого
    /// устройство не поддерживает (значение nil), в карточке не показываем.
    func updateLevels(output: Float?, input: Float?) {
        outIcon.isHidden = (output == nil)
        outLabel.isHidden = (output == nil)
        outLabel.stringValue = Self.percent(output)
        inIcon.isHidden = (input == nil)
        inLabel.isHidden = (input == nil)
        inLabel.stringValue = Self.percent(input)
        let parts = [output.map { _ in "\(L("panel.section.output")) \(Self.percent(output))" },
                     input.map { _ in "\(L("panel.section.input")) \(Self.percent(input))" }]
        setAccessibilityLabel("\(L("panel.sound.title")). " + parts.compactMap { $0 }.joined(separator: ", "))
    }

    private func refresh() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
    }

    private static func percent(_ value: Float?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
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

/// Единая «пилюля» выделения: одна подложка, которая физически переезжает пружиной от прошлой
/// позиции к текущей (magic-move), а не телепортирует подсветку по строкам. Живёт под списком,
/// строки/плитки свою заливку-выбор больше не рисуют — подсветку целиком держит она.
private final class SelectionPill: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Переезд к целевому кадру. `animated == false` — мгновенно (первое появление, ресайз);
    /// иначе позиция едет мягкой пружиной с едва заметным доездом, а размер и радиус углов
    /// задемпфированы критически (без колебаний) — иначе пилюля «резинится» на переходе между
    /// крупной плиткой и тонкой строкой.
    func move(to target: NSRect, cornerRadius: CGFloat, animated: Bool) {
        guard let layer else { return }
        let wasHidden = isHidden
        isHidden = false
        // От нуля/скрытого состояния не летим — просто проявляемся на месте.
        guard animated, !wasHidden, !frame.isEmpty else {
            layer.removeAnimation(forKey: "pillMove")
            layer.removeAnimation(forKey: "pillResize")
            layer.removeAnimation(forKey: "pillRadius")
            frame = target
            layer.cornerRadius = cornerRadius
            return
        }
        let oldPosition = layer.presentation()?.position ?? layer.position
        let oldBounds = layer.presentation()?.bounds ?? layer.bounds
        let oldRadius = layer.presentation()?.cornerRadius ?? layer.cornerRadius
        frame = target
        layer.cornerRadius = cornerRadius

        // Позиция: ζ≈0.85 при высокой жёсткости — быстрый доезд с едва заметным «приземлением».
        let move = CASpringAnimation(keyPath: "position")
        move.fromValue = NSValue(point: oldPosition)
        move.toValue = NSValue(point: layer.position)
        move.stiffness = 2400; move.damping = 92; move.mass = 1
        move.duration = move.settlingDuration
        layer.add(move, forKey: "pillMove")

        // Размер: ζ≈1 — оседает без колебания, не тянется резиной.
        let resize = CASpringAnimation(keyPath: "bounds.size")
        resize.fromValue = NSValue(size: oldBounds.size)
        resize.toValue = NSValue(size: layer.bounds.size)
        resize.stiffness = 2600; resize.damping = 102; resize.mass = 1
        resize.duration = resize.settlingDuration
        layer.add(resize, forKey: "pillResize")

        // Радиус — короткий ease, чтобы угол не щёлкал на переходе 12↔8.
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = oldRadius
        radius.toValue = cornerRadius
        radius.duration = 0.12
        radius.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(radius, forKey: "pillRadius")
    }
}

/// Короткий «щелчок» при активации элемента: масштаб 1→0.93→1 за ~0.16с. Визуальный аналог
/// тактильного отклика — виден при любом вводе, в отличие от трекпадных haptics.
private func pressBounce(_ view: NSView) {
    guard let layer = view.layer else { return }
    let anim = CAKeyframeAnimation(keyPath: "transform.scale")
    anim.values = [1.0, 0.93, 1.0]
    anim.keyTimes = [0, 0.4, 1]
    anim.duration = 0.16
    anim.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                            CAMediaTimingFunction(name: .easeIn)]
    layer.add(anim, forKey: "pressBounce")
}

/// Переносит пилюлю под выбранную вьюху в координатах документа списка. Форсит раскладку — иначе
/// на первой сборке кадры ещё нулевые. `selected == nil` (пустой список) — прячем пилюлю.
private func positionPill(_ pill: SelectionPill, in listView: NSView, selected: NSView?, animated: Bool) {
    listView.layoutSubtreeIfNeeded()
    guard let selected else { pill.isHidden = true; return }
    let frame = selected.convert(selected.bounds, to: listView)
    guard !frame.isEmpty else { pill.isHidden = true; return }
    pill.move(to: frame, cornerRadius: selected.layer?.cornerRadius ?? 10, animated: animated)
}

/// Строка (действие / лончер / сниппет): номер + иконка + название + трейлинг (хоткей действия
/// или тип сниппета). У сниппетов на hover/выборе трейлинг сменяется кнопками действий.
/// Выделение — нейтральная акцентная заливка, hover — слабая серая.
final class CommandRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let keycap = NumberBadge()
    private let chip = IconChip()
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
        chip.translatesAutoresizingMaskIntoConstraints = false

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

        addSubview(keycap); addSubview(chip); addSubview(titleLabel)
        addSubview(trailingLabel); addSubview(actionsStack)
        iconLeadingToBadge = chip.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 8)
        iconLeadingToEdge = chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 20),
            keycap.heightAnchor.constraint(equalToConstant: 20),
            iconLeadingToBadge,
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 24),
            chip.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 10),
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
    /// `tint` красит подложку чипа под иконкой; `nil` — прозрачная подложка (результаты поиска,
    /// строки устройств, полноцветные иконки приложений остаются как раньше).
    func configure(badge: String?, symbol: String, title: String, trailing: String?,
                   image: NSImage? = nil, attributedTitle: NSAttributedString? = nil,
                   tint: NSColor? = nil) {
        keycap.value = badge ?? ""
        let hasBadge = !(badge ?? "").isEmpty
        iconLeadingToBadge.isActive = hasBadge
        iconLeadingToEdge.isActive = !hasBadge
        chip.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        // Полноцветную иконку приложения не сажаем на цветной квадрат — её показываем «как есть».
        chip.apply(tint: image == nil ? tint : nil)
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
        // Выбор рисует общая пилюля — строка держит только hover-заливку.
        let color = isHovered ? NSColor.secondaryLabelColor.withAlphaComponent(0.10) : .clear
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
        // Выбор рисует общая пилюля — ряд слайдера собственную заливку-выбор не держит.
        layer?.backgroundColor = NSColor.clear.cgColor
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
    /// Мета справа: приложение-источник + относительная дата. Прячется на hover/выборе, уступая
    /// место паста-глифу.
    private let metaLabel = NSTextField(labelWithString: "")
    /// Миниатюра для записи-картинки (у текстовой строки скрыта).
    private let thumb = NSImageView()
    private var tracking: NSTrackingArea?
    /// Два взаимоисключающих leading-констрейнта текста: к кейпаду (текст) или к миниатюре
    /// (картинка). Активируем нужный в `configure`.
    private var textLeadingToKeycap: NSLayoutConstraint!
    private var textLeadingToThumb: NSLayoutConstraint!

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

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.isHidden = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.usesSingleLineMode = true
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.alignment = .right
        metaLabel.isEditable = false; metaLabel.isBordered = false; metaLabel.drawsBackground = false
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        // Мета держит свою ширину, обрезается первым сам предпросмотр, а не приложение/дата.
        metaLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        metaLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(keycap); addSubview(thumb); addSubview(textLabel); addSubview(metaLabel); addSubview(pasteIcon)
        textLeadingToKeycap = textLabel.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 10)
        textLeadingToThumb = textLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            keycap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.widthAnchor.constraint(equalToConstant: 20),
            keycap.heightAnchor.constraint(equalToConstant: 20),
            thumb.leadingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: 10),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 24),
            thumb.heightAnchor.constraint(equalToConstant: 24),
            textLeadingToKeycap,
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -8),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metaLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            metaLabel.leadingAnchor.constraint(greaterThanOrEqualTo: thumb.trailingAnchor, constant: 8),
            pasteIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pasteIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pasteIcon.widthAnchor.constraint(equalToConstant: 15),
            pasteIcon.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    /// Задаёт мета-подпись (приложение · дата) и полную подсказку. Пустая мета скрывает лейбл.
    func setMeta(_ text: String?, tooltip: String?) {
        metaLabel.stringValue = text ?? ""
        toolTip = tooltip
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(digit: Int?, text: String) {
        keycap.value = digit.map(String.init) ?? ""
        thumb.isHidden = true
        thumb.image = nil
        textLeadingToThumb.isActive = false
        textLeadingToKeycap.isActive = true
        textLabel.stringValue = text
        setAccessibilityLabel(text)
    }

    /// Настраивает строку под запись-картинку: миниатюра слева + подпись (тип · размеры).
    func configure(digit: Int?, image: NSImage?, subtitle: String) {
        keycap.value = digit.map(String.init) ?? ""
        thumb.image = image
        thumb.isHidden = false
        textLeadingToKeycap.isActive = false
        textLeadingToThumb.isActive = true
        textLabel.stringValue = subtitle
        setAccessibilityLabel(subtitle)
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
        // Выбор рисует общая пилюля — строка держит только hover-заливку и показ паста-глифа.
        let color = isHovered ? NSColor.secondaryLabelColor.withAlphaComponent(0.10) : .clear
        layer?.backgroundColor = color.cgColor
        let affordance = isSelected || isHovered
        pasteIcon.isHidden = !affordance
        // Мета и паста-глиф делят один слот справа: на hover/выборе показываем глиф, иначе — мету.
        metaLabel.isHidden = affordance || metaLabel.stringValue.isEmpty
    }
}


/// Одна точка-кружок инлайн-полосы заметок: цвет = точка, пустая приглушена, при фокусе (полоса
/// выбрана и на этой точке стоит курсор ←/→) — акцентное кольцо. Клик открывает точку.
private final class PaletteDotButton: NSView {
    var onClick: (() -> Void)?
    private let index: Int
    private var color: NSColor = .systemGray
    private var isEmptyNote = true
    /// Текущая (последняя открытая) точка — тонкое нейтральное кольцо, когда полоса не в фокусе.
    var isCurrent = false { didSet { needsDisplay = true } }
    var isFocused = false { didSet { needsDisplay = true } }

    init(index: Int) {
        self.index = index
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(color: NSColor, isEmpty: Bool) {
        self.color = color
        self.isEmptyNote = isEmpty
        setAccessibilityLabel(String(format: L("notes.dot"), index + 1))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 12
        let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        (isEmptyNote ? color.withAlphaComponent(0.4) : color).setFill()
        NSBezierPath(ovalIn: rect).fill()
        // Одно кольцо за раз: акцентное — курсор-фокус (полоса выбрана), иначе нейтральное —
        // пометка текущей точки.
        if isFocused {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        } else if isCurrent {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1
            NSColor.secondaryLabelColor.setStroke()
            ring.stroke()
        }
    }
}

/// Инлайн-полоса из семи точек-заметок в палитре. Клик по точке открывает её; ←/→ (когда полоса
/// выделена в списке) двигают курсор-фокус, ↩ открывает точку под фокусом. Цифры не расходуются —
/// они целиком у сниппетов.
private final class NotesStripView: NSView {
    var onOpen: ((Int) -> Void)?
    private var dots: [PaletteDotButton] = []
    private(set) var focusedIndex = 0
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<NotesStore.count {
            let dot = PaletteDotButton(index: index)
            dot.onClick = { [weak self] in self?.onOpen?(index) }
            dots.append(dot)
            stack.addArrangedSubview(dot)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(colors: [NSColor], emptyFlags: [Bool], focused: Int) {
        focusedIndex = max(0, min(NotesStore.count - 1, focused))
        for (index, dot) in dots.enumerated() {
            dot.configure(color: colors[safe: index] ?? .systemGray,
                          isEmpty: emptyFlags[safe: index] ?? true)
            dot.isCurrent = index == focusedIndex  // стартовый фокус = текущая точка
            dot.isFocused = selected && index == focusedIndex
        }
    }

    func setSelected(_ value: Bool) {
        selected = value
        refreshFocus()
    }

    /// ←/→ на выделенной полосе: двигаем курсор-фокус в пределах [0…count-1] (без заворота).
    func moveFocus(_ delta: Int) {
        focusedIndex = max(0, min(NotesStore.count - 1, focusedIndex + delta))
        refreshFocus()
    }

    private func refreshFocus() {
        for (index, dot) in dots.enumerated() { dot.isFocused = selected && index == focusedIndex }
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

    /// Карточка «Звук» просит развернуть экран уровней (модуль). Хозяин (AppDelegate) собирает
    /// `LevelsModule` из актуальных данных громкости и делает `enterModule` — панель остаётся открытой.
    var onOpenLevels: (() -> Void)?

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

    /// Данные инлайн-полосы заметок для панели: цвета семи точек, флаги пустоты, текущая точка
    /// (её курсор-фокус подсвечивается по умолчанию) и открытие точки по индексу.
    struct NotesStrip {
        let colors: [NSColor]
        /// Первая строка каждой точки — показывается в результатах поиска.
        let previews: [String]
        /// Полный текст каждой точки — по нему матчит поиск палитры.
        let contents: [String]
        let emptyFlags: [Bool]
        let activeIndex: Int
        let onOpen: (Int) -> Void
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
    /// Растёт на каждом `show()`. Отложенное закрытие по fade-out (см. `fadeOutAndClose`) сверяет
    /// поколение: если за время затухания панель открыли заново, «висящий» close() отменяется.
    private var showGeneration = 0
    /// Счётчик присвоенных сниппетам цифр 1–9.
    private var snippetDigitCounter = 0

    /// Опрос системной громкости, пока панель открыта: ряды слайдеров с их геттером уровня.
    private var pollSliders: [(row: SliderRowView, read: () -> Float?)] = []
    /// Обновление уровней в карточке «Звук» на каждом тике опроса (nil — карточки нет).
    private var pollCard: (() -> Void)?
    private var pollTimer: Timer?

    private let listView = CommandListView()
    private let searchField = PaletteSearchField()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
    /// Плывущая подложка выделения (magic-move) — живёт под `contentStack` в координатах списка.
    private let selectionPill = SelectionPill()

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
    /// Инлайн-полоса заметок (nil — не показывать секцию).
    private var lastNotes: NotesStrip?
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
        // Пилюля — под списком (её рисуем позади строк, поверх — контент).
        listView.addSubview(selectionPill, positioned: .below, relativeTo: contentStack)

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

        listView.onMove = { [weak self] delta in self?.moveVertical(delta) }
        listView.onRun = { [weak self] index in self?.runIndex(index) }
        listView.onDigit = { [weak self] digit in self?.runDigit(digit) }
        listView.onCommandKey = { [weak self] keyCode in self?.runCommandKey(keyCode) ?? false }
        listView.onClose = { [weak self] in self?.handleCancel() }
        listView.onHorizontal = { [weak self] delta in self?.moveHorizontal(delta) }
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
            fadeOutAndClose()
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
            moveVertical(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveVertical(-1); return true
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
    func show(commands: [ToolboxCommand], snippets: [Snippet], sliders: [VolumeSlider] = [],
              notes: NotesStrip? = nil) {
        finished = false
        showGeneration &+= 1
        lastCommands = commands
        lastSnippets = snippets
        lastSliders = sliders
        lastNotes = notes
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
        // Окно уже на экране и размечено — ставим пилюлю на стартовую позицию без анимации.
        updateSelection(animated: false)
        animateEntrance()
        startVolumePolling()
    }

    /// Вход: панель проявляется (fade) и «садится» — масштаб 0.96→1.0 пружиной от геометрического
    /// центра (матрицей, без завязки на anchorPoint слоя стекла). Читается как «прилетела и села».
    private func animateEntrance() {
        guard let window else { return }
        // Alpha — на окне; сброс безусловный (не за guard'ом слоя), чтобы переиспользуемая панель
        // после fade-out гарантированно снова проявлялась.
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        // Масштаб — по слою ВНУТРЕННЕГО контента, а не стекла: NSGlassEffectView/NSVisualEffectView
        // сами гоняют свой backing-слой под live-блюр и transform на нём игнорируют/дёргают.
        panelContent.layoutSubtreeIfNeeded()
        guard let layer = panelContent.layer else { return }
        let b = layer.bounds
        guard b.width > 0, b.height > 0 else { return }  // без валидных bounds центр ушёл бы в угол
        let cx = b.width / 2, cy = b.height / 2
        var from = CATransform3DIdentity
        from = CATransform3DTranslate(from, cx, cy, 0)
        from = CATransform3DScale(from, 0.96, 0.96, 1)
        from = CATransform3DTranslate(from, -cx, -cy, 0)
        let scale = CASpringAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: from)
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.stiffness = 900; scale.damping = 40; scale.mass = 1
        scale.duration = scale.settlingDuration
        layer.add(scale, forKey: "entrance")
    }

    /// Быстрый уход по Esc/клику-вне: гасим alpha и только потом закрываем. Только для чистого
    /// закрытия (без действия) — там задержка не мешает; активация с пастой/лончером закрывается
    /// мгновенно (см. `finish`), чтобы не терять отзывчивость.
    private func fadeOutAndClose() {
        guard let window else { return }
        // Панель переиспользуется: если за время затухания её открыли заново (`show()` увеличит
        // поколение), «висящий» close() отменяем — иначе схлопнем свежепоказанную панель.
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            guard let self, self.showGeneration == generation else { return }
            window?.close()
        })
    }

    /// Пока панель открыта — раз в ~0.3с читаем системную громкость и подтягиваем ползунки, чтобы
    /// подхватить изменения извне (клавиши, Системные настройки). `.common` — чтобы тикало и во
    /// время модального цикла трекинга ползунка (там `externalUpdate` сам себя пропустит по флагу).
    private func startVolumePolling() {
        stopVolumePolling()
        guard !pollSliders.isEmpty || pollCard != nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            for item in self.pollSliders {
                if let value = item.read() { item.row.externalUpdate(value) }
            }
            self.pollCard?()
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
        pollCard = nil
        snippetDigitCounter = 0

        let toggles = commands.filter { $0.id.section == .toggles }
        let actions = commands.filter { $0.id.section == .actions || $0.id.section == .launchers }

        // Зона «переключатели» — плитки по три в ряд: микрофон, карточка «Звук» (уровни) и keep-awake.
        // Громкость больше не занимает отдельную секцию из ползунков — она свёрнута в карточку «Звук»,
        // которая проваливает в отдельный экран уровней (см. `makeSoundCard` / `LevelsModule`).
        if !toggles.isEmpty {
            addHeader(L("panel.section.toggles"), trailing: nil)
            var tiles: [NSView] = []
            for command in toggles {
                tiles.append(makeTile(command))
                // Карточку «Звук» ставим сразу за микрофоном — уровни рядом с мьютом (см. дизайн).
                if command.id == .micToggle, !sliders.isEmpty { tiles.append(makeSoundCard(sliders: sliders)) }
            }
            // Звук есть, а микрофона в наборе нет — карточку в конец ряда.
            if !sliders.isEmpty, !toggles.contains(where: { $0.id == .micToggle }) {
                tiles.append(makeSoundCard(sliders: sliders))
            }
            var index = 0
            while index < tiles.count {
                addTileRow(Array(tiles[index..<min(index + 3, tiles.count)]))
                index += 3
            }
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

        // Зона «заметки» — инлайн-полоса из семи точек (в идиоме Tot). Одна выделяемая позиция:
        // ←/→ двигают курсор-фокус по точкам, ↩ открывает точку под фокусом, клик — конкретную.
        // Цифры не расходуются (они у сниппетов); буква N тоже открывает (последнюю точку).
        if let notes = lastNotes {
            addHeader(L("notes.window.title"), trailing: L("panel.notes.hint"))
            let strip = NotesStripView()
            strip.configure(colors: notes.colors, emptyFlags: notes.emptyFlags, focused: notes.activeIndex)
            strip.onOpen = { [weak self] index in self?.finish { self?.lastNotes?.onOpen(index) } }
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.heightAnchor.constraint(equalToConstant: 30).isActive = true
            contentStack.addArrangedSubview(strip)
            strip.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            entries.append(Entry(
                view: strip, badge: nil, digit: nil, commandKey: CommandID.notes.panelKeyCode,
                setSelected: { [weak strip] in strip?.setSelected($0) },
                run: { [weak self, weak strip] in
                    guard let strip else { return }
                    self?.finish { self?.lastNotes?.onOpen(strip.focusedIndex) }
                },
                adjust: { [weak strip] delta in strip?.moveFocus(delta) }))
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
        pollCard = nil
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

        // Заметки: матчим по всему тексту точки (лучший скор среди строк — как у приложений),
        // пустые пропускаем. Результат показывает превью с цветным кружком и открывает точку.
        if let notes = lastNotes {
            for index in notes.contents.indices where !(notes.emptyFlags[safe: index] ?? true) {
                let preview = notes.previews[safe: index] ?? ""
                // Матчим по строкам текста + имени/превью (имя точки участвует в поиске).
                var candidates = notes.contents[index].split(whereSeparator: \.isNewline).map(String.init)
                candidates.append(preview)
                guard let score = FuzzyMatch.bestScore(query: query, candidates: candidates) else { continue }
                let dot = Self.noteDotImage(notes.colors[safe: index] ?? .systemGray)
                ranked.append(Ranked(score: score) { [weak self] in
                    self?.addResultRow(symbol: "note.text", title: preview,
                                       trailing: L("panel.search.type.note"), image: dot,
                                       run: { self?.finish { self?.lastNotes?.onOpen(index) } })
                })
            }
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

    /// Карточка «Звук»: свёрнутые уровни (выход/вход) + буква быстрого выбора (A). Клик/буква
    /// проваливают в экран уровней (`onOpenLevels`). Направления различаем по символу спека
    /// (`speaker…` — выход, `mic…` — вход); карточку опрашиваем на каждом тике (`pollCard`).
    private func makeSoundCard(sliders: [VolumeSlider]) -> SoundCardView {
        let card = SoundCardView()
        let key = UInt16(kVK_ANSI_A)
        let badge = keyName(forKeyCode: UInt32(key))
        let output = sliders.first { $0.symbol.contains("speaker") }
        let input = sliders.first { $0.symbol.contains("mic") }
        card.configure(badge: badge, output: output?.value, input: input?.value)
        // Живой опрос: если у направления есть геттер — читаем систему, иначе держим стартовое.
        pollCard = { [weak card] in
            card?.updateLevels(output: output?.readValue?() ?? output?.value,
                               input: input?.readValue?() ?? input?.value)
        }
        card.onClick = { [weak self] in self?.openLevels() }
        entries.append(Entry(view: card, badge: badge, digit: nil, commandKey: key,
                             setSelected: { [weak card] in card?.isSelected = $0 },
                             run: { [weak self] in self?.openLevels() }))
        return card
    }

    /// Провалиться в экран уровней. Хозяин сам делает `enterModule` — панель остаётся открытой,
    /// поэтому здесь без `finish()` (в отличие от лончеров, закрывающих окно).
    private func openLevels() { onOpenLevels?() }

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
                      trailing: command.trailing(), tint: command.id.paletteTint)
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

    /// Кладёт произвольную вьюху в список на всю ширину (высоту вьюха задаёт сама). Для секций,
    /// где строки идут в один столбец (ползунки громкости, ячейки устройств над ними).
    private func addFullWidthRow(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
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

    /// Визуальная решётка индексов `entries`: строки по фактическому Y кадров, колонки по X.
    /// Записи с `adjust` (слайдеры/заметки — они держат ←/→ под уровень/курсор) выносятся каждая
    /// в отдельную строку: между ними ходят ↑/↓, а ←/→ остаются за их семантикой. Так навигация
    /// становится двумерной (↓ = строго вниз, а не «следующий по списку → сосед справа»).
    private func navGrid() -> [[Int]] {
        guard !entries.isEmpty else { return [] }
        listView.layoutSubtreeIfNeeded()
        let framed = entries.indices.map { i -> (idx: Int, frame: CGRect) in
            (i, entries[i].view.convert(entries[i].view.bounds, to: listView))
        }
        // Группируем по Y (допуск — половина высоты, чтобы одна визуальная строка не расщепилась).
        var rows: [[(idx: Int, frame: CGRect)]] = []
        for item in framed.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let ref = rows.last?.first,
               abs(ref.frame.midY - item.frame.midY) < max(ref.frame.height, item.frame.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        // Каждую строку — по X; строку со слайдерами/заметками дробим на одиночные (см. выше).
        var grid: [[Int]] = []
        for row in rows {
            let sorted = row.sorted { $0.frame.midX < $1.frame.midX }
            if sorted.contains(where: { entries[$0.idx].adjust != nil }) {
                sorted.forEach { grid.append([$0.idx]) }
            } else {
                grid.append(sorted.map { $0.idx })
            }
        }
        return grid
    }

    private func gridPosition(of index: Int, in grid: [[Int]]) -> (row: Int, col: Int)? {
        for (r, row) in grid.enumerated() {
            if let c = row.firstIndex(of: index) { return (r, c) }
        }
        return nil
    }

    private func select(_ index: Int) {
        selectedIndex = index
        updateSelection(animated: true)
        entries[selectedIndex].view.scrollToVisible(entries[selectedIndex].view.bounds)
    }

    /// ↑/↓ — на строку выше/ниже, удерживая колонку (обрезаем по ширине целевой строки). На краях
    /// заворачиваем, как и раньше.
    private func moveVertical(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let grid = navGrid()
        guard let (row, col) = gridPosition(of: selectedIndex, in: grid), !grid.isEmpty else { return }
        let targetRow = grid[(row + delta + grid.count) % grid.count]
        select(targetRow[min(col, targetRow.count - 1)])
    }

    /// ←/→ — сперва отдаём семантике записи (слайдер — уровень, сниппет — панель действий), иначе
    /// это переход между колонками сетки (плитки-тумблеры, строки действий).
    private func moveHorizontal(_ delta: Int) {
        guard entries.indices.contains(selectedIndex) else { return }
        let entry = entries[selectedIndex]
        if entry.adjust != nil || (delta > 0 && entry.secondary != nil) {
            horizontalOnSelection(delta); return
        }
        let grid = navGrid()
        guard let (row, col) = gridPosition(of: selectedIndex, in: grid) else { return }
        let targetCol = col + delta
        if grid[row].indices.contains(targetCol) { select(grid[row][targetCol]) }
    }

    /// `animated` — перезаезд пилюли пружиной (навигация стрелками); при пересборке списка/первом
    /// показе ставим её на место мгновенно.
    private func updateSelection(animated: Bool = false) {
        for (i, entry) in entries.enumerated() { entry.setSelected(i == selectedIndex) }
        positionPill(selectionPill, in: listView,
                     selected: entries[safe: selectedIndex]?.view, animated: animated)
    }

    private func runIndex(_ index: Int) {
        let target = index < 0 ? selectedIndex : index
        guard entries.indices.contains(target) else { NSSound.beep(); return }
        pressBounce(entries[target].view)
        entries[target].run()
    }

    /// Быстрый выбор цифрой 1–9: запускаем сниппет с этим номером (команды на буквах, история
    /// номеров не имеет).
    private func runDigit(_ digit: Int) {
        guard let entry = entries.first(where: { $0.digit == digit }) else { NSSound.beep(); return }
        pressBounce(entry.view)
        entry.run()
    }

    /// Быстрый выбор буквой команды по физическому keyCode. Возвращает true, если команда с таким
    /// кодом есть (тогда событие поглощено); иначе false — незанятая буква уходит в `super`.
    private func runCommandKey(_ keyCode: UInt16) -> Bool {
        guard let entry = entries.first(where: { $0.commandKey == keyCode }) else { return false }
        pressBounce(entry.view)
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

    /// Маленький залитый кружок в цвет точки — иконка заметки в результатах поиска (не template,
    /// поэтому не перекрашивается тинтом строки и остаётся цветным).
    private static func noteDotImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
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

/// Локаль по текущему языку приложения (`AppleLanguages` читается при старте) — чтобы
/// относительные даты («5 мин назад») совпадали с языком интерфейса, а не системным.
private let historyMetaLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

private let historyRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    f.locale = historyMetaLocale
    return f
}()

private let historyAbsoluteFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.locale = historyMetaLocale
    return f
}()

/// Компактная мета-подпись строки: «Приложение · 5 мин назад» (любая часть может отсутствовать).
/// Дата эпохи (запись без `createdAt`) в относительную часть не идёт — показываем только приложение.
func historyMetaLabel(_ entry: ClipboardEntry) -> String? {
    var parts: [String] = []
    if let app = entry.source?.appName, !app.isEmpty { parts.append(app) }
    if entry.createdAt.timeIntervalSince1970 > 0 {
        parts.append(historyRelativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Полная подсказка (tooltip): приложение + абсолютные дата и время.
func historyMetaTooltip(_ entry: ClipboardEntry) -> String? {
    var parts: [String] = []
    if let app = entry.source?.appName, !app.isEmpty { parts.append(app) }
    if entry.createdAt.timeIntervalSince1970 > 0 {
        parts.append(historyAbsoluteFormatter.string(from: entry.createdAt))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        /// Точечное удаление строки (напр. запись истории). nil — строку удалять нельзя (аудио).
        let onDelete: (() -> Void)?

        init(view: NSView, digit: Int?, enabled: Bool, setSelected: @escaping (Bool) -> Void,
             setOnClick: @escaping (@escaping () -> Void) -> Void, run: @escaping () -> Void,
             onDelete: (() -> Void)? = nil) {
            self.view = view; self.digit = digit; self.enabled = enabled
            self.setSelected = setSelected; self.setOnClick = setOnClick; self.run = run
            self.onDelete = onDelete
        }
    }

    // MARK: - Билдеры Item

    static func historyItems(_ history: [ClipboardEntry],
                             imageProvider: (ClipboardImageRef) -> Data?,
                             onPaste: @escaping (ClipboardEntry) -> Void,
                             onDelete: @escaping (ClipboardEntry) -> Void) -> [Item] {
        history.enumerated().map { index, entry in
            let digit = index < 9 ? index + 1 : nil
            let row = HistoryRowView()
            switch entry.content {
            case .text(let text):
                row.configure(digit: digit, text: historyPreview(text))
            case .image(let ref):
                let thumbnail = imageProvider(ref).flatMap { NSImage(data: $0) }
                row.configure(digit: digit, image: thumbnail,
                              subtitle: "\(L("clipboard.image")) · \(ref.pixelWidth)×\(ref.pixelHeight)")
            }
            // Мета справа: приложение-источник + относительная дата; полная дата — в подсказке.
            row.setMeta(historyMetaLabel(entry), tooltip: historyMetaTooltip(entry))
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            return Item(view: row, digit: digit, enabled: true,
                        setSelected: { [weak row] in row?.isSelected = $0 },
                        setOnClick: { [weak row] handler in row?.onClick = handler },
                        run: { onPaste(entry) },
                        onDelete: { onDelete(entry) })
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
    private let footerKey: String
    private let rowHeight: CGFloat
    private let maxContentHeight: CGFloat
    private var clearHandler: (() -> Void)?

    private var items: [Item] = []
    private var selectedIndex = 0
    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
    /// Плывущая подложка выделения (magic-move) — та же, что в корневой палитре.
    private let selectionPill = SelectionPill()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var clearButton: ClosureButton?
    private weak var host: PaletteHost?

    private var window: NSWindow? { contentView.window }

    init(titleKey: String, emptyKey: String? = nil, footerKey: String = "panel.footer",
         rowHeight: CGFloat = 40, maxContentHeight: CGFloat = 520) {
        self.titleKey = titleKey
        self.emptyKey = emptyKey
        self.footerKey = footerKey
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
        // Список размечен внутри палитры — ставим пилюлю на стартовую позицию без анимации.
        updateSelection(animated: false)
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
        listView.addSubview(selectionPill, positioned: .below, relativeTo: contentStack)

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

        let hint = NSTextField(labelWithString: L(footerKey))
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
        listView.onDelete = { [weak self] in self?.deleteSelected() }
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

    /// Удаляет текущую выделенную строку (если она удаляемая — у аудио `onDelete == nil`, тогда
    /// beep). Список перестраивается на месте, палитра не закрывается; при опустошении показываем
    /// «пусто» и прячем корзину. Высота изменилась — просим палитру пере-разметиться.
    private func deleteSelected() {
        guard items.indices.contains(selectedIndex), let onDelete = items[selectedIndex].onDelete else {
            NSSound.beep(); return
        }
        onDelete()
        items.remove(at: selectedIndex)
        rebuild()
        selectedIndex = items.isEmpty ? -1 : min(selectedIndex, items.count - 1)
        updateSelection(animated: false)
        emptyLabel.isHidden = !items.isEmpty
        clearButton?.isHidden = (clearHandler == nil || items.isEmpty)
        host?.setNeedsResize()
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        updateSelection(animated: true)
        items[selectedIndex].view.scrollToVisible(items[selectedIndex].view.bounds)
    }
    private func updateSelection(animated: Bool = false) {
        for (i, item) in items.enumerated() { item.setSelected(i == selectedIndex) }
        positionPill(selectionPill, in: listView,
                     selected: items[safe: selectedIndex]?.view, animated: animated)
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
        pressBounce(item.view)
        host?.closePalette()
        item.run()
    }
}

/// Экран управления уровнями — куда проваливает карточка «Звук». Держит ползунки выхода/входа с
/// выбором устройства (те же `SliderRowView`/`DeviceMenuButton`, что раньше жили секцией в корне) и
/// свою навигацию: ↑/↓ между ползунками, ←/→ меняют уровень, Esc — назад в корень. Пока экран на
/// виду — опрашивает системную громкость (таймер живёт по присутствию вьюхи в окне).
final class LevelsModule: NSObject, PaletteModule {
    typealias VolumeSlider = CommandPanelWindowController.VolumeSlider

    let titleKey = "audio.levels.title"

    private var specs: [VolumeSlider] = []
    private var sliderRows: [SliderRowView] = []
    private var readers: [() -> Float?] = []
    private var selectedIndex = 0
    private var pollTimer: Timer?

    private let listView = CommandListView()
    private let contentStack = NSStackView()
    private let scroll = NSScrollView()
    private let selectionPill = SelectionPill()
    private weak var host: PaletteHost?

    private var window: NSWindow? { contentView.window }

    /// Задаёт направления перед `enterModule` (форсит ленивую сборку вьюхи).
    func configure(sliders: [VolumeSlider]) {
        _ = contentView
        specs = sliders
        rebuild()
        selectedIndex = sliderRows.isEmpty ? -1 : 0
        updateSelection(animated: false)
    }

    // MARK: PaletteModule

    private(set) lazy var contentView: NSView = buildContent()

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        contentStack.layoutSubtreeIfNeeded()
        let inner = contentStack.fittingSize.height + 12
        // футер: зазор до подсказки (6) + подсказка (~14) + нижний отступ (10) + верхний отступ (6).
        let footer: CGFloat = 6 + 14 + 10 + 6
        return inner + footer
    }

    func moduleWillAppear(host: PaletteHost) {
        self.host = host
        window?.makeFirstResponder(listView)
        updateSelection(animated: false)
    }

    func handleCommandReturn() -> Bool { false }

    private func buildContent() -> NSView {
        let content = LevelsContentView()
        // Таймер опроса живёт только пока экран в окне (у модуля нет колбэка «исчез»).
        content.onWindowChange = { [weak self] visible in
            visible ? self?.startPolling() : self?.stopPolling()
        }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(contentStack)
        listView.addSubview(selectionPill, positioned: .below, relativeTo: contentStack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listView
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString: L("panel.levels.footer"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

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

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onHorizontal = { [weak self] delta in self?.nudgeSelected(delta) }
        listView.onClose = { [weak self] in self?.host?.dismissModule() }
        return content
    }

    private func rebuild() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sliderRows.removeAll()
        readers.removeAll()
        for spec in specs {
            if spec.device != nil {
                let cell = makeDeviceCell(spec.device)
                contentStack.addArrangedSubview(cell)
                cell.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
            let row = SliderRowView()
            row.configure(symbol: spec.symbol, value: spec.value, reflectsLevel: spec.reflectsLevel)
            row.onChange = spec.onChange
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            sliderRows.append(row)
            readers.append(spec.readValue ?? { nil })
        }
    }

    /// Строка выбора устройства над ползунком (та же выпадашка, что была в корневой секции).
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

    private func moveSelection(by delta: Int) {
        guard !sliderRows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + sliderRows.count) % sliderRows.count
        updateSelection(animated: true)
        sliderRows[selectedIndex].scrollToVisible(sliderRows[selectedIndex].bounds)
    }
    private func nudgeSelected(_ delta: Int) {
        sliderRows[safe: selectedIndex]?.nudge(delta)
    }
    private func updateSelection(animated: Bool) {
        for (i, row) in sliderRows.enumerated() { row.isSelected = (i == selectedIndex) }
        positionPill(selectionPill, in: listView, selected: sliderRows[safe: selectedIndex], animated: animated)
    }

    private func startPolling() {
        stopPolling()
        guard !readers.isEmpty else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (i, read) in self.readers.enumerated() {
                if let value = read() { self.sliderRows[safe: i]?.externalUpdate(value) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

/// Корневая вьюха экрана уровней: сообщает модулю о входе/уходе из окна, чтобы стартовать/глушить
/// опрос громкости (у модуля нет колбэка «исчез», а таймер должен жить только пока экран на виду).
private final class LevelsContentView: NSView {
    var onWindowChange: ((Bool) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
