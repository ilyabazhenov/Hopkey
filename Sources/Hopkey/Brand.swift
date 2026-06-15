import AppKit

/// Фирменная палитра и мелкие брендовые элементы Hopkey. Один источник правды для
/// «янтарного» акцента (как кейкап на иконке) и общих деталей оформления окон, чтобы
/// окно ввода и пикер сниппетов выглядели как одно приложение, а не как системные диалоги.
///
/// Все цвета — адаптивные (`NSColor(name:dynamicProvider:)`): стекло окон следует системной
/// теме, поэтому фиксированный цвет в тёмной теме выжигал бы глаза. В тёмной берём чуть
/// светлее/мягче янтарь, в светлой — насыщенный, как колпачок клавиши на иконке.
enum Brand {

    /// Основной акцент — янтарь логотипа. Заменяет системный синий на выделении строки,
    /// кнопке «Открыть» и брендовых деталях.
    static let accent = NSColor(name: "HopkeyAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.00, green: 0.78, blue: 0.32, alpha: 1)   // мягче в тёмной теме
            : NSColor(srgbRed: 0.96, green: 0.66, blue: 0.13, alpha: 1)   // насыщенный янтарь
    }

    /// Заливка колпачка клавиши (бейдж быстрого выбора) — тот же янтарь, что и акцент.
    static let keycapFill = accent

    /// Заливка кнопки «Открыть». Глубже и спокойнее яркого `accent`: на большой площади
    /// сочный янтарь кейкапов «кричит», а у крупной кнопки приятнее приглушённый мёд.
    static let buttonFill = NSColor(name: "HopkeyButton") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.86, green: 0.63, blue: 0.26, alpha: 1)
            : NSColor(srgbRed: 0.83, green: 0.58, blue: 0.15, alpha: 1)
    }

    /// Контур колпачка: чуть темнее заливки, придаёт «кейкапу» объём без тяжёлой тени.
    static let keycapStroke = NSColor(name: "HopkeyKeycapStroke") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.80, green: 0.55, blue: 0.10, alpha: 0.9)
            : NSColor(srgbRed: 0.74, green: 0.48, blue: 0.06, alpha: 0.9)
    }

    /// Цифра на колпачке — тёмно-коричневая в обеих темах: заливка светлый янтарь и там, и
    /// там, поэтому тёмный текст читается одинаково.
    static let keycapText = NSColor(srgbRed: 0.32, green: 0.21, blue: 0.02, alpha: 1)

    /// Текст/иконка поверх янтарной кнопки «Открыть». Адаптивный: в светлой теме тёмно-
    /// коричневый (контраст на янтаре), в тёмной — тёплый белый. Так читается и на янтаре,
    /// когда кнопка активна, и на тёмно-сером фоне, когда окно неактивно (иначе коричневый
    /// текст сливается с тёмным фоном неактивной кнопки).
    static let onAccentText = NSColor(name: "HopkeyOnAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.0, green: 0.96, blue: 0.88, alpha: 1)   // тёплый белый
            : NSColor(srgbRed: 0.32, green: 0.21, blue: 0.02, alpha: 1)  // тёмно-коричневый
    }

    /// Янтарь как ТЕКСТ/иконка на нейтральном фоне окна (выбранная вкладка настроек). Глубже
    /// яркого `accent`: тот хорош заливкой, но светлым текстом на белом фоне читается плохо.
    /// Адаптивный: в светлой теме тёмное золото для контраста, в тёмной — яркий янтарь.
    static let accentForeground = NSColor(name: "HopkeyAccentText") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.0, green: 0.80, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.49, blue: 0.06, alpha: 1)
    }

    /// Заливка выделенной строки в пикере. НЕ `accent.withAlpha`: над тёмным стеклом слабый
    /// янтарь даёт грязно-коричневый, поэтому в тёмной теме берём ярче и плотнее.
    static let selectionFill = NSColor(name: "HopkeySelection") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.0, green: 0.80, blue: 0.36, alpha: 0.42)
            : NSColor(srgbRed: 0.96, green: 0.66, blue: 0.13, alpha: 0.28)
    }

    /// Заливка строки под курсором (hover) — слабее выделения, та же логика по темам.
    static let hoverFill = NSColor(name: "HopkeyHover") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.0, green: 0.80, blue: 0.36, alpha: 0.18)
            : NSColor(srgbRed: 0.96, green: 0.66, blue: 0.13, alpha: 0.12)
    }

    /// Тёплый кремовый оттенок поверх системного стекла — чтобы фон окна перестал быть
    /// нейтрально-серым и потеплел под цвет иконки. Очень слабый: стекло остаётся стеклом,
    /// а не превращается в плашку. В тёмной теме греем чуть иначе, чтобы не осветлять фон.
    static let glassTint = NSColor(name: "HopkeyGlassTint") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.62, green: 0.46, blue: 0.18, alpha: 0.10)
            : NSColor(srgbRed: 0.96, green: 0.84, blue: 0.55, alpha: 0.12)
    }

    /// Брендовая марка для окон — монохромный силуэт из менюбар-иконки (`MenuBarIcon`). Она
    /// шаблонная (прозрачный фон + перекраска под тему), поэтому в отличие от `AppIcon.icns`
    /// не тащит зашитый кремовый квадрат, который в тёмной теме выглядел инородным «кафелем».
    /// Бонус: марка в окне совпадает со значком в строке меню — единый знак.
    static var markImage: NSImage? {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }

    /// Кладёт тёплый кремовый оверлей (`glassTint`) поверх стекла на всю площадь `backdrop`.
    /// Оверлей не перехватывает события — перетаскивание окна за фон продолжает работать.
    static func addGlassTint(to backdrop: NSView) {
        let overlay = BrandTintOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(overlay, positioned: .below, relativeTo: nil)  // под контентом
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: backdrop.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
    }

    /// Брендовый заголовок окна: иконка + название одной строкой по центру полосы заголовка.
    /// Ставим вместо системного `title` (его прячем через `titleVisibility = .hidden`), чтобы
    /// окно читалось как Hopkey, а не как безымянная системная панель.
    static func makeHeaderView(title: String) -> NSView {
        let icon = NSImageView(image: markImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor  // шаблонная марка под цвет заголовка (адаптивна)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// Тёплый кремовый оверлей поверх стекла. Слой-бэкенд, цвет берёт из `Brand.glassTint` и
/// обновляет при смене темы (`updateLayer`). `hitTest` → nil: оверлей прозрачен для мыши,
/// чтобы не ломать перетаскивание окна за фон и клики по списку под ним.
final class BrandTintOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Brand.glassTint.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Брендовый бейдж-«кейкап» для номера быстрого выбора (1–9): скруглённый янтарный колпачок
/// клавиши — прямая отсылка к иконке приложения. Для строк за пределами девяти `value` пустой,
/// и колпачок не рисуется (остаётся пустое место под выравнивание).
final class KeycapBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    /// Цифра на колпачке; пусто — колпачок скрыт.
    var value: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        label.textColor = Brand.keycapText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func draw(_ dirtyRect: NSRect) {
        guard !value.isEmpty else { return }  // нет номера — нет колпачка
        // Почти квадратный колпачок по центру строки, чуть скруглённый — как клавиша на иконке.
        let side = min(bounds.width, bounds.height, 20)
        let rect = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side, height: side
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        Brand.keycapFill.setFill()
        path.fill()
        Brand.keycapStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
