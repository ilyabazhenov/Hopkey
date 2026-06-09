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
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.autoOpen: false,
            Key.hotKeyEnabled: false,
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

    /// Открывать сразу (true) или показывать уведомление (false).
    public var autoOpen: Bool {
        get { defaults.bool(forKey: Key.autoOpen) }
        set { defaults.set(newValue, forKey: Key.autoOpen) }
    }

    /// Включён ли глобальный хоткей (требует Accessibility).
    public var hotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.hotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.hotKeyEnabled) }
    }
}
