import AppKit
import HopkeyCore

/// Перевёрнутая вью (origin сверху-слева) — документ NSScrollView списка. Иначе короткий контент
/// (когда фильтр оставил пару строк) «падает» к низу вьюпорта, а не прижимается к верху.
///
/// Также умеет быть первым откликом (третья остановка Tab-цикла): в фокусе ↑↓ листают список,
/// Enter вставляет, Tab уводит фокус дальше. `onCommand` возвращает true, если клавиша обработана.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    var focusable = false
    var onCommand: ((Selector) -> Bool)?

    override var acceptsFirstResponder: Bool { focusable }

    /// Разбираем клавиши сами по keyCode (не зависит от раскладки): у обычной NSView
    /// `interpretKeyEvents` не транслирует события в doCommand (нет NSTextInputClient).
    override func keyDown(with event: NSEvent) {
        let selector: Selector?
        switch event.keyCode {
        case 126: selector = #selector(NSResponder.moveUp(_:))       // ↑
        case 125: selector = #selector(NSResponder.moveDown(_:))     // ↓
        case 36, 76: selector = #selector(NSResponder.insertNewline(_:))   // ↩ / keypad Enter
        case 53: selector = #selector(NSResponder.cancelOperation(_:))     // Esc
        case 48: selector = event.modifierFlags.contains(.shift)          // Tab / ⇧Tab
            ? #selector(NSResponder.insertBacktab(_:))
            : #selector(NSResponder.insertTab(_:))
        default: selector = nil
        }
        if let selector, onCommand?(selector) == true { return }
        super.keyDown(with: event)
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

/// Ручное преобразование текста как **модуль палитры**: поле ввода сверху, список всех способов
/// (только названия), фильтр и единое поле результата для **выбранного** способа. Живёт внутри
/// окна палитры команд (см. `PaletteModule`) — отдельного окна не открывает.
///
/// Открывается, когда команда «Преобразовать выделение» вызвана из палитры или напрямую (меню/
/// хоткей — тогда AppDelegate сперва открывает палитру): выделение (если есть)
/// префиллит поле ввода. Пользователь выбирает способ (кликом/↑↓), внизу виден результат, и жмёт
/// «Вставить» (⌘↩). Esc возвращает в корень палитры. Саму вставку делает AppDelegate через `onApply`.
final class TransformModule: NSObject, PaletteModule, NSTextViewDelegate, NSSearchFieldDelegate {

    /// Итоговый (уже преобразованный) текст для вставки в целевое поле.
    var onApply: ((String) -> Void)?

    private let inputView = PlaceholderTextView()
    private let resultView = PlaceholderTextView()
    private let searchField = NSSearchField()
    private let listStack = NSStackView()
    private let listScroll = NSScrollView()
    private let listContainer = FlippedView()
    private let resultCaption = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let insertButton = NSButton()
    private let copyButton = NSButton()

    private let transforms = TextTransform.allCases
    private var rows: [CommandRowView] = []
    private var results: [String?] = []
    private var headerViews: [TextTransform.Category: NSView] = [:]
    private var selectedIndex = -1
    /// Текущая строка поиска. Прячет несовпавшие строки списка (и пустые секции); ↑/↓ листают
    /// только видимые-и-применимые строки.
    private var filter = ""
    /// Текущая наведённая строка. Наведение эксклюзивно: при входе в новую строку гасим прежнюю —
    /// иначе потерянный `mouseExited` (быстрый проход по списку) оставляет подсветку залипшей.
    private weak var hoveredRow: CommandRowView?
    /// Был ли текст префилла пуст на входе — определяет, куда ставить фокус (поле ввода или список).
    private var prefillWasEmpty = true
    private weak var host: PaletteHost?

    private var window: NSWindow? { contentView.window }

    // MARK: - PaletteModule

    let titleKey = "transform.input.title"

    private(set) lazy var contentView: NSView = buildContent()

    /// Модуль высоты не растит от контента — фиксируем как раньше окно (≈620), палитра докинет хедер.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat { 576 }

    /// Вход в режим: фокус в поле ввода при ручном наборе, в список — когда текст уже подставлен
    /// (сразу листать ↑↓ и вставлять). Приложение не активируем — палитра уже ключевая (в отличие
    /// от отдельного окна, которому нужен NSApp.activate).
    func moduleWillAppear(host: PaletteHost) {
        self.host = host
        window?.makeFirstResponder(prefillWasEmpty ? inputView : listContainer)
    }

    /// ⌘↩ на уровне окна палитры — вставить выбранное.
    func handleCommandReturn() -> Bool { applySelected(); return true }

    /// Подставляет исходный текст и пересобирает результаты/фильтр под него. Вызывать до `enterModule`.
    func prefill(_ text: String) {
        // Гарантируем, что ленивый `contentView` (а с ним `rows`/`results` из `buildRows`) построен:
        // `prefill` может прийти раньше, чем палитра впервые дотянется до вьюхи в `enterModule`.
        _ = contentView
        prefillWasEmpty = text.isEmpty
        inputView.string = text
        searchField.stringValue = ""
        filter = ""
        selectedIndex = -1
        refreshResults()
        applyFilter()
    }

    private func buildContent() -> NSView {
        let content = NSView()

        let field = boxedTextView(inputView, editable: true, placeholder: L("transform.input.placeholder"))
        inputView.delegate = self
        inputView.onCancel = { [weak self] in self?.host?.dismissModule() }
        content.addSubview(field)

        // Поле-фильтр над списком: сужает список по названию/термину (jwt, base64…). ↑/↓ и Enter
        // работают и отсюда (см. NSSearchFieldDelegate), так что можно печатать и сразу вставлять.
        searchField.placeholderString = L("transform.input.filter")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        // Список преобразований — только названия. Результат отдельным полем снизу, чтобы
        // длинная строка не тянула окно вширь и не показывать по превью на каждую строку.
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false
        buildRows()

        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listStack)
        // Список — третья остановка Tab-цикла: в фокусе сам разбирает ↑↓/Enter/Esc/Tab. Признак
        // фокуса — подсветка выбранной строки и отсутствие текстового курсора, рамки не рисуем.
        listContainer.focusable = true
        listContainer.onCommand = { [weak self] selector in self?.handleListCommand(selector) ?? false }

        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.documentView = listContainer
        content.addSubview(listScroll)

        // Пустое состояние поверх списка, когда фильтр не дал совпадений.
        emptyLabel.stringValue = L("transform.input.noMatches")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        // Подпись над полем результата: имя выбранного способа — чтобы поле результата не путали
        // со вторым полем ввода (у них одинаковая рамка) и было видно, что именно применилось.
        resultCaption.font = .systemFont(ofSize: 11, weight: .medium)
        resultCaption.textColor = .secondaryLabelColor
        resultCaption.lineBreakMode = .byTruncatingTail
        resultCaption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(resultCaption)

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

        // Вторичное действие: модуль открывается всегда, в т.ч. когда вставлять некуда (нет целевого
        // поля / Accessibility) — тогда результат можно просто скопировать.
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.imagePosition = .imageLeading
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("transform.input.copy"))
        copyButton.title = L("transform.input.copy")
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(copyButton)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            field.heightAnchor.constraint(equalToConstant: 76),

            searchField.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            listScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            listScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            listScroll.bottomAnchor.constraint(equalTo: resultCaption.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),

            resultCaption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            resultCaption.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            resultCaption.bottomAnchor.constraint(equalTo: resultBox.topAnchor, constant: -4),

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
            hint.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),

            copyButton.trailingAnchor.constraint(equalTo: insertButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: insertButton.centerYAnchor),

            insertButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            insertButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        return content
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
        var lastCategory: TextTransform.Category?
        for (index, transform) in transforms.enumerated() {
            // Заголовок секции — при смене категории (allCases идёт уже сгруппированно).
            if transform.category != lastCategory {
                let header = makeSectionHeader(L(transform.category.titleKey))
                listStack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                headerViews[transform.category] = header
                lastCategory = transform.category
            }
            // Без цифровых бейджей: фокус всегда в поле ввода (цифра просто напечаталась бы),
            // поэтому выбор — мышью или ↑/↓, а не по номеру. Бейдж-обманку не рисуем.
            let row = CommandRowView()
            row.configure(badge: nil, symbol: GlassListWindowController.transformSymbol(transform),
                          title: L(transform.titleKey), trailing: nil)
            row.onHover = { [weak self, weak row] hovered in
                guard let self, let row else { return }
                self.setRowHovered(row, hovered)
            }
            row.onClick = { [weak self] in self?.select(index) }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rows.append(row)
        }
        results = Array(repeating: nil, count: transforms.count)
    }

    /// Мелкий приглушённый заголовок секции (капсом) с небольшим верхним отступом.
    private func makeSectionHeader(_ title: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])
        return container
    }

    /// Пересчитывает результаты под текущий текст (и приглушает неприменимые), затем чинит выбор.
    private func refreshResults() {
        let source = inputView.string
        for (index, transform) in transforms.enumerated() {
            let result = source.isEmpty ? nil : transform.apply(to: source)
            results[index] = result
            rows[index].alphaValue = result == nil ? 0.4 : 1
        }
        reconcileSelection()
        updateSelection()
    }

    /// Применяет строку поиска: прячет несовпавшие строки и опустевшие секции, показывает пустое
    /// состояние, чинит выбор. Скрытые строки исключаются из выбора и навигации.
    private func applyFilter() {
        for (i, transform) in transforms.enumerated() {
            rows[i].isHidden = !transform.matches(query: filter, localizedTitle: L(transform.titleKey))
        }
        for (category, header) in headerViews {
            let anyVisible = transforms.enumerated()
                .contains { $0.element.category == category && !rows[$0.offset].isHidden }
            header.isHidden = !anyVisible
        }
        emptyLabel.isHidden = rows.contains { !$0.isHidden }
        reconcileSelection()
        updateSelection()
    }

    /// На строку можно встать выбором, если она не скрыта фильтром. Применимость к вводу —
    /// отдельно: у неприменимой (нет результата) просто пусто в поле результата и заблокированы
    /// «Вставить/Скопировать». Иначе при пустом вводе список был бы «мёртв» для навигации.
    private func isSelectable(_ index: Int) -> Bool {
        rows.indices.contains(index) && !rows[index].isHidden
    }

    /// Если текущий выбор невалиден (скрыт/неприменим) — переносит на первую доступную строку.
    private func reconcileSelection() {
        if !isSelectable(selectedIndex) {
            selectedIndex = (0..<transforms.count).first(where: isSelectable) ?? -1
        }
    }

    /// Ставит/снимает наведение так, чтобы подсвеченной была максимум одна строка. При входе в
    /// строку гасим прежнюю (страховка от потерянного `mouseExited`); при выходе — только свою.
    private func setRowHovered(_ row: CommandRowView, _ hovered: Bool) {
        if hovered {
            if hoveredRow !== row { hoveredRow?.setHovered(false) }
            row.setHovered(true)
            hoveredRow = row
        } else {
            row.setHovered(false)
            if hoveredRow === row { hoveredRow = nil }
        }
    }

    private func select(_ index: Int) {
        guard isSelectable(index) else { NSSound.beep(); return }
        selectedIndex = index
        updateSelection()
    }

    /// Перемещает выбор по списку на ±1, пропуская скрытые фильтром строки, с заворотом на краях —
    /// как в основной палитре команд (мышечная память единая на все списки приложения).
    private func moveSelection(by delta: Int) {
        let count = transforms.count
        guard (0..<count).contains(where: isSelectable) else { return }
        var i = selectedIndex
        for _ in 0..<count {
            i = ((i + delta) % count + count) % count  // заворот в обе стороны
            if isSelectable(i) { selectedIndex = i; updateSelection(); return }
        }
    }

    private func updateSelection() {
        for (i, row) in rows.enumerated() { row.isSelected = (i == selectedIndex) }
        let hasSelection = isSelectable(selectedIndex)
        // Результат — только у применимой строки; у неприменимой поле пустое, кнопки выключены.
        let result = hasSelection ? results[selectedIndex] : nil
        resultView.string = result ?? ""
        resultView.needsDisplay = true  // перерисовать плейсхолдер, когда результат пуст
        resultCaption.stringValue = hasSelection ? L(transforms[selectedIndex].titleKey) : ""
        insertButton.isEnabled = result != nil
        copyButton.isEnabled = result != nil
        if hasSelection { rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds) }
    }

    @objc private func insertClicked() { applySelected() }

    /// Копирует результат в буфер (для случая, когда вставлять некуда). Кратко подтверждает
    /// галочкой на кнопке, потом возвращает исходный вид.
    @objc private func copyClicked() {
        guard results.indices.contains(selectedIndex), let result = results[selectedIndex] else {
            NSSound.beep(); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        copyButton.title = L("transform.input.copied")
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.copyButton.title = L("transform.input.copy")
            self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                            accessibilityDescription: L("transform.input.copy"))
        }
    }

    /// Вставка выбранного: закрываем палитру целиком (как вставка сниппета) и отдаём результат
    /// наружу — AppDelegate вернёт фокус целевому приложению и синтезирует Cmd+V.
    private func applySelected() {
        guard results.indices.contains(selectedIndex), let result = results[selectedIndex] else {
            NSSound.beep(); return
        }
        host?.closePalette()
        onApply?(result)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inputView else { return }
        refreshResults()
    }

    /// Tab/⇧Tab в поле ввода не вставляют символ табуляции, а крутят фокус по циклу
    /// поле ввода → фильтр → список → снова поле ввода. Иначе NSTextView глотает Tab как текст.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): window?.makeFirstResponder(searchField); return true
        case #selector(NSResponder.insertBacktab(_:)): window?.makeFirstResponder(listContainer); return true
        default: return false
        }
    }

    /// Клавиши, когда фокус на списке (третья Tab-остановка): листаем ↑↓, вставляем Enter,
    /// закрываем Esc, Tab уводит фокус дальше по циклу. true — клавиша обработана здесь.
    private func handleListCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)): applySelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): host?.dismissModule(); return true
        case #selector(NSResponder.insertTab(_:)): window?.makeFirstResponder(inputView); return true
        case #selector(NSResponder.insertBacktab(_:)): window?.makeFirstResponder(searchField); return true
        default: return false
        }
    }

    // MARK: - NSSearchFieldDelegate (поле-фильтр)

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        filter = searchField.stringValue
        applyFilter()
    }

    /// Enter/Esc/Tab из поля-фильтра: вставить выбранное, закрыть, увести фокус на список.
    /// Стрелки тут НЕ листают список — они двигают курсор в поле; для навигации Tab на список.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): applySelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): host?.dismissModule(); return true
        case #selector(NSResponder.insertTab(_:)): window?.makeFirstResponder(listContainer); return true
        case #selector(NSResponder.insertBacktab(_:)): window?.makeFirstResponder(inputView); return true
        default: return false
        }
    }
}
