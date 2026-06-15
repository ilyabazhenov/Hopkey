import Foundation
import Security

/// Сниппет — заранее заданное значение для быстрой вставки (пароль, ссылка на комнату
/// и т.п.). Публичный тип для UI несёт только id и имя; само значение хранится отдельно
/// (см. `SnippetStore`) и наружу отдаётся лишь по явному запросу `value(for:)`.
public struct Snippet: Codable, Equatable {
    /// Стабильный идентификатор (UUID-строкой).
    public var id: String
    /// Видимое имя в списке пикера и настроек.
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    /// Имя для показа: непустое `name`, иначе плейсхолдер «без имени».
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}

/// Внутренняя запись с самим значением — из неё собирается единый JSON-блоб в Keychain.
private struct StoredSnippet: Codable {
    var id: String
    var name: String
    var value: String
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
        return cache.map { Snippet(id: $0.id, name: $0.name) }
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
        let record = StoredSnippet(id: snippet.id, name: snippet.name, value: value)
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

        cache = oldList.map { StoredSnippet(id: $0.id, name: $0.name,
                                            value: keychain.value(for: $0.id) ?? "") }
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
    public func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let base = baseQuery(for: account)
        let status: OSStatus
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
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
