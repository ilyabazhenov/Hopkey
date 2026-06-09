import AppKit
import HopkeyCore

/// Простое окно настроек: базовый URL, список префиксов, переключатели.
/// Изменения сохраняются по кнопке «Сохранить» и сообщаются через `onSave`.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let config: JiraConfig
    /// Вызывается после сохранения, чтобы AppDelegate применил изменения (хоткей и т.п.).
    var onSave: (() -> Void)?

    private let baseURLField = NSTextField()
    private let prefixesField = NSTextField()
    private let autoOpenCheck = NSButton(checkboxWithTitle: "Открывать сразу (без уведомления)", target: nil, action: nil)
    private let hotKeyCheck = NSButton(checkboxWithTitle: "Включить глобальный хоткей (нужен Accessibility)", target: nil, action: nil)
    private let hotKeyRecorder = HotKeyRecorderView()

    init(config: JiraConfig) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Hopkey"
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }

        let baseLabel = label("Базовый URL Jira:")
        let prefixesLabel = label("Префиксы (через запятую или пробел):")

        for field in [baseURLField, prefixesField] {
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        baseURLField.placeholderString = "https://your-jira/browse/"
        prefixesField.placeholderString = "PROJ, TEAM"
        autoOpenCheck.translatesAutoresizingMaskIntoConstraints = false
        hotKeyCheck.translatesAutoresizingMaskIntoConstraints = false

        let hotKeyLabel = label("Комбинация:")
        hotKeyRecorder.translatesAutoresizingMaskIntoConstraints = false
        let hotKeyRow = NSStackView(views: [hotKeyLabel, hotKeyRecorder])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.alignment = .centerY
        hotKeyRow.spacing = 8
        hotKeyRow.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            baseLabel, baseURLField,
            prefixesLabel, prefixesField,
            autoOpenCheck, hotKeyCheck,
            hotKeyRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(saveButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            baseURLField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            prefixesField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hotKeyRecorder.widthAnchor.constraint(equalToConstant: 160),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func loadValues() {
        baseURLField.stringValue = config.baseURL
        prefixesField.stringValue = config.prefixes.joined(separator: ", ")
        autoOpenCheck.state = config.autoOpen ? .on : .off
        hotKeyCheck.state = config.hotKeyEnabled ? .on : .off
        hotKeyRecorder.combo = (UInt32(config.hotKeyKeyCode), UInt32(config.hotKeyModifiers))
    }

    func showWindow() {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func save() {
        config.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        config.prefixes = prefixesField.stringValue
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        config.autoOpen = autoOpenCheck.state == .on
        config.hotKeyEnabled = hotKeyCheck.state == .on
        config.hotKeyKeyCode = Int(hotKeyRecorder.combo.keyCode)
        config.hotKeyModifiers = Int(hotKeyRecorder.combo.modifiers)

        onSave?()
        window?.close()
    }
}
