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
        migrateProjectsIfNeeded()
    }

    private enum Key {
        // Шаблоны распознавания (regex→URL). `projects` — legacy-ключ, читается только миграцией.
        static let templates = "templates"
        static let projects = "projects"
        static let templatesV1Migrated = "templatesV1Migrated"
        static let autoOpen = "autoOpen"
        static let defaultAction = "defaultAction"
        static let clipboardAction = "clipboardAction"
        // Хоткей окна ручного ввода (Accessibility не требует — лишь показывает окно).
        static let showInputHotKeyEnabled = "showInputHotKeyEnabled"
        static let showInputHotKeyKeyCode = "showInputHotKeyKeyCode"
        static let showInputHotKeyModifiers = "showInputHotKeyModifiers"
        // Хоткей окна-пикера сниппетов (авто-вставка требует Accessibility).
        static let snippetsHotKeyEnabled = "snippetsHotKeyEnabled"
        static let snippetsHotKeyKeyCode = "snippetsHotKeyKeyCode"
        static let snippetsHotKeyModifiers = "snippetsHotKeyModifiers"
        // Звук при срабатывании глобальных хоткеев.
        static let hotKeySoundsEnabled = "hotKeySoundsEnabled"
        static let hotKeySound = "hotKeySound"
        // Имя шаблона, выбранного в окне ввода последним — для предвыбора.
        static let lastQuickTemplate = "lastQuickTemplate"
    }

    /// Carbon-модификаторы controlKey | optionKey (⌃⌥).
    private static let defaultModifiers = 0x1000 | 0x0800
    /// Дефолтные комбинации: ⌃⌥C — окно ввода, ⌃⌥V — пикер сниппетов.
    private static let defaultShowInputKeyCode = 8  // kVK_ANSI_C
    private static let defaultSnippetsKeyCode = 9   // kVK_ANSI_V

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.autoOpen: false,
            // Обе горячие клавиши включены по умолчанию.
            Key.showInputHotKeyEnabled: true,
            Key.showInputHotKeyKeyCode: Self.defaultShowInputKeyCode,
            Key.showInputHotKeyModifiers: Self.defaultModifiers,
            Key.snippetsHotKeyEnabled: true,
            Key.snippetsHotKeyKeyCode: Self.defaultSnippetsKeyCode,
            Key.snippetsHotKeyModifiers: Self.defaultModifiers,
            Key.hotKeySoundsEnabled: true,
            Key.hotKeySound: HotKeySound.default.rawValue,
        ])
    }

    /// Все ключи приложения в `UserDefaults` — для полного сброса.
    private static let allKeys = [
        Key.templates, Key.projects, Key.templatesV1Migrated, Key.autoOpen,
        Key.defaultAction, Key.clipboardAction,
        Key.showInputHotKeyEnabled, Key.showInputHotKeyKeyCode, Key.showInputHotKeyModifiers,
        Key.snippetsHotKeyEnabled, Key.snippetsHotKeyKeyCode, Key.snippetsHotKeyModifiers,
        Key.hotKeySoundsEnabled,
        Key.hotKeySound,
        Key.lastQuickTemplate,
    ]

    /// Сбрасывает все настройки к значениям по умолчанию: шаблоны, действие при копировании
    /// и обе горячие клавиши (⌃⌥C — окно ввода, ⌃⌥V — пикер сниппетов, включены). После
    /// вызова окно настроек следует перечитать через `loadValues()`, а хоткеи — переприменить.
    public func resetToDefaults() {
        Self.allKeys.forEach(defaults.removeObject(forKey:))
        registerDefaults()
        // Чтобы повторная инициализация не восстановила шаблоны из остаточных legacy-`projects`.
        defaults.set(true, forKey: Key.templatesV1Migrated)
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

    // MARK: Hotkey «открыть окно ввода»

    /// Включён ли хоткей, открывающий окно ручного ввода тикета. По умолчанию включён.
    /// Accessibility ему не нужен — он лишь показывает окно (с доступом подставит выделение).
    public var showInputHotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.showInputHotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.showInputHotKeyEnabled) }
    }

    /// Код клавиши хоткея «окно ввода». По умолчанию 8 (C → ⌃⌥C).
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

    /// Включён ли хоткей, открывающий окно-пикер сниппетов. По умолчанию включён.
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

    /// Воспроизводить ли короткий звук при срабатывании глобальных хоткеев. По умолчанию включено.
    public var hotKeySoundsEnabled: Bool {
        get { defaults.bool(forKey: Key.hotKeySoundsEnabled) }
        set { defaults.set(newValue, forKey: Key.hotKeySoundsEnabled) }
    }

    /// Какой системный звук воспроизводить при срабатывании хоткеев. По умолчанию `Bottle`.
    public var hotKeySound: HotKeySound {
        get { HotKeySound(rawValue: defaults.string(forKey: Key.hotKeySound) ?? "") ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.hotKeySound) }
    }

    /// Имя шаблона, выбранного в окне ручного ввода последним. Пусто, пока не выбирали.
    /// Используется лишь для предвыбора в списке — если шаблон исчез, окно берёт первый.
    public var lastQuickTemplate: String {
        get { defaults.string(forKey: Key.lastQuickTemplate) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastQuickTemplate) }
    }
}
