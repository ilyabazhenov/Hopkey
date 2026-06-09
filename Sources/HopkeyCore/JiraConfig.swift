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
        migrateHotKeysIfNeeded()
    }

    private enum Key {
        static let projects = "projects"
        static let autoOpen = "autoOpen"
        // Legacy: единственный хоткей (до разделения на «открыть» и «скопировать»).
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let defaultAction = "defaultAction"
        static let hotKeyAction = "hotKeyAction"
        static let clipboardAction = "clipboardAction"
        // Два отдельных хоткея с фиксированным действием.
        static let openHotKeyEnabled = "openHotKeyEnabled"
        static let openHotKeyKeyCode = "openHotKeyKeyCode"
        static let openHotKeyModifiers = "openHotKeyModifiers"
        static let copyHotKeyEnabled = "copyHotKeyEnabled"
        static let copyHotKeyKeyCode = "copyHotKeyKeyCode"
        static let copyHotKeyModifiers = "copyHotKeyModifiers"
        static let hotKeysV2Migrated = "hotKeysV2Migrated"
    }

    /// Carbon-модификаторы controlKey | optionKey (⌃⌥).
    private static let defaultModifiers = 0x1000 | 0x0800
    /// Дефолтные комбинации хоткеев: ⌃⌥J — открыть, ⌃⌥K — скопировать.
    private static let defaultOpenKeyCode = 38  // kVK_ANSI_J
    private static let defaultCopyKeyCode = 40  // kVK_ANSI_K

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.autoOpen: false,
            Key.hotKeyEnabled: false,
            Key.hotKeyKeyCode: Self.defaultOpenKeyCode,
            Key.hotKeyModifiers: Self.defaultModifiers,
        ])
    }

    /// Однократно переносит единственный legacy-хоткей в нужный из двух новых слотов
    /// (по его прежнему действию) и задаёт дефолты для второго слота. Идемпотентно.
    private func migrateHotKeysIfNeeded() {
        guard !defaults.bool(forKey: Key.hotKeysV2Migrated) else { return }
        defaults.set(true, forKey: Key.hotKeysV2Migrated)

        let legacyEnabled = defaults.bool(forKey: Key.hotKeyEnabled)
        let legacyKeyCode = defaults.integer(forKey: Key.hotKeyKeyCode)
        let legacyModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
        let defaultOpen = (Self.defaultOpenKeyCode, Self.defaultModifiers, false)
        let defaultCopy = (Self.defaultCopyKeyCode, Self.defaultModifiers, false)

        // Прежнее действие хоткея определяет, в какой слот лёг настроенный пользователем хоткей.
        let (open, copy): ((Int, Int, Bool), (Int, Int, Bool)) = hotKeyAction == .copyURL
            ? (defaultOpen, (legacyKeyCode, legacyModifiers, legacyEnabled))
            : ((legacyKeyCode, legacyModifiers, legacyEnabled), defaultCopy)

        defaults.set(open.0, forKey: Key.openHotKeyKeyCode)
        defaults.set(open.1, forKey: Key.openHotKeyModifiers)
        defaults.set(open.2, forKey: Key.openHotKeyEnabled)
        defaults.set(copy.0, forKey: Key.copyHotKeyKeyCode)
        defaults.set(copy.1, forKey: Key.copyHotKeyModifiers)
        defaults.set(copy.2, forKey: Key.copyHotKeyEnabled)
    }

    /// Список проектов Jira (каждый со своим URL и префиксами). Пусто, пока не задан.
    /// Хранится в `UserDefaults` как JSON.
    public var projects: [JiraProject] {
        get {
            guard let data = defaults.data(forKey: Key.projects),
                  let list = try? JSONDecoder().decode([JiraProject].self, from: data)
            else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.projects) }
    }

    /// Заданы ли обязательные настройки — есть хотя бы один валидный проект.
    public var isConfigured: Bool {
        projects.contains(where: \.isValid)
    }

    /// Открывать сразу (true) или показывать уведомление с кликом (false, по умолчанию).
    public var autoOpen: Bool {
        get { defaults.bool(forKey: Key.autoOpen) }
        set { defaults.set(newValue, forKey: Key.autoOpen) }
    }

    // MARK: Legacy single hotkey (используется только миграцией в два слота)

    /// Legacy: включён ли единственный глобальный хоткей. Источник для миграции.
    public var hotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.hotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.hotKeyEnabled) }
    }

    /// Legacy: код клавиши единственного хоткея. Источник для миграции.
    public var hotKeyKeyCode: Int {
        get { defaults.integer(forKey: Key.hotKeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotKeyKeyCode) }
    }

    /// Legacy: модификаторы единственного хоткея. Источник для миграции.
    public var hotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.hotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.hotKeyModifiers) }
    }

    /// Legacy: прежнее действие хоткея. Теперь определяет лишь слот при миграции.
    public var hotKeyAction: TicketAction {
        get { TicketAction(rawValue: defaults.string(forKey: Key.hotKeyAction) ?? "") ?? defaultAction }
        set { defaults.set(newValue.rawValue, forKey: Key.hotKeyAction) }
    }

    // MARK: Actions

    /// Legacy-настройка действия: раньше управляла и хоткеем, и авто-открытием из буфера.
    /// Теперь служит дефолтом для `clipboardAction` (если новый ключ не задан → `.openInBrowser`).
    public var defaultAction: TicketAction {
        get { TicketAction(rawValue: defaults.string(forKey: Key.defaultAction) ?? "") ?? .openInBrowser }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultAction) }
    }

    /// Что делает авто-открытие/уведомление при копировании ключа тикета в буфер.
    /// При отсутствии значения наследует `defaultAction` (миграция со старой версии).
    public var clipboardAction: TicketAction {
        get { TicketAction(rawValue: defaults.string(forKey: Key.clipboardAction) ?? "") ?? defaultAction }
        set { defaults.set(newValue.rawValue, forKey: Key.clipboardAction) }
    }

    // MARK: Hotkey «открыть в браузере»

    /// Включён ли хоткей «открыть в браузере» (требует Accessibility).
    public var openHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.openHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.openHotKeyEnabled) }
    }

    /// Код клавиши хоткея «открыть в браузере». По умолчанию 38 (J → ⌃⌥J).
    public var openHotKeyKeyCode: Int {
        get { defaults.integer(forKey: Key.openHotKeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.openHotKeyKeyCode) }
    }

    /// Модификаторы хоткея «открыть в браузере» в Carbon-формате.
    public var openHotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.openHotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.openHotKeyModifiers) }
    }

    // MARK: Hotkey «скопировать ссылку»

    /// Включён ли хоткей «скопировать ссылку» (требует Accessibility).
    public var copyHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.copyHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.copyHotKeyEnabled) }
    }

    /// Код клавиши хоткея «скопировать ссылку». По умолчанию 40 (K → ⌃⌥K).
    public var copyHotKeyKeyCode: Int {
        get { defaults.integer(forKey: Key.copyHotKeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.copyHotKeyKeyCode) }
    }

    /// Модификаторы хоткея «скопировать ссылку» в Carbon-формате.
    public var copyHotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.copyHotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.copyHotKeyModifiers) }
    }
}
