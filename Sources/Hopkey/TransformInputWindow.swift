import AppKit
import HopkeyCore

/// Стеклянная панель окна ручного преобразования: ловит Esc (закрыть) и ⌘↩ (вставить
/// выбранное) на уровне окна — независимо от того, где фокус (поле ввода или сама панель).
/// Обычный ↩ оставляем полю: текст может быть многострочным.
private final class TransformInputPanel: NSPanel {
    var onCommandReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let onlyCommand = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask) == .command
        if onlyCommand, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Многострочное поле с приглушённым плейсхолдером, пока текст пуст. Esc пробрасываем наружу
/// (`onCancel`) — по умолчанию NSTextView гасит `cancelOperation` на себе. Текст переносится
/// по ширине (не растёт вправо): контейнер трекает ширину вьюхи.
private final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .systemFont(ofSize: 13),
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attrs)
    }
}

/// Окно ручного преобразования текста для команды «Преобразовать выделение».
///
/// Открывается, когда в момент вызова команды ничего не выделено. В одном окне: поле ввода
/// сверху, под ним — список всех преобразований (только названия), а внизу — единое поле
/// результата, показывающее итог **только для выбранного** способа. Так окно не разрастается
/// вширь от длинного превью и не рябит десятком строк-результатов сразу.
///
/// Пользователь набирает/вставляет текст, кликом выбирает способ (внизу виден результат) и
/// жмёт «Вставить» (или ⌘↩). Esc закрывает. Саму вставку делает AppDelegate через `onApply`.
final class TransformInputWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    /// Итоговый (уже преобразованный) текст для вставки в целевое поле.
    var onApply: ((String) -> Void)?

    private let inputView = PlaceholderTextView()
    private let resultView = PlaceholderTextView()
    private let listStack = NSStackView()
    private let insertButton = NSButton()

    private let transforms = TextTransform.allCases
    private var rows: [CommandRowView] = []
    private var results: [String?] = []
    private var selectedIndex = -1

    private static let windowWidth: CGFloat = 500
    private static let windowHeight: CGFloat = 560

    init() {
        let panel = TransformInputPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight),
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
        panel.onCommandReturn = { [weak self] in self?.applySelected() }
        panel.onCancel = { [weak self] in self?.window?.close() }
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI() {
        guard let window else { return }
        let content = NSView()
        installGlass(in: window, content: content)

        let header = Brand.makeHeaderView(title: L("transform.input.title"))
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let field = boxedTextView(inputView, editable: true, placeholder: L("transform.input.placeholder"))
        inputView.delegate = self
        inputView.onCancel = { [weak self] in self?.window?.close() }
        content.addSubview(field)

        // Список преобразований — только названия. Результат отдельным полем снизу, чтобы
        // длинная строка не тянула окно вширь и не показывать по превью на каждую строку.
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false
        buildRows()

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listStack)

        let listScroll = NSScrollView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.documentView = listContainer
        content.addSubview(listScroll)

        // Поле результата — только для выбранного способа. Read-only, но выделяемое (можно
        // скопировать вручную); текст переносится по ширине.
        let resultBox = boxedTextView(resultView, editable: false, placeholder: L("transform.input.result"))
        content.addSubview(resultBox)

        let hint = NSTextField(labelWithString: L("transform.input.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        insertButton.bezelStyle = .rounded
        insertButton.target = self
        insertButton.action = #selector(insertClicked)
        insertButton.bezelColor = Brand.buttonFill
        insertButton.image = NSImage(systemSymbolName: "text.insert",
                                     accessibilityDescription: L("transform.input.insert"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Brand.onAccentText]))
        insertButton.image?.isTemplate = false
        insertButton.imagePosition = .imageLeading
        insertButton.attributedTitle = NSAttributedString(
            string: L("transform.input.insert"),
            attributes: [.foregroundColor: Brand.onAccentText,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        insertButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(insertButton)

        NSLayoutConstraint.activate([
            // Жёстко фиксируем размер окна — оно не должно расти от контента.
            content.widthAnchor.constraint(equalToConstant: Self.windowWidth),
            content.heightAnchor.constraint(equalToConstant: Self.windowHeight),

            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),

            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            field.heightAnchor.constraint(equalToConstant: 76),

            listScroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            listScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            listScroll.bottomAnchor.constraint(equalTo: resultBox.topAnchor, constant: -10),

            listContainer.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            listContainer.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),

            listStack.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 6),
            listStack.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 6),
            listStack.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -6),
            listStack.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -6),

            resultBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            resultBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            resultBox.heightAnchor.constraint(equalToConstant: 84),
            resultBox.bottomAnchor.constraint(equalTo: insertButton.topAnchor, constant: -10),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.centerYAnchor.constraint(equalTo: insertButton.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: insertButton.leadingAnchor, constant: -8),

            insertButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            insertButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    /// Собирает поле-текствью в рамке поверх стекла. Текст переносится по ширине (не растёт вправо).
    private func boxedTextView(_ view: PlaceholderTextView, editable: Bool, placeholder: String) -> NSView {
        view.placeholder = placeholder
        view.font = .systemFont(ofSize: 13)
        view.isRichText = false
        view.isEditable = editable
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = view

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return box
    }

    private func buildRows() {
        for (index, transform) in transforms.enumerated() {
            let digit = index < 9 ? index + 1 : nil
            let row = CommandRowView()
            row.configure(badge: digit.map(String.init), symbol: GlassListWindowController.transformSymbol(transform),
                          title: L(transform.titleKey), trailing: nil)
            row.onHover = { [weak row] hovered in row?.setHovered(hovered) }
            row.onClick = { [weak self] in self?.select(index) }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rows.append(row)
        }
        results = Array(repeating: nil, count: transforms.count)
    }

    /// Пересчитывает доступность строк под текущий текст и обновляет поле результата. Если
    /// выбранная строка стала недоступной (nil-результат) — перекидывает выбор на первую доступную.
    private func refreshResults() {
        let source = inputView.string
        for (index, transform) in transforms.enumerated() {
            let result = source.isEmpty ? nil : transform.apply(to: source)
            results[index] = result
            rows[index].alphaValue = result == nil ? 0.4 : 1
        }
        if selectedIndex < 0 || results[selectedIndex] == nil {
            selectedIndex = results.firstIndex(where: { $0 != nil }) ?? -1
        }
        updateSelection()
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        guard results[index] != nil else { NSSound.beep(); return }
        selectedIndex = index
        updateSelection()
    }

    private func updateSelection() {
        for (i, row) in rows.enumerated() { row.isSelected = (i == selectedIndex) }
        resultView.string = results.indices.contains(selectedIndex) ? (results[selectedIndex] ?? "") : ""
        resultView.needsDisplay = true  // перерисовать плейсхолдер, когда результат пуст
        insertButton.isEnabled = selectedIndex >= 0
    }

    @objc private func insertClicked() { applySelected() }

    private func applySelected() {
        guard results.indices.contains(selectedIndex), let result = results[selectedIndex] else {
            NSSound.beep(); return
        }
        window?.close()
        onApply?(result)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inputView else { return }
        refreshResults()
    }

    // MARK: - Показ

    /// Показывает окно, ставит фокус в поле. Приложение — `.accessory`, поэтому без
    /// `NSApp.activate` панель не получит клавиатурный фокус (как в окне быстрого ввода).
    func show(prefill: String = "") {
        inputView.string = prefill
        selectedIndex = -1
        refreshResults()
        NSApp.activate(ignoringOtherApps: true)
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputView)
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
}
