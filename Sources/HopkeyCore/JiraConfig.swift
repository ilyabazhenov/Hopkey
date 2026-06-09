import Foundation

/// Настройки приложения, хранящиеся в `UserDefaults`.
///
/// Здесь же лежат значения по умолчанию из требований пользователя.
public final class JiraConfig {

    public static let shared = JiraConfig()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private enum Key {
        static let baseURL = "baseURL"
        static let prefixes = "prefixes"
        static let autoOpen = "autoOpen"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.autoOpen: true,
            Key.hotKeyEnabled: false,
            // По умолчанию ⌃⌥J: keyCode 38 (kVK_ANSI_J),
            // модификаторы в Carbon-формате controlKey | optionKey = 0x1000 | 0x0800.
            Key.hotKeyKeyCode: 38,
            Key.hotKeyModifiers: 0x1000 | 0x0800,
        ])
    }

    /// Базовый URL Jira (с завершающим слэшем нормализуется в парсере). Пусто, пока не задан.
    public var baseURL: String {
        get { defaults.string(forKey: Key.baseURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.baseURL) }
    }

    /// Список префиксов проектов. Пусто, пока не задан.
    public var prefixes: [String] {
        get { defaults.stringArray(forKey: Key.prefixes) ?? [] }
        set { defaults.set(newValue, forKey: Key.prefixes) }
    }

    /// Заданы ли обязательные настройки (URL и хотя бы один префикс).
    public var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prefixes.isEmpty
    }

    /// Открывать сразу (true, по умолчанию) или показывать уведомление (false).
    public var autoOpen: Bool {
        get { defaults.bool(forKey: Key.autoOpen) }
        set { defaults.set(newValue, forKey: Key.autoOpen) }
    }

    /// Включён ли глобальный хоткей (требует Accessibility).
    public var hotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.hotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.hotKeyEnabled) }
    }

    /// Виртуальный код клавиши хоткея (kVK_*). По умолчанию 38 — клавиша J.
    public var hotKeyKeyCode: Int {
        get { defaults.integer(forKey: Key.hotKeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotKeyKeyCode) }
    }

    /// Модификаторы хоткея в Carbon-формате (controlKey/optionKey/cmdKey/shiftKey).
    public var hotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.hotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.hotKeyModifiers) }
    }
}
