import Foundation
import Security

/// Тип сниппета — определяет, как его показывать и что с ним можно делать.
/// `secret` (по умолчанию) маскируется в UI; `text` показывается как есть;
/// `link` показывается и его можно открыть в браузере.
public enum SnippetKind: String, Codable, CaseIterable {
    case secret
    case text
    case link

    /// Маскируется ли значение в интерфейсе (точками вместо текста).
    public var isSecret: Bool { self == .secret }
}

/// Действие по умолчанию для сниппета-ссылки — что делает основной выбор (1–9 / ↩ / клик).
/// Порядок кейсов = порядок сегментов переключателя в редакторе.
public enum SnippetLinkAction: String, Codable, CaseIterable {
    /// Вставить ссылку в активное поле.
    case paste
    /// Открыть ссылку в браузере.
    case open
    /// Скопировать ссылку в буфер обмена.
    case copy

    /// Действие в пикере, соответствующее этому выбору.
    public var activation: SnippetActivation {
        switch self {
        case .paste: return .paste
        case .open:  return .open
        case .copy:  return .copy
        }
    }
}

/// Что делает основной выбор сниппета в пикере (1–9 / ↩ / клик). Чистая логика поверх
/// типа и `linkAction` — вынесена, чтобы покрыть тестами без UI. Порядок кейсов = порядок
/// кнопок в строке пикера.
public enum SnippetActivation: Equatable, CaseIterable {
    case paste
    case open
    case copy
}

/// Сниппет — заранее заданное значение для быстрой вставки (пароль, ссылка на комнату
/// и т.п.). Публичный тип для UI несёт только id, имя и тип; само значение хранится
/// отдельно (см. `SnippetStore`) и наружу отдаётся лишь по явному запросу `value(for:)`.
public struct Snippet: Codable, Equatable {
    /// Стабильный идентификатор (UUID-строкой).
    public var id: String
    /// Видимое имя в списке пикера и настроек.
    public var name: String
    /// Тип: секрет / текст / ссылка.
    public var kind: SnippetKind
    /// Действие по умолчанию для ссылки (перейти/скопировать). Для прочих типов не
    /// используется.
    public var linkAction: SnippetLinkAction

    public init(id: String = UUID().uuidString, name: String, kind: SnippetKind = .secret,
                linkAction: SnippetLinkAction = .open) {
        self.id = id
        self.name = name
        self.kind = kind
        self.linkAction = linkAction
    }

    // Обратносовместимый декод: у legacy-метаданных (в UserDefaults до перехода на блоб)
    // ключей `kind`/`linkAction` нет — трактуем тип как `.secret`, действие — как `.open`,
    // иначе декод падает и миграция теряет старые сниппеты.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(SnippetKind.self, forKey: .kind) ?? .secret
        linkAction = try c.decodeIfPresent(SnippetLinkAction.self, forKey: .linkAction) ?? .open
    }

    /// Что делает основной выбор (1–9 / ↩ / клик): секрет и текст вставляются, ссылка —
    /// согласно `linkAction` (вставить / перейти / скопировать).
    public var primaryActivation: SnippetActivation {
        switch kind {
        case .secret, .text: return .paste
        case .link:          return linkAction.activation
        }
    }

    /// Все действия, осмысленные для этого сниппета, и кнопки строки пикера. Вставить и
    /// скопировать доступны всем; открыть — только ссылке. Кнопки показываем для всех явно
    /// (даже когда действие совпадает с основным по 1–9/↩/клику) — так любое действие под
    /// рукой; дубликат не мешает, потому что кнопки видны лишь на активной строке.
    public var availableActivations: [SnippetActivation] {
        switch kind {
        case .secret, .text: return [.paste, .copy]
        case .link:          return [.paste, .open, .copy]
        }
    }

    /// Имя для показа: непустое `name`, иначе плейсхолдер «без имени».
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    /// Нормализует строку значения в URL для открытия: добавляет схему `https://`,
    /// если она не указана. Возвращает `nil`, если получить валидный http(s)-URL не
    /// удалось. Вынесено сюда, чтобы логику можно было покрыть тестами.
    public static func url(forValue value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}

/// Внутренняя запись с самим значением — из неё собирается единый JSON-блоб в Keychain.
/// Декодер обратносовместим: у записей, сохранённых до появления `kind`, ключа нет —
/// такие сниппеты трактуем как `.secret`, чтобы прежнее поведение (маскировка) сохранилось.
private struct StoredSnippet: Codable {
    var id: String
    var name: String
    var value: String
    var kind: SnippetKind
    var linkAction: SnippetLinkAction

    init(id: String, name: String, value: String, kind: SnippetKind,
         linkAction: SnippetLinkAction) {
        self.id = id
        self.name = name
        self.value = value
        self.kind = kind
        self.linkAction = linkAction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decode(String.self, forKey: .value)
        kind = try c.decodeIfPresent(SnippetKind.self, forKey: .kind) ?? .secret
        linkAction = try c.decodeIfPresent(SnippetLinkAction.self, forKey: .linkAction) ?? .open
    }
}

/// Хранилище секретов по строковому ключу. На проде — Keychain (`KeychainStore`);
/// в тестах подменяется на in-memory реализацию.
public protocol SnippetSecretStore {
    func set(_ value: String, for account: String)
    func value(for account: String) -> String?
    func delete(_ account: String)
}

/// Хранилище сниппетов. ВСЕ сниппеты (id + имя + значение) лежат ОДНОЙ записью в Keychain
/// в виде JSON. Эту запись читаем РОВНО один раз при старте (`prepare()`) и держим в
/// памяти — поэтому запрос доступа к связке ключей возможен максимум один раз за запуск
/// (а после «Always Allow» — ни разу), и можно использовать строгий ACL (доступ только
/// нашему приложению). Выбор/показ сниппетов идёт из кэша, в Keychain больше не лезем;
/// запись/удаление обновляют кэш и переписывают блоб.
public final class SnippetStore {

    public static let shared = SnippetStore()

    private let defaults: UserDefaults
    private let keychain: SnippetSecretStore

    /// Снимок всех сниппетов в памяти (источник правды после первой загрузки).
    private var cache: [StoredSnippet] = []
    /// Загружали ли уже блоб из Keychain в этом запуске.
    private var loaded = false
    /// Защищает `cache`/`loaded`: к сниппетам обращаются и UI (главный поток), и
    /// возможные фоновые вызовы (пикер/вставка), поэтому первую загрузку и любую
    /// правку блоба сериализуем. Замок нерекурсивный — публичные методы берут его
    /// ровно один раз и зовут только приватные хелперы, которые замок не трогают.
    private let lock = NSLock()

    /// Единственная запись в Keychain со всем JSON-блобом.
    private static let blobAccount = "all"

    private enum Key {
        /// Legacy: метаданные сниппетов в UserDefaults (до перехода на единый блоб).
        static let legacySnippets = "snippets"
        static let blobMigrated = "snippetsBlobMigrated"
    }

    public init(defaults: UserDefaults = .standard,
                keychain: SnippetSecretStore = KeychainStore(service: "Hopkey Snippets")) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// Загружает блоб из Keychain в память (идемпотентно). Можно вызвать заранее, но это
    /// не обязательно: загрузка происходит ЛЕНИВО при первом обращении к данным — чтобы
    /// запрос доступа к связке появлялся не на старте, а когда сниппеты реально нужны
    /// (открыли их в настройках или впервые вызвали пикер/вставку).
    public func prepare() { lock.lock(); defer { lock.unlock() }; ensureLoaded() }

    /// Единственное место, читающее Keychain (и где возможен запрос доступа). Срабатывает
    /// один раз за запуск — при первом доступе к сниппетам.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        migrateToBlobIfNeeded()
        load()
    }

    /// Список сниппетов (id + имя). При первом обращении загружает блоб из Keychain.
    public var snippets: [Snippet] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return cache.map { Snippet(id: $0.id, name: $0.name, kind: $0.kind, linkAction: $0.linkAction) }
    }

    /// Значение сниппета (nil, если не найден). При первом обращении загружает блоб.
    public func value(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return cache.first { $0.id == id }?.value
    }

    /// Добавляет новый или обновляет существующий сниппет (по `id`) и переписывает блоб.
    public func upsert(_ snippet: Snippet, value: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let record = StoredSnippet(id: snippet.id, name: snippet.name, value: value,
                                   kind: snippet.kind, linkAction: snippet.linkAction)
        if let i = cache.firstIndex(where: { $0.id == snippet.id }) {
            cache[i] = record
        } else {
            cache.append(record)
        }
        persist()
    }

    /// Удаляет сниппет и переписывает блоб.
    public func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        cache.removeAll { $0.id == id }
        persist()
    }

    /// Полностью очищает сниппеты (и саму запись в Keychain) — для сброса настроек.
    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        cache = []
        keychain.delete(Self.blobAccount)
    }

    // MARK: - Внутреннее

    private func load() {
        // Записи нет — штатная ситуация первого запуска (не ошибка), просто пустой кэш.
        guard let json = keychain.value(for: Self.blobAccount),
              let data = json.data(using: .utf8) else { cache = []; return }
        do {
            cache = try JSONDecoder().decode([StoredSnippet].self, from: data)
        } catch {
            // Блоб есть, но не читается (повреждён/чужой формат) — это уже ошибка: логируем,
            // чтобы её можно было увидеть, а не молча терять сниппеты.
            NSLog("Hopkey: не удалось декодировать блоб сниппетов из Keychain: \(error)")
            cache = []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(cache)
            keychain.set(String(decoding: data, as: UTF8.self), for: Self.blobAccount)
        } catch {
            NSLog("Hopkey: не удалось сериализовать сниппеты для записи в Keychain: \(error)")
        }
    }

    /// Одноразовый перенос старого формата (метаданные в UserDefaults + значение на КАЖДЫЙ
    /// сниппет отдельной записью в Keychain) в единый блоб. Читает старые значения (если
    /// они были с разрешающим ACL — без запроса; иначе один запрос на запись — разово),
    /// собирает блоб и подчищает старые записи. Идемпотентно (флаг в UserDefaults).
    private func migrateToBlobIfNeeded() {
        guard !defaults.bool(forKey: Key.blobMigrated) else { return }
        defer { defaults.set(true, forKey: Key.blobMigrated) }

        guard let data = defaults.data(forKey: Key.legacySnippets),
              let oldList = try? JSONDecoder().decode([Snippet].self, from: data),
              !oldList.isEmpty else { return }

        // Legacy-сниппеты появились до типов — все были секретами, переносим как `.secret`.
        cache = oldList.map { StoredSnippet(id: $0.id, name: $0.name,
                                            value: keychain.value(for: $0.id) ?? "",
                                            kind: $0.kind, linkAction: $0.linkAction) }
        persist()
        oldList.forEach { keychain.delete($0.id) }       // подчищаем старые пер-ключевые записи
        defaults.removeObject(forKey: Key.legacySnippets)
    }
}

/// Тонкая обёртка над Keychain (generic password) для строковых значений по строковому
/// ключу. Один `service` на хранилище, `account` = ключ записи. ACL по умолчанию: доступ
/// только создавшему приложению (строгий) — система спросит доступ, если к записи
/// обратится другой/пере-подписанный бинарник. Поскольку читаем единый блоб лишь раз при
/// старте, такой запрос возможен максимум один раз за запуск.
public final class KeychainStore: SnippetSecretStore {

    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Записывает значение (создаёт или обновляет существующее).
    ///
    /// Сначала пробуем `SecItemUpdate`, и только если записи нет (`errSecItemNotFound`) —
    /// `SecItemAdd`. БЕЗ предварительного `SecItemCopyMatching`: у записи со строгим ACL
    /// каждое обращение к Keychain поднимает отдельный диалог доступа, поэтому лишняя проверка
    /// существования удваивала запрос (один на проверку, второй на саму запись). Теперь на
    /// обычном пути (запись уже есть) — ровно одно обращение, то есть максимум один диалог.
    public func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let base = baseQuery(for: account)
        var status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        // Тихая потеря записи в Keychain незаметна пользователю (сниппет «не сохранился»),
        // поэтому неуспех логируем, а не проглатываем.
        if status != errSecSuccess {
            NSLog("Hopkey: запись в Keychain не удалась (account=\(account), status=\(status))")
        }
    }

    /// Читает значение (nil, если записи нет или данные не строка UTF-8).
    public func value(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Удаляет запись (идемпотентно).
    public func delete(_ account: String) {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        // Отсутствие записи — норма (идемпотентность); прочие ошибки логируем.
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Hopkey: удаление из Keychain не удалось (account=\(account), status=\(status))")
        }
    }
}
