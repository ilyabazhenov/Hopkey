import AppKit
import HopkeyCore

/// Окно «Заметки»: семь постоянных цветных точек-черновиков в идиоме Tot. Плавающее стеклянное
/// окно поверх активного приложения; в отличие от пикера сниппетов (неактивирующая панель, фокус
/// не крадёт) здесь окно намеренно становится ключевым — это редактор, в него нужно печатать.
/// «Вставить» отдаёт текст назад в приложение, которое было активным до открытия окна (см.
/// `onPaste` → AppDelegate, тот же путь, что и вставка сниппета).
///
/// Переключение точек: клик по точке, ⌘1…⌘7 (цифры без модификатора заняты набором текста).
/// Автосохранение: правки кэшируются в `NotesStore` на каждое нажатие, на диск сбрасываются по
/// паузе в наборе, при переключении точки и закрытии окна.
final class NotesWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    /// «Вставить» содержимое (или выделение) текущей точки в целевое приложение.
    var onPaste: ((String) -> Void)?
    /// «Скопировать» содержимое (или выделение) текущей точки в буфер.
    var onCopy: ((String) -> Void)?

    private let store: NotesStore

    /// Цвета семи точек (в порядке индексов) — как спектр дотов Tot. Значения совпадают с макетом.
    static let dotColors: [NSColor] = [
        NSColor(srgbRed: 0.886, green: 0.294, blue: 0.290, alpha: 1),  // красный
        NSColor(srgbRed: 0.937, green: 0.624, blue: 0.153, alpha: 1),  // оранжевый
        NSColor(srgbRed: 0.388, green: 0.600, blue: 0.133, alpha: 1),  // зелёный
        NSColor(srgbRed: 0.114, green: 0.620, blue: 0.459, alpha: 1),  // бирюзовый
        NSColor(srgbRed: 0.216, green: 0.541, blue: 0.867, alpha: 1),  // синий
        NSColor(srgbRed: 0.498, green: 0.467, blue: 0.867, alpha: 1),  // фиолетовый
        NSColor(srgbRed: 0.831, green: 0.325, blue: 0.494, alpha: 1),  // розовый
    ]

    /// Активная точка (индекс 0…count-1). Сохраняется между запусками, чтобы окно открывалось там,
    /// где его закрыли.
    private var activeDot = 0
    private static let lastDotKey = "notes.lastActiveDot"

    /// Моноширинный шрифт редактора — заметки часто содержат токены/команды. Переустанавливаем
    /// после подмены `.string` (setter сбрасывает атрибуты к дефолтным).
    private let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let dotBar = NotesDotBar()
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    /// Успел ли центрироваться на первом показе (дальше положение окна не трогаем).
    private var didCenter = false
    /// Дебаунс сброса на диск: правки кэшируются сразу, файл переписываем по паузе в наборе.
    private var saveTimer: Timer?

    private static let width: CGFloat = 440
    private static let height: CGFloat = 320

    init(store: NotesStore) {
        self.store = store
        let panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false  // остаётся при переключении на целевое приложение (для вставки)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 240)
        super.init(window: panel)
        panel.delegate = self
        panel.onSelectDot = { [weak self] index in self?.selectDot(index) }
        panel.onClose = { [weak self] in self?.window?.close() }
        activeDot = Self.clampedLastDot()
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Последняя активная точка из прошлого сеанса (с обрезкой в валидный диапазон).
    private static func clampedLastDot() -> Int {
        let stored = UserDefaults.standard.integer(forKey: Self.lastDotKey)
        return max(0, min(NotesStore.count - 1, stored))
    }

    // MARK: - Сборка UI

    private func buildChrome() {
        guard let window else { return }
        let content = NSView()
        installGlass(in: window, content: content)

        let (header, _) = Brand.makeHeader(title: L("notes.window.title"))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        dotBar.translatesAutoresizingMaskIntoConstraints = false
        dotBar.onSelect = { [weak self] index in self?.selectDot(index) }
        content.addSubview(dotBar)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        // Текст точки — plain-редактор моноширинным (заметки часто содержат токены/команды).
        // Rich-текст выключен намеренно (Markdown-режим Tot оставлен на потом); подсветку
        // заголовков/разделителей рисуем display-only временными атрибутами (см. applyHighlighting).
        textView.isRichText = false
        textView.font = editorFont
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.delegate = self
        // Вертикальный рост под длинный текст: без большого maxSize вью зажимается стартовой
        // высотой и длинная заметка не прокручивается.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        content.addSubview(scroll)

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footerSeparator)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.isEditable = false; countLabel.isBordered = false; countLabel.drawsBackground = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: L("notes.copy"), target: self, action: #selector(copyNote))
        copyButton.bezelStyle = .rounded
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let pasteButton = NSButton(title: L("notes.paste"), target: self, action: #selector(pasteNote))
        pasteButton.bezelStyle = .rounded
        pasteButton.keyEquivalent = "\r"
        // Акцентная основная кнопка — единый вид главного действия со всеми окнами приложения.
        pasteButton.bezelColor = Brand.buttonFill
        pasteButton.attributedTitle = NSAttributedString(
            string: L("notes.paste"),
            attributes: [.foregroundColor: Brand.onAccentText,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        pasteButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [countLabel, NSView(), copyButton, pasteButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),

            dotBar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            dotBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dotBar.heightAnchor.constraint(equalToConstant: 24),

            separator.topAnchor.constraint(equalTo: dotBar.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -6),

            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footerSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        loadDot()  // наполнить активную точку до первого показа
    }

    // MARK: - Показ

    /// Открывает окно на последней активной точке, запомнив, чтобы «Вставить» вернул текст туда,
    /// откуда пришли (это делает AppDelegate, запоминая frontmost перед вызовом).
    func show() {
        guard let window else { return }
        loadDot()
        if !didCenter {
            window.center()
            didCenter = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        // Курсор в конец текста — сразу можно дописывать.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    // MARK: - Точки

    /// Переключает активную точку: сохраняет текущую на диск, грузит выбранную.
    private func selectDot(_ index: Int) {
        guard index >= 0, index < NotesStore.count, index != activeDot else { return }
        persistCurrent()
        activeDot = index
        UserDefaults.standard.set(index, forKey: Self.lastDotKey)
        loadDot()
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Наполняет редактор текстом активной точки и синхронизирует всё зависимое (бар точек,
    /// счётчик, подсветку).
    private func loadDot() {
        textView.string = store.text(at: activeDot)
        textView.font = editorFont  // setter `.string` сбрасывает шрифт к дефолту — возвращаем
        dotBar.configure(colors: Self.dotColors,
                         emptyFlags: (0..<NotesStore.count).map { store.isEmpty(at: $0) },
                         active: activeDot)
        applyHighlighting()
        updateCount()
    }

    /// Сбрасывает текущую точку на диск немедленно (переключение/закрытие). Кэш уже актуален —
    /// правки кладутся в него на каждое нажатие в `textDidChange`.
    private func persistCurrent() {
        store.update(textView.string, at: activeDot)
        store.persist(at: activeDot)
    }

    // MARK: - Редактирование

    func textDidChange(_ notification: Notification) {
        store.update(textView.string, at: activeDot)  // кэш — сразу
        updateCount()
        applyHighlighting()
        dotBar.setEmpty(store.isEmpty(at: activeDot), at: activeDot)  // «пустая» точка бледнеет живьём
        scheduleSave()  // на диск — по паузе
    }

    /// Переписывает файл активной точки через ~0.6с после последнего нажатия (частые правки не
    /// бьют по диску на каждую букву).
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.store.persist(at: self.activeDot)
        }
    }

    /// Обновляет счётчик слов/знаков под текущий текст.
    private func updateCount() {
        let text = textView.string
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = (text as NSString).length
        countLabel.stringValue = String(format: L("notes.count"), words, chars)
    }

    /// Лёгкая Markdown-подсветка (display-only, через временные атрибуты — не трогает сам текст и
    /// undo): строки-заголовки (`#…`) красим системным акцентом, строки-разделители (`---`/`***`/
    /// `___`) — приглушённо. Полный rich-режим Tot оставлен на будущее.
    private func applyHighlighting() {
        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        let nsText = storage.string as NSString
        nsText.enumerateSubstrings(in: full, options: .byLines) { substring, range, _, _ in
            guard let line = substring else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: NSColor.controlAccentColor], forCharacterRange: range)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: NSColor.tertiaryLabelColor], forCharacterRange: range)
            }
        }
    }

    // MARK: - Действия

    /// Текст для вставки/копирования: выделение, если оно непустое, иначе вся точка целиком.
    private func selectedOrAllText() -> String {
        let selected = textView.selectedRange()
        if selected.length > 0 {
            return (textView.string as NSString).substring(with: selected)
        }
        return textView.string
    }

    @objc private func pasteNote() {
        let text = selectedOrAllText()
        guard !text.isEmpty else { NSSound.beep(); return }
        persistCurrent()
        onPaste?(text)
    }

    @objc private func copyNote() {
        let text = selectedOrAllText()
        guard !text.isEmpty else { NSSound.beep(); return }
        onCopy?(text)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        saveTimer?.invalidate()
        saveTimer = nil
        persistCurrent()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Уход фокуса (в т.ч. переключение на целевое приложение при вставке) — фиксируем на диск.
        persistCurrent()
    }
}

/// Плавающая панель заметок: становится ключевой (в неё печатают), перехватывает ⌘1…⌘7 для
/// переключения точек и Esc для закрытия.
private final class NotesPanel: NSPanel {
    var onSelectDot: ((Int) -> Void)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let onlyCommand = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask) == .command
        // ⌘1…⌘7 — переключить точку (по символу: цифры не зависят от раскладки).
        if onlyCommand, let chars = event.charactersIgnoringModifiers, let digit = Int(chars),
           digit >= 1, digit <= NotesStore.count {
            onSelectDot?(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Ряд из семи цветных точек-табов. Клик выбирает точку; активная обведена кольцом, «пустые»
/// (без текста) — приглушены, чтобы сразу видеть, куда можно писать.
private final class NotesDotBar: NSView {
    var onSelect: ((Int) -> Void)?
    private var dots: [NotesDotButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<NotesStore.count {
            let dot = NotesDotButton(index: index)
            dot.onClick = { [weak self] in self?.onSelect?(index) }
            dots.append(dot)
            stack.addArrangedSubview(dot)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Полная перенастройка: цвета, флаги пустоты, активная точка.
    func configure(colors: [NSColor], emptyFlags: [Bool], active: Int) {
        for (index, dot) in dots.enumerated() {
            dot.color = colors[safe: index] ?? .systemGray
            dot.isEmptyNote = emptyFlags[safe: index] ?? true
            dot.isActive = (index == active)
        }
    }

    /// Живое обновление «пустоты» одной точки (при наборе текста).
    func setEmpty(_ isEmpty: Bool, at index: Int) {
        dots[safe: index]?.isEmptyNote = isEmpty
    }
}

/// Одна точка-таб: залитый кружок; активная — с кольцом, пустая — приглушённая.
private final class NotesDotButton: NSView {
    var onClick: (() -> Void)?
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    var isEmptyNote = true { didSet { needsDisplay = true } }

    private let index: Int

    init(index: Int) {
        self.index = index
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(format: L("notes.dot"), index + 1))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = isActive ? 15 : 14
        let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        // Пустая неактивная точка — приглушена (сразу видно свободные слоты).
        let fill = (isEmptyNote && !isActive) ? color.withAlphaComponent(0.4) : color
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
        // Активная — кольцо в цвет точки вокруг кружка.
        if isActive {
            let ringRect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
