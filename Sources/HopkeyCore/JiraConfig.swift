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
        migrateProjectsIfNeeded()
    }

    private enum Key {
        // Шаблоны распознавания (regex→URL). `projects` — legacy-ключ, читается только миграцией.
        static let templates = "templates"
        static let projects = "projects"
        static let templatesV1Migrated = "templatesV1Migrated"
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
        // Хоткей, открывающий окно ручного ввода тикета (не требует Accessibility).
        static let showInputHotKeyEnabled = "showInputHotKeyEnabled"
        static let showInputHotKeyKeyCode = "showInputHotKeyKeyCode"
        static let showInputHotKeyModifiers = "showInputHotKeyModifiers"
        // Хоткей, открывающий окно-пикер сниппетов (авто-вставка требует Accessibility).
        static let snippetsHotKeyEnabled = "snippetsHotKeyEnabled"
        static let snippetsHotKeyKeyCode = "snippetsHotKeyKeyCode"
        static let snippetsHotKeyModifiers = "snippetsHotKeyModifiers"
        // Имя шаблона, выбранного в окне ввода последним — для предвыбора.
        static let lastQuickTemplate = "lastQuickTemplate"
        static let hotKeysV2Migrated = "hotKeysV2Migrated"
    }

    /// Carbon-модификаторы controlKey | optionKey (⌃⌥).
    private static let defaultModifiers = 0x1000 | 0x0800
    /// Дефолтные комбинации хоткеев: ⌃⌥J — открыть, ⌃⌥K — скопировать, ⌃⌥O — окно ввода.
    private static let defaultOpenKeyCode = 38  // kVK_ANSI_J
    private static let defaultCopyKeyCode = 40  // kVK_ANSI_K
    private static let defaultShowInputKeyCode = 31  // kVK_ANSI_O
    private static let defaultSnippetsKeyCode = 9  // kVK_ANSI_V (⌃⌥V)

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.autoOpen: false,
            Key.hotKeyEnabled: false,
            Key.hotKeyKeyCode: Self.defaultOpenKeyCode,
            Key.hotKeyModifiers: Self.defaultModifiers,
            // Слот «окно ввода» появился позже миграции в два слота, поэтому его дефолты
            // живут здесь (регистрационный домен) — так и новые, и обновившиеся
            // пользователи получают ⌃⌥O без отдельной миграции.
            Key.showInputHotKeyEnabled: false,
            Key.showInputHotKeyKeyCode: Self.defaultShowInputKeyCode,
            Key.showInputHotKeyModifiers: Self.defaultModifiers,
            // Слот «пикер сниппетов» появился ещё позже — его дефолты тоже живут здесь,
            // чтобы и новые, и обновившиеся пользователи получили ⌃⌥V без отдельной миграции.
            Key.snippetsHotKeyEnabled: false,
            Key.snippetsHotKeyKeyCode: Self.defaultSnippetsKeyCode,
            Key.snippetsHotKeyModifiers: Self.defaultModifiers,
        ])
    }

    /// Все ключи приложения в `UserDefaults` — для полного сброса.
    private static let allKeys = [
        Key.templates, Key.projects, Key.templatesV1Migrated, Key.autoOpen,
        Key.hotKeyEnabled, Key.hotKeyKeyCode, Key.hotKeyModifiers,
        Key.defaultAction, Key.hotKeyAction, Key.clipboardAction,
        Key.openHotKeyEnabled, Key.openHotKeyKeyCode, Key.openHotKeyModifiers,
        Key.copyHotKeyEnabled, Key.copyHotKeyKeyCode, Key.copyHotKeyModifiers,
        Key.showInputHotKeyEnabled, Key.showInputHotKeyKeyCode, Key.showInputHotKeyModifiers,
        Key.snippetsHotKeyEnabled, Key.snippetsHotKeyKeyCode, Key.snippetsHotKeyModifiers,
        Key.lastQuickTemplate,
        Key.hotKeysV2Migrated,
    ]

    /// Сбрасывает все настройки к значениям по умолчанию: проекты, действие при
    /// копировании и оба хоткея (⌃⌥J / ⌃⌥K, выключены). После вызова окно настроек
    /// следует перечитать через `loadValues()`, а хоткеи — переприменить.
    public func resetToDefaults() {
        Self.allKeys.forEach(defaults.removeObject(forKey:))
        registerDefaults()
        // Слоты хоткеев не входят в `registerDefaults` — задаём дефолты явно. Флаг
        // миграции выставляем, чтобы повторная инициализация не перетёрла их легаси-данными.
        defaults.set(true, forKey: Key.hotKeysV2Migrated)
        // Аналогично для шаблонов: иначе re-init восстановил бы их из остаточных legacy-`projects`.
        defaults.set(true, forKey: Key.templatesV1Migrated)
        defaults.set(Self.defaultOpenKeyCode, forKey: Key.openHotKeyKeyCode)
        defaults.set(Self.defaultModifiers, forKey: Key.openHotKeyModifiers)
        defaults.set(false, forKey: Key.openHotKeyEnabled)
        defaults.set(Self.defaultCopyKeyCode, forKey: Key.copyHotKeyKeyCode)
        defaults.set(Self.defaultModifiers, forKey: Key.copyHotKeyModifiers)
        defaults.set(false, forKey: Key.copyHotKeyEnabled)
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

    /// Legacy-форма проекта (только для разбора старого `projects` при миграции).
    private struct LegacyProject: Codable {
        var baseURL: String
        var prefixes: [String]
    }

    /// Однократно переносит старые `projects` в `templates`: каждый префикс каждого
    /// проекта разворачивается в отдельный шаблон (`PROJ` → `PROJ-(\d+)` →
    /// `<base>PROJ-$1`), чтобы в окне ручного ввода набирался только номер.
    /// Поведение Jira не меняется. Идемпотентно (флаг `templatesV1Migrated`).
    private func migrateProjectsIfNeeded() {
        guard !defaults.bool(forKey: Key.templatesV1Migrated) else { return }
        defaults.set(true, forKey: Key.templatesV1Migrated)

        guard let data = defaults.data(forKey: Key.projects),
              let legacy = try? JSONDecoder().decode([LegacyProject].self, from: data)
        else { return }

        var migrated: [LinkTemplate] = []
        for project in legacy {
            let base = Self.normalizeBaseURL(project.baseURL)
            for prefix in project.prefixes {
                let clean = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let escaped = NSRegularExpression.escapedPattern(for: clean)
                migrated.append(LinkTemplate(
                    name: clean,
                    pattern: "\(escaped)-(\\d+)",
                    url: "\(base)\(clean)-$1",
                    wholeWord: true, uppercase: true, enabled: true))
            }
        }
        guard !migrated.isEmpty else { return }
        defaults.set(try? JSONEncoder().encode(migrated), forKey: Key.templates)
    }

    /// Гарантирует один завершающий слэш у базового URL (для сборки `base + ключ`).
    private static func normalizeBaseURL(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    /// Шаблоны распознавания (regex→URL). Пусто, пока не задано. Хранится как JSON.
    public var templates: [LinkTemplate] {
        get {
            guard let data = defaults.data(forKey: Key.templates),
                  let list = try? JSONDecoder().decode([LinkTemplate].self, from: data)
            else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.templates) }
    }

    /// Заданы ли обязательные настройки — есть хотя бы один валидный шаблон.
    public var isConfigured: Bool {
        templates.contains(where: \.isValid)
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

    // MARK: Hotkey «открыть окно ввода»

    /// Включён ли хоткей, открывающий окно ручного ввода тикета.
    /// В отличие от двух хоткеев выше, Accessibility ему не нужен — он лишь показывает окно.
    public var showInputHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.showInputHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.showInputHotKeyEnabled) }
    }

    /// Код клавиши хоткея «окно ввода». По умолчанию 31 (O → ⌃⌥O).
    public var showInputHotKeyKeyCode: Int {
        get { defaults.integer(forKey: Key.showInputHotKeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.showInputHotKeyKeyCode) }
    }

    /// Модификаторы хоткея «окно ввода» в Carbon-формате.
    public var showInputHotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.showInputHotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.showInputHotKeyModifiers) }
    }

    // MARK: Hotkey «пикер сниппетов»

    /// Включён ли хоткей, открывающий окно-пикер сниппетов.
    /// Авто-вставка выбранного значения (синтез Cmd+V в чужое поле) требует Accessibility.
    public var snippetsHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.snippetsHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.snippetsHotKeyEnabled) }
    }

    /// Код клавиши хоткея «пикер сниппетов». По умолчанию 9 (V → ⌃⌥V).
    public var snippetsHotKeyKeyCode: Int {
        get { defaults.integer(forKey: Key.snippetsHotKeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.snippetsHotKeyKeyCode) }
    }

    /// Модификаторы хоткея «пикер сниппетов» в Carbon-формате.
    public var snippetsHotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.snippetsHotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.snippetsHotKeyModifiers) }
    }

    /// Имя шаблона, выбранного в окне ручного ввода последним. Пусто, пока не выбирали.
    /// Используется лишь для предвыбора в списке — если шаблон исчез, окно берёт первый.
    public var lastQuickTemplate: String {
        get { defaults.string(forKey: Key.lastQuickTemplate) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastQuickTemplate) }
    }
}
