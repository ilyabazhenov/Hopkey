import AppKit

/// Общие детали оформления окон Hopkey: единый источник цветов и брендовой марки, чтобы все
/// окна выглядели как одно приложение. Палитра выровнена на системный вид основной панели
/// команд (`controlAccentColor` + нейтрали) — без фирменного тёплого акцента; сами цвета
/// системные, поэтому адаптивность к теме/выбранному акценту даёт система.
enum Brand {

    // Раньше здесь жил фирменный янтарь. Всё выровнено на системный вид основной панели команд:
    // имена оставлены (на них завязаны вызовы во всех окнах), но цвета — системные
    // (`controlAccentColor` и нейтрали), чтобы окна выглядели как одно системное приложение.

    /// Основной акцент — системный (как выделение строки в панели команд).
    static let accent = NSColor.controlAccentColor

    /// Заливка бейджа быстрого выбора — нейтральный серый (как `NumberBadge` в панели).
    static let keycapFill = NSColor.secondaryLabelColor.withAlphaComponent(0.14)

    /// Заливка основной кнопки («Вставить»/«Открыть»/«Сохранить») — системный акцент.
    static let buttonFill = NSColor.controlAccentColor

    /// Контур бейджа больше не рисуем — плоский серый колпачок.
    static let keycapStroke = NSColor.clear

    /// Цифра/символ на бейдже — приглушённый серый.
    static let keycapText = NSColor.secondaryLabelColor

    /// Текст/иконка поверх акцентной кнопки — белый, как у системной кнопки по умолчанию.
    static let onAccentText = NSColor.white

    /// Акцент как ТЕКСТ на нейтральном фоне (выбранная вкладка настроек) — системный.
    static let accentForeground = NSColor.controlAccentColor

    /// Заливка выделенной строки списка — системный акцент (как в панели команд).
    static let selectionFill = NSColor.controlAccentColor.withAlphaComponent(0.20)

    /// Заливка строки под курсором (hover) — слабый нейтральный серый (как hover в панели).
    static let hoverFill = NSColor.secondaryLabelColor.withAlphaComponent(0.10)

    /// Нейтральная полупрозрачная подложка поверх системного стекла: гасит избыточную прозрачность
    /// (сквозь пустые поля просвечивал рабочий стол), сохраняя стеклянный характер. Не тёплая —
    /// системно-серая. Адаптивна: в светлой теме подсветляем, в тёмной затемняем.
    static let glassTint = NSColor(name: "HopkeyGlassBacking") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(white: 0.11, alpha: 0.42)
            : NSColor(white: 1.00, alpha: 0.42)
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

    /// Кладёт нейтральную подложку (`glassTint`) поверх стекла на всю площадь `backdrop` —
    /// гасит избыточную прозрачность. Оверлей не перехватывает события — перетаскивание за фон
    /// продолжает работать.
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
        makeHeader(title: title).view
    }

    /// Как `makeHeaderView`, но отдаёт и label — чтобы менять заголовок на лету (палитра меняет его
    /// под активный модуль).
    static func makeHeader(title: String) -> (view: NSView, label: NSTextField) {
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
        return (stack, label)
    }
}

/// Нейтральная подложка поверх стекла. Слой-бэкенд, цвет берёт из `Brand.glassTint` и
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

/// Бейдж номера быстрого выбора (1–9): скруглённый серый колпачок (как `NumberBadge` в панели
/// команд). Для строк за пределами девяти `value` пустой, и колпачок не рисуется (остаётся
/// пустое место под выравнивание).
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
