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
        migrateCommandBindingsIfNeeded()
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
        // Единый словарь биндингов команд (JSON [CommandID: HotKeyBinding]) и флаг миграции.
        static let commandBindings = "commandBindings"
        static let commandBindingsMigrated = "commandBindingsMigrated"
        // Как вызывается панель команд (PaletteTrigger.rawValue).
        static let paletteTrigger = "paletteTrigger"
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
            Key.paletteTrigger: PaletteTrigger.default.rawValue,
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
        Key.commandBindings, Key.commandBindingsMigrated, Key.paletteTrigger,
    ]

    /// Сбрасывает все настройки к значениям по умолчанию: шаблоны, действие при копировании
    /// и обе горячие клавиши (⌃⌥C — окно ввода, ⌃⌥V — пикер сниппетов, включены). После
    /// вызова окно настроек следует перечитать через `loadValues()`, а хоткеи — переприменить.
    public func resetToDefaults() {
        Self.allKeys.forEach(defaults.removeObject(forKey:))
        registerDefaults()
        // Чтобы повторная инициализация не восстановила шаблоны из остаточных legacy-`projects`.
        defaults.set(true, forKey: Key.templatesV1Migrated)
        // Аналогично: не переимпортировать хоткеи из legacy-полей после сброса. Пустой словарь
        // `commandBindings` → `binding(for:)` вернёт значения по умолчанию.
        defaults.set(true, forKey: Key.commandBindingsMigrated)
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

    // MARK: Биндинги команд

    /// Комбинация команды. Если в словаре записи нет — значение по умолчанию (`defaultBinding`),
    /// поэтому свежая установка работает без явной инициализации словаря.
    public func binding(for id: CommandID) -> HotKeyBinding {
        loadCommandBindings()[id.rawValue] ?? Self.defaultBinding(for: id)
    }

    /// Сохраняет комбинацию команды в общий словарь (единый источник правды).
    public func setBinding(_ binding: HotKeyBinding, for id: CommandID) {
        var dict = loadCommandBindings()
        dict[id.rawValue] = binding
        storeCommandBindings(dict)
    }

    /// Значения по умолчанию: ⌃⌥C — окно ввода, ⌃⌥V — сниппеты, ⌃⌥N — заметки, ⇧⌘M — мьют
    /// микрофона; keep-awake и paste-plain по умолчанию без прямой комбинации (живут в панели).
    public static func defaultBinding(for id: CommandID) -> HotKeyBinding {
        switch id {
        case .quickInput:
            return HotKeyBinding(enabled: true, keyCode: 8,
                                 modifiers: CarbonModifier.control | CarbonModifier.option)
        case .snippets:
            return HotKeyBinding(enabled: true, keyCode: 9,
                                 modifiers: CarbonModifier.control | CarbonModifier.option)
        case .notes:
            // ⌃⌥N (keyCode 45 = kVK_ANSI_N) — та же мнемоника, что буква N в палитре.
            return HotKeyBinding(enabled: true, keyCode: 45,
                                 modifiers: CarbonModifier.control | CarbonModifier.option)
        case .micToggle:
            return HotKeyBinding(enabled: true, keyCode: 46,
                                 modifiers: CarbonModifier.shift | CarbonModifier.command)
        case .keepAwake, .pastePlain, .clipboardHistory, .textTransform, .audioOutput, .audioInput, .ocr:
            return HotKeyBinding(enabled: false, keyCode: 0, modifiers: 0)
        }
    }

    private func loadCommandBindings() -> [String: HotKeyBinding] {
        guard let data = defaults.data(forKey: Key.commandBindings),
              let dict = try? JSONDecoder().decode([String: HotKeyBinding].self, from: data)
        else { return [:] }
        return dict
    }

    private func storeCommandBindings(_ dict: [String: HotKeyBinding]) {
        defaults.set(try? JSONEncoder().encode(dict), forKey: Key.commandBindings)
    }

    /// Как вызывается панель команд. По умолчанию — двойной тап правого ⌘.
    public var paletteTrigger: PaletteTrigger {
        get { PaletteTrigger(rawValue: defaults.string(forKey: Key.paletteTrigger) ?? "") ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.paletteTrigger) }
    }

    /// Однократно переносит пользовательские комбинации из legacy-полей в общий словарь.
    /// Остальные команды берут значения из `defaultBinding`. Идемпотентно (флаг). Читаем СЫРЫЕ
    /// legacy-ключи напрямую — свойства-шимы уже смотрят в словарь, через них читать нельзя.
    private func migrateCommandBindingsIfNeeded() {
        guard !defaults.bool(forKey: Key.commandBindingsMigrated) else { return }
        defaults.set(true, forKey: Key.commandBindingsMigrated)

        var dict = loadCommandBindings()
        dict[CommandID.quickInput.rawValue] = HotKeyBinding(
            enabled: defaults.bool(forKey: Key.showInputHotKeyEnabled),
            keyCode: defaults.integer(forKey: Key.showInputHotKeyKeyCode),
            modifiers: defaults.integer(forKey: Key.showInputHotKeyModifiers))
        dict[CommandID.snippets.rawValue] = HotKeyBinding(
            enabled: defaults.bool(forKey: Key.snippetsHotKeyEnabled),
            keyCode: defaults.integer(forKey: Key.snippetsHotKeyKeyCode),
            modifiers: defaults.integer(forKey: Key.snippetsHotKeyModifiers))
        storeCommandBindings(dict)
    }

    // MARK: Legacy-шимы над `commandBindings`

    /// Поля `showInputHotKey*` / `snippetsHotKey*` оставлены ради существующего кода
    /// (SettingsWindow/AppDelegate). Это тонкие шимы над словарём команд — единый источник
    /// правды — он; прямого чтения/записи в legacy-ключи `UserDefaults` больше нет.
    public var showInputHotKeyEnabled: Bool {
        get { binding(for: .quickInput).enabled }
        set { updateBinding(.quickInput) { $0.enabled = newValue } }
    }
    public var showInputHotKeyKeyCode: Int {
        get { binding(for: .quickInput).keyCode }
        set { updateBinding(.quickInput) { $0.keyCode = newValue } }
    }
    public var showInputHotKeyModifiers: Int {
        get { binding(for: .quickInput).modifiers }
        set { updateBinding(.quickInput) { $0.modifiers = newValue } }
    }
    public var snippetsHotKeyEnabled: Bool {
        get { binding(for: .snippets).enabled }
        set { updateBinding(.snippets) { $0.enabled = newValue } }
    }
    public var snippetsHotKeyKeyCode: Int {
        get { binding(for: .snippets).keyCode }
        set { updateBinding(.snippets) { $0.keyCode = newValue } }
    }
    public var snippetsHotKeyModifiers: Int {
        get { binding(for: .snippets).modifiers }
        set { updateBinding(.snippets) { $0.modifiers = newValue } }
    }

    private func updateBinding(_ id: CommandID, _ mutate: (inout HotKeyBinding) -> Void) {
        var b = binding(for: id)
        mutate(&b)
        setBinding(b, for: id)
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
