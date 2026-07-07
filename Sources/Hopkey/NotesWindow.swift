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
final class NotesWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                   NSTextFieldDelegate {

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

    /// Стартовый шрифт редактора (моно) — highlighter переопределяет под режим точки.
    private let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let dotBar = NotesDotBar()
    private let textView = PlaceholderTextView()
    private let scroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    /// Имя активной точки (необязательное).
    private let nameField = NSTextField()
    /// Тумблер «Формат» (Markdown-рендер) активной точки.
    private let formatToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Подсветка/рендер Markdown — как делегат textStorage (перекрашивает по правкам, без мусора
    /// в undo). Режим (plain/rich) переключается на точку.
    private let highlighter = MarkdownHighlighter()
    /// Успел ли центрироваться на первом показе (дальше положение окна не трогаем).
    private var didCenter = false
    /// Дебаунс сброса на диск: правки кэшируются сразу, файл переписываем по паузе в наборе.
    private var saveTimer: Timer?
    /// Идёт авто-перенумерация нумерованного списка — гасит рекурсию через `textDidChange`.
    private var isRenumbering = false

    // Размер сопоставим с палитрой команд (та ~470 шириной) — заметки это рабочая поверхность,
    // а не крохотный попап. Пользовательский ресайз запоминается (frameAutosaveName ниже).
    private static let width: CGFloat = 500
    private static let height: CGFloat = 540
    private static let frameAutosaveName = "HopkeyNotesWindow"

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
        panel.minSize = NSSize(width: 400, height: 320)
        panel.setFrameAutosaveName(Self.frameAutosaveName)  // запоминаем пользовательский размер/позицию
        super.init(window: panel)
        panel.delegate = self
        panel.onSelectDot = { [weak self] index in self?.selectDot(index) }
        panel.onClose = { [weak self] in self?.window?.close() }
        panel.onWrap = { [weak self] marker in self?.wrapSelection(with: marker) }
        activeDot = Self.clampedLastDot()
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Последняя активная точка из прошлого сеанса (с обрезкой в валидный диапазон). Публично —
    /// чтобы инлайн-полоса точек в палитре знала, какую точку подсветить как текущую.
    static var lastActiveDot: Int { clampedLastDot() }

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

        // Тулбар точки: имя (необязательное) + тумблер «Формат» + очистка.
        nameField.placeholderString = L("notes.name.placeholder")
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.lineBreakMode = .byTruncatingTail
        nameField.usesSingleLineMode = true
        nameField.delegate = self
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        formatToggle.title = L("notes.format")
        formatToggle.target = self
        formatToggle.action = #selector(toggleFormat)
        formatToggle.toolTip = L("notes.format.tooltip")
        formatToggle.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(image: NSImage(systemSymbolName: "trash",
                                                  accessibilityDescription: L("notes.clear")) ?? NSImage(),
                                   target: self, action: #selector(clearDot))
        clearButton.isBordered = false
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = L("notes.clear")
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [nameField, formatToggle, clearButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        // Текст точки. Хранится всегда как plain-Markdown (мы сохраняем `.string`); отображение
        // задаёт highlighter — делегат textStorage: в plain-режиме моноширинный однородно, в
        // rich-режиме рендерит Markdown (заголовки/жирный/курсив/код/списки). isRichText=true, чтобы
        // реальные атрибуты (жирный шрифт и пр.) отображались; наружу всё равно уходит `.string`.
        textView.isRichText = true
        textView.textStorage?.delegate = highlighter
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
        textView.placeholder = L("notes.placeholder")
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
        // ⌘↩, а не голый Return: Return в редакторе должен вставлять перенос строки, а не «применять».
        pasteButton.keyEquivalent = "\r"
        pasteButton.keyEquivalentModifierMask = .command
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

        // Подсказка хоткеев внизу — как в палитре (приглушённо, по центру).
        let hint = NSTextField(labelWithString: L("notes.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),

            dotBar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            dotBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dotBar.heightAnchor.constraint(equalToConstant: 24),

            toolbar.topAnchor.constraint(equalTo: dotBar.bottomAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
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
            footer.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
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
            // Разово восстанавливаем сохранённый размер/позицию (если есть).
            _ = window.setFrameUsingName(Self.frameAutosaveName)
            didCenter = true
        }
        moveToActiveScreenIfNeeded()  // открыть там, где работаешь (экран под курсором), а не на main
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        // Курсор в конец текста — сразу можно дописывать.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Экран, где сейчас работает пользователь — под курсором мыши (как у палитры), иначе main.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Если окно не на активном экране — центрирует его там (размер сохраняем). Если уже на нём —
    /// не трогаем позицию, чтобы уважать ручное перемещение пользователя.
    private func moveToActiveScreenIfNeeded() {
        guard let window, let screen = activeScreen(), window.screen !== screen else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    /// Открывает окно сразу на указанной точке (вызов из инлайн-полосы палитры). Если окно уже
    /// открыто на другой точке — сохраняем её перед переключением.
    func show(dot index: Int) {
        let clamped = max(0, min(NotesStore.count - 1, index))
        if window?.isVisible == true, clamped != activeDot {
            persistCurrent()
        }
        activeDot = clamped
        UserDefaults.standard.set(clamped, forKey: Self.lastDotKey)
        show()
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
        highlighter.formatted = store.isFormatted(at: activeDot)  // режим — до подмены текста
        formatToggle.state = highlighter.formatted ? .on : .off
        nameField.stringValue = store.name(at: activeDot)
        textView.font = editorFont
        textView.string = store.text(at: activeDot)  // подмена текста триггерит highlighter
        highlighter.revealParagraph = paragraphOfCaret()  // раскрыть маркеры строки под курсором
        if let storage = textView.textStorage { highlighter.rehighlight(storage) }  // на случай, если делегат не сработал
        dotBar.configure(colors: Self.dotColors,
                         emptyFlags: (0..<NotesStore.count).map { store.isEmpty(at: $0) },
                         active: activeDot)
        updateCount()
        textView.needsDisplay = true  // обновить плейсхолдер под новую (возможно пустую) точку
    }

    /// Сбрасывает текущую точку на диск немедленно (переключение/закрытие). Кэш уже актуален —
    /// правки кладутся в него на каждое нажатие в `textDidChange`.
    private func persistCurrent() {
        store.update(textView.string, at: activeDot)
        store.persist(at: activeDot)
    }

    // MARK: - Редактирование

    func textDidChange(_ notification: Notification) {
        renumberOrderedListsIfNeeded()  // может переписать номера пунктов (удаление/вставка)
        store.update(textView.string, at: activeDot)  // кэш — сразу (highlighter красит через делегат)
        updateCount()
        dotBar.setEmpty(store.isEmpty(at: activeDot), at: activeDot)  // «пустая» точка бледнеет живьём
        if textView.string.isEmpty { textView.needsDisplay = true }  // вернуть плейсхолдер при полном стирании
        scheduleSave()  // на диск — по паузе
    }

    /// Правка имени точки (поле имени) — сохраняем сразу (meta мал, дебаунс не нужен).
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === nameField else { return }
        store.setName(nameField.stringValue, at: activeDot)
    }

    /// Абзац, в котором стоит курсор (для раскрытия его маркеров в rich-режиме).
    private func paragraphOfCaret() -> NSRange {
        (textView.string as NSString).paragraphRange(for: textView.selectedRange())
    }

    /// Разбор нумерованной строки: отступ, номер, текст пункта. nil — не «N. …».
    private func orderedInfo(_ line: String) -> (indent: String, number: Int, content: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.first == ".", after.dropFirst().first == " " else { return nil }
        return (String(indent), number, String(after.dropFirst(2)))
    }

    /// Перенумеровывает смежные блоки нумерованного списка последовательно от номера первого пункта
    /// (удалил/вставил пункт — остальные подстроились). Блок — идущие подряд строки «N. …» с
    /// одинаковым отступом. Правит текст одним undo-шагом, курсор сохраняем. Только в rich-режиме.
    private func renumberOrderedListsIfNeeded() {
        guard highlighter.formatted, !isRenumbering else { return }
        var lines = textView.string.components(separatedBy: "\n")
        var changed = false
        var i = 0
        while i < lines.count {
            guard let head = orderedInfo(lines[i]) else { i += 1; continue }
            var offset = 0
            while i + offset < lines.count,
                  let item = orderedInfo(lines[i + offset]), item.indent == head.indent {
                let desired = head.number + offset
                if item.number != desired {
                    lines[i + offset] = "\(item.indent)\(desired). \(item.content)"
                    changed = true
                }
                offset += 1
            }
            i += offset
        }
        guard changed else { return }

        let newText = lines.joined(separator: "\n")
        let caret = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        isRenumbering = true
        if textView.shouldChangeText(in: fullRange, replacementString: newText) {
            textView.replaceCharacters(in: fullRange, with: newText)
            textView.didChangeText()
        }
        isRenumbering = false
        let newLength = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret.location, newLength), length: 0))
    }

    /// Смена выделения — в rich-режиме раскрываем маркеры строки только под ОДИНОЧНЫМ курсором
    /// (пустое выделение). При выделении диапазона/⌘A маркеры остаются спрятанными: тогда текст
    /// читают/копируют, а не правят конкретную строку.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard highlighter.formatted, let storage = textView.textStorage else { return }
        let reveal = textView.selectedRange().length == 0
            ? paragraphOfCaret()
            : NSRange(location: NSNotFound, length: 0)
        guard !NSEqualRanges(reveal, highlighter.revealParagraph) else { return }
        highlighter.revealParagraph = reveal
        highlighter.rehighlight(storage)
    }

    /// Умный буллет: в rich-режиме `-`/`*`/`+` + пробел в начале строки превращаем в `• `.
    func textView(_ view: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                  replacementString: String?) -> Bool {
        guard highlighter.formatted, replacementString == " ", affectedRange.length == 0,
              affectedRange.location > 0 else { return true }
        let ns = view.string as NSString
        let markerLoc = affectedRange.location - 1
        let marker = ns.substring(with: NSRange(location: markerLoc, length: 1))
        guard ["-", "*", "+"].contains(marker) else { return true }
        let lineRange = ns.lineRange(for: NSRange(location: affectedRange.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: markerLoc - lineRange.location))
        guard before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return true }
        let replaceRange = NSRange(location: markerLoc, length: 1)
        if view.shouldChangeText(in: replaceRange, replacementString: "• ") {
            view.replaceCharacters(in: replaceRange, with: "• ")  // "•" + пробел вместо "-" + вводимого пробела
            view.didChangeText()
        }
        return false
    }

    /// Умные буллеты по Enter: продолжить список маркером следующего пункта; на пустом пункте —
    /// завершить (убрать маркер). Только в rich-режиме.
    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard highlighter.formatted else { return false }

        // Перескок курсора через скрытые (нулевой ширины) маркеры — чтобы одним нажатием стрелки
        // не «застревать» в невидимом `**`/`#`.
        let caret = view.selectedRange()
        if caret.length == 0, selector == #selector(NSResponder.moveRight(_:)),
           let end = highlighter.hiddenRunEnd(rightOf: caret.location) {
            view.setSelectedRange(NSRange(location: end, length: 0)); return true
        }
        if caret.length == 0, caret.location > 0, selector == #selector(NSResponder.moveLeft(_:)),
           let start = highlighter.hiddenRunStart(leftOf: caret.location - 1) {
            view.setSelectedRange(NSRange(location: start, length: 0)); return true
        }

        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = view.string as NSString
        let lineRange = ns.lineRange(for: view.selectedRange())
        guard let item = NotesListItem.parse(ns.substring(with: lineRange)) else { return false }
        if item.contentEmpty {
            let prefixRange = NSRange(location: lineRange.location, length: item.prefixLength)
            if view.shouldChangeText(in: prefixRange, replacementString: "") {
                view.replaceCharacters(in: prefixRange, with: "")
                view.didChangeText()
            }
        } else {
            let insert = "\n" + item.nextMarker
            let range = view.selectedRange()
            if view.shouldChangeText(in: range, replacementString: insert) {
                view.replaceCharacters(in: range, with: insert)
                view.didChangeText()
            }
        }
        return true
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

    /// Обновляет счётчик слов/знаков под текущий текст (с плюрализацией под язык интерфейса).
    private func updateCount() {
        let text = textView.string
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = (text as NSString).length
        countLabel.stringValue =
            "\(words) \(Self.plural(words, "notes.count.words")) · \(chars) \(Self.plural(chars, "notes.count.chars"))"
    }

    /// Выбирает форму слова под число и язык интерфейса. Формы берём из локализации (три через `|`:
    /// одна/несколько/много), правило — русское для ru, простое one/other для остальных.
    private static func plural(_ n: Int, _ formsKey: String) -> String {
        let forms = L(formsKey).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard forms.count == 3 else { return forms.first ?? "" }
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let index: Int
        if lang.hasPrefix("ru") {
            let mod100 = n % 100, mod10 = n % 10
            if (11...14).contains(mod100) { index = 2 }
            else if mod10 == 1 { index = 0 }
            else if (2...4).contains(mod10) { index = 1 }
            else { index = 2 }
        } else {
            index = (n == 1) ? 0 : 2
        }
        return forms[index]
    }

    // MARK: - Формат / очистка / Markdown-обёртки

    /// Переключает режим отображения активной точки (plain ↔ Markdown-рендер), сохраняет и
    /// перекрашивает текущий текст.
    @objc private func toggleFormat() {
        let formatted = formatToggle.state == .on
        store.setFormatted(formatted, at: activeDot)
        highlighter.formatted = formatted
        highlighter.revealParagraph = paragraphOfCaret()
        if let storage = textView.textStorage { highlighter.rehighlight(storage) }
        window?.makeFirstResponder(textView)
    }

    /// Очищает активную точку (текст + имя + режим) после подтверждения.
    @objc private func clearDot() {
        guard !store.isEmpty(at: activeDot) || !store.name(at: activeDot).isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L("notes.clear.confirm.title")
        alert.informativeText = L("notes.clear.confirm.body")
        alert.addButton(withTitle: L("notes.clear"))
        alert.addButton(withTitle: L("common.cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.store.clear(at: self.activeDot)
            self.loadDot()
            self.window?.makeFirstResponder(self.textView)
        }
    }

    /// ⌘B/⌘I: оборачивает выделение (или ставит пару маркеров у курсора) в Markdown-маркер.
    /// Работает в любом режиме — это просто вставка Markdown; undo штатный.
    func wrapSelection(with marker: String) {
        // Только когда правится сам текст точки (а не поле имени) — иначе ⌘B из имени залезет в текст.
        guard textView.window?.firstResponder === textView else { return }
        let range = textView.selectedRange()
        let ns = textView.string as NSString
        let selected = ns.substring(with: range)
        let replacement = marker + selected + marker
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        // Пустое выделение — курсор между маркерами; иначе выделяем обёрнутое.
        if selected.isEmpty {
            textView.setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
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
    /// ⌘B/⌘I — обернуть выделение Markdown-маркером (`**`/`*`).
    var onWrap: ((String) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let onlyCommand = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask) == .command
        if onlyCommand, let chars = event.charactersIgnoringModifiers {
            // ⌘1…⌘7 — переключить точку (по символу: цифры не зависят от раскладки).
            if let digit = Int(chars), digit >= 1, digit <= NotesStore.count {
                onSelectDot?(digit - 1)
                return true
            }
            // ⌘B/⌘I — обернуть выделение в жирный/курсив Markdown.
            if chars == "b" { onWrap?("**"); return true }
            if chars == "i" { onWrap?("*"); return true }
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

/// `NSTextView` с плейсхолдером: у пустой точки рисуем приглушённую подсказку («начните печатать»)
/// на месте будущего текста, тем же шрифтом. Пропадает, как только появляется текст.
private final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                         withAttributes: attrs)
    }
}

/// Рендер Markdown как делегат `NSTextStorage`: перекрашивает текст по каждой правке (в
/// `didProcessEditing`, поэтому не мусорит в undo). `formatted=false` — однородный моноширинный
/// (исходник); `formatted=true` — Markdown-вид: заголовки/жирный/курсив/код/разделители.
///
/// В rich-режиме сами маркеры (`**`, `*`, `` ` ``, `#·`) ПРЯЧУТСЯ (нулевой шрифт + прозрачный цвет —
/// display-only, текст на диске остаётся plain-Markdown), КРОМЕ абзаца под курсором (`revealParagraph`):
/// там маркеры видны, чтобы их можно было править (идиома Bear/Obsidian).
private final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    var formatted = false
    /// Абзац под курсором — в нём маркеры не прячем (можно править). Задаёт контроллер по смене
    /// выделения; `NSNotFound` — не раскрывать ничего.
    var revealParagraph = NSRange(location: NSNotFound, length: 0)
    /// Диапазоны спрятанных (нулевой ширины) маркеров текущего рендера — чтобы контроллер перескакивал
    /// через них стрелками.
    private(set) var hiddenRanges: [NSRange] = []
    private var isHighlighting = false

    private let bodyFont = NSFont.systemFont(ofSize: 14)
    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private lazy var boldBody = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
    private lazy var italicBody = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    /// «Прячущие» атрибуты: почти нулевой шрифт (схлопывает ширину глифов) + прозрачный цвет.
    private let hiddenAttrs: [NSAttributedString.Key: Any] =
        [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]

    // `**жирный**`, `*курсив*` (не задевая `**`), `` `код` `` — группа 1 = содержимое без маркеров.
    private static let boldRE = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let italicRE = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)([^*\\n]+?)\\*(?!\\*)")
    private static let codeRE = try? NSRegularExpression(pattern: "`([^`\\n]+)`")

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isHighlighting else { return }
        highlight(textStorage)
    }

    /// Полная перекраска без правки текста (переключение режима / смена абзаца-раскрытия).
    func rehighlight(_ textStorage: NSTextStorage) { highlight(textStorage) }

    private func highlight(_ ts: NSTextStorage) {
        isHighlighting = true
        defer { isHighlighting = false }
        hiddenRanges.removeAll()
        let full = NSRange(location: 0, length: ts.length)
        // База: моно (исходник) либо пропорциональный (rich). Меняем только атрибуты.
        ts.setAttributes([.font: formatted ? bodyFont : monoFont,
                          .foregroundColor: NSColor.labelColor], range: full)
        guard formatted, full.length > 0 else { return }

        // Строчные конструкции: заголовки (жирнее/крупнее, `#·` прячем), разделители (приглушённо).
        let text = ts.string as NSString
        text.enumerateSubstrings(in: full, options: .byLines) { line, lineRange, _, _ in
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let level = Self.headingLevel(trimmed) {
                let size: CGFloat = level == 1 ? 19 : (level == 2 ? 16 : 14)
                ts.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: lineRange)
                // Прячем префикс «#…· » (решётки + пробелы до текста), если после него есть контент.
                let leading = line.prefix { $0 == " " }.count
                let prefixLen = leading + level + 1
                if line.count > prefixLen {
                    self.hide(NSRange(location: lineRange.location, length: prefixLen), in: ts)
                }
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
            } else if Self.isListLine(line) {
                // Висячий отступ: перенос строки пункта выравнивается под текст, а не под буллет.
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = 0
                style.headIndent = 18
                ts.addAttribute(.paragraphStyle, value: style, range: lineRange)
            }
        }

        // Инлайн: содержимое стилизуем, маркеры (разница match − группа1) прячем.
        style(Self.boldRE, in: ts, range: full, content: [.font: boldBody])
        style(Self.italicRE, in: ts, range: full, content: [.font: italicBody])
        style(Self.codeRE, in: ts, range: full,
              content: [.font: monoFont, .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12)])
    }

    /// Стилизует содержимое (группа 1) и прячет обрамляющие маркеры каждого совпадения.
    private func style(_ regex: NSRegularExpression?, in ts: NSTextStorage, range: NSRange,
                       content: [NSAttributedString.Key: Any]) {
        guard let regex else { return }
        regex.enumerateMatches(in: ts.string, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let whole = match.range, inner = match.range(at: 1)
            ts.addAttributes(content, range: whole)          // весь спан — в стиль (в т.ч. маркеры)
            // Левый маркер: [whole.start, inner.start); правый: [inner.end, whole.end).
            self.hide(NSRange(location: whole.location, length: inner.location - whole.location), in: ts)
            let innerEnd = inner.location + inner.length
            self.hide(NSRange(location: innerEnd, length: whole.location + whole.length - innerEnd), in: ts)
        }
    }

    /// Прячет диапазон маркера — кроме случая, когда он в абзаце под курсором (там оставляем видимым
    /// для правки).
    private func hide(_ range: NSRange, in ts: NSTextStorage) {
        guard range.length > 0 else { return }
        if revealParagraph.location != NSNotFound,
           NSIntersectionRange(range, revealParagraph).length > 0 { return }
        ts.addAttributes(hiddenAttrs, range: range)
        hiddenRanges.append(range)
    }

    /// Конец скрытого прогона справа от курсора (для перескока стрелкой →), либо nil.
    func hiddenRunEnd(rightOf caret: Int) -> Int? {
        for range in hiddenRanges where caret >= range.location && caret < range.location + range.length {
            return range.location + range.length
        }
        return nil
    }

    /// Начало скрытого прогона слева от курсора (для перескока стрелкой ←), либо nil. `index` —
    /// позиция символа слева от курсора (`caret - 1`).
    func hiddenRunStart(leftOf index: Int) -> Int? {
        for range in hiddenRanges where index >= range.location && index < range.location + range.length {
            return range.location
        }
        return nil
    }

    /// Уровень Markdown-заголовка (1…6) или nil. «#tag» без пробела после решёток — не заголовок.
    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = trimmed.dropFirst(hashes)
        return (after.isEmpty || after.first == " ") ? hashes : nil
    }

    /// Строка-пункт списка: маркер `•`/`-`/`*`/`+` или `N.` + пробел (с любым ведущим отступом).
    static func isListLine(_ line: String) -> Bool {
        NotesListItem.parse(line) != nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
