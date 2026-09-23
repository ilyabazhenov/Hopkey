import Foundation

/// Вид записи истории буфера.
public enum ClipboardKind: String, Codable {
    case text
    case image
}

/// Ссылка на картинку в истории: сами байты (PNG) лежат отдельным зашифрованным файлом
/// `img-<uuid>.enc`, здесь — только имя файла и метаданные для показа/лимитов.
public struct ClipboardImageRef: Equatable {
    /// Имя файла на диске (`img-<uuid>.enc`).
    public let file: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Размер расшифрованного PNG в байтах.
    public let byteSize: Int
}

/// Приложение-источник копии: где пользователь что-то скопировал. Ловится в app-слое из
/// `NSWorkspace.frontmostApplication` в момент детекта. Оба поля опциональны (фронтом мог
/// быть не-GUI процесс).
public struct ClipboardSource: Equatable {
    /// Локализованное имя приложения (для показа).
    public let appName: String?
    /// Bundle id (стабильный ключ; на будущее — иконка/фильтр).
    public let bundleID: String?

    public init(appName: String?, bundleID: String?) {
        self.appName = appName
        self.bundleID = bundleID
    }
}

/// Публичная запись истории для UI: контент (текст / ссылка на картинку) + метаданные
/// (когда добавлена, из какого приложения). Байты картинки достаются по запросу через
/// `ClipboardHistory.imageData(for:)` (в память все картинки не поднимаем — только когда
/// пользователь открыл список / вставляет).
public struct ClipboardEntry: Equatable {
    public enum Content: Equatable {
        case text(String)
        case image(ClipboardImageRef)
    }

    /// Стабильный идентификатор записи (для точечного удаления).
    public let id: String
    public let content: Content
    /// Когда запись добавлена в историю.
    public let createdAt: Date
    /// Приложение, из которого скопировали (nil — неизвестно/программная копия).
    public let source: ClipboardSource?
}

/// История буфера обмена: кольцо последних копий (текст + картинки) для быстрой повторной
/// вставки. В отличие от прежней in-memory версии — **персистентна и зашифрована**:
///
/// - Ключ (256 бит) хранится ОДНОЙ записью в Keychain (строгий ACL, читается один раз за
///   запуск — как блоб `SnippetStore`); при первом запуске генерируется.
/// - `manifest.enc` — зашифрованный JSON со списком записей (текст inline, картинки — ссылками).
///   Мал, переписывается на каждое изменение.
/// - `img-<uuid>.enc` — каждая картинка отдельным зашифрованным файлом, пишется однократно и
///   удаляется при вытеснении из кольца.
///
/// «Скрытые» копии (пароль-менеджеры помечают буфер `org.nspasteboard.ConcealedType`) сюда не
/// попадают — фильтрует вызывающий перед `record`. Дубликаты «всплывают» наверх, а не плодятся
/// (текст — по строке, картинки — по SHA-256 контента).
public final class ClipboardHistory {

    /// Запись на диске (в `manifest.enc`). Для текста заполнен `text`, для картинки —
    /// `imageFile`/размеры/`hash`. Опциональные поля с `decodeIfPresent` — на будущее, чтобы
    /// добавление полей не роняло декод старого манифеста.
    private struct StoredEntry: Codable {
        var id: String
        var kind: ClipboardKind
        var text: String?
        var imageFile: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var byteSize: Int?
        /// SHA-256 контента картинки (hex) — для dedup без расшифровки файлов.
        var hash: String?
        /// Когда добавлена запись.
        var createdAt: Date
        /// Имя и bundle id приложения-источника.
        var appName: String?
        var appBundleID: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(ClipboardKind.self, forKey: .kind)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
            pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
            pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
            byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize)
            hash = try c.decodeIfPresent(String.self, forKey: .hash)
            // createdAt появился позже — у записи без него берём эпоху (не роняем декод).
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            appName = try c.decodeIfPresent(String.self, forKey: .appName)
            appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        }

        init(id: String, kind: ClipboardKind, text: String? = nil, imageFile: String? = nil,
             pixelWidth: Int? = nil, pixelHeight: Int? = nil, byteSize: Int? = nil, hash: String? = nil,
             createdAt: Date, appName: String? = nil, appBundleID: String? = nil) {
            self.id = id; self.kind = kind; self.text = text; self.imageFile = imageFile
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            self.byteSize = byteSize; self.hash = hash
            self.createdAt = createdAt; self.appName = appName; self.appBundleID = appBundleID
        }
    }

    private let capacity: Int
    private let maxImageBytes: Int
    private let directory: URL
    private let keyStore: SnippetSecretStore
    /// Источник времени для «даты добавления» — инъекция ради детерминизма тестов.
    private let clock: () -> Date

    /// Снимок истории в памяти (источник правды после загрузки). Правки идут и с UI-потока,
    /// и с фонового опроса буфера — сериализуем замком (как `SnippetStore`).
    private var stored: [StoredEntry] = []
    private var crypto: ClipboardCrypto?
    private var loaded = false
    private let lock = NSLock()

    /// Единственная запись ключа в Keychain.
    private static let keyAccount = "key"

    /// - Parameters:
    ///   - directory: каталог файлов истории; `nil` — Application Support/Hopkey/clipboard.
    ///   - keyStore: где лежит ключ шифрования; на проде Keychain, в тестах — in-memory.
    public init(capacity: Int = 100,
                maxImageBytes: Int = 16 * 1024 * 1024,
                directory: URL? = nil,
                keyStore: SnippetSecretStore = KeychainStore(service: "Hopkey Clipboard"),
                clock: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.maxImageBytes = maxImageBytes
        self.directory = directory ?? Self.defaultDirectory()
        self.keyStore = keyStore
        self.clock = clock
    }

    /// `Application Support/Hopkey/clipboard`. Fallback на temp — чтобы отсутствие Application
    /// Support не роняло инициализацию (как в `NotesStore`).
    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Hopkey", isDirectory: true)
                   .appendingPathComponent("clipboard", isDirectory: true)
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("manifest.enc", isDirectory: false)
    }

    private func imageURL(_ file: String) -> URL {
        directory.appendingPathComponent(file, isDirectory: false)
    }

    // MARK: - Публичный API

    /// Загружает ключ и манифест в память + подчищает осиротевшие файлы (идемпотентно).
    /// Можно не звать — загрузка ленивая при первом обращении, чтобы запрос доступа к Keychain
    /// появлялся не на старте, а когда история реально понадобилась (первая копия/открытие списка).
    public func prepare() { lock.lock(); defer { lock.unlock() }; ensureLoaded() }

    /// Текущие записи истории (новые сверху). При первом обращении лениво грузит из Keychain/диска.
    public var entries: [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return stored.map { s in
            let content: ClipboardEntry.Content
            if s.kind == .image, let file = s.imageFile {
                content = .image(ClipboardImageRef(file: file,
                                                   pixelWidth: s.pixelWidth ?? 0,
                                                   pixelHeight: s.pixelHeight ?? 0,
                                                   byteSize: s.byteSize ?? 0))
            } else {
                content = .text(s.text ?? "")
            }
            let source = (s.appName != nil || s.appBundleID != nil)
                ? ClipboardSource(appName: s.appName, bundleID: s.appBundleID) : nil
            return ClipboardEntry(id: s.id, content: content, createdAt: s.createdAt, source: source)
        }
    }

    /// Удаляет одну запись по идентификатору (для точечного удаления из списка). Файл картинки,
    /// если он был, тоже удаляется. Отсутствующий id — no-op.
    public func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard let idx = stored.firstIndex(where: { $0.id == id }) else { return }
        let entry = stored.remove(at: idx)
        if let f = entry.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        persistManifestLocked()
    }

    /// Добавляет текст в начало. Пустой/пробельный игнорируется. Повтор — наверх (без дубля),
    /// с обновлением даты/источника на свежую копию.
    public func record(_ text: String, source: ClipboardSource? = nil) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stored.removeAll { $0.kind == .text && $0.text == text }
        stored.insert(StoredEntry(id: UUID().uuidString, kind: .text, text: text,
                                  createdAt: clock(), appName: source?.appName,
                                  appBundleID: source?.bundleID), at: 0)
        trimLocked()
        persistManifestLocked()
    }

    /// Добавляет картинку (PNG-байты) в начало. Пустая или крупнее лимита — игнорируется.
    /// Повтор того же контента (по SHA-256) — всплывает наверх без второго файла, с обновлением
    /// даты/источника на свежую копию.
    public func record(imagePNG png: Data, pixelWidth: Int, pixelHeight: Int, source: ClipboardSource? = nil) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard !png.isEmpty, png.count <= maxImageBytes, let crypto else { return }

        let hash = ClipboardCrypto.sha256Hex(png)
        if let idx = stored.firstIndex(where: { $0.kind == .image && $0.hash == hash }) {
            var existing = stored.remove(at: idx)
            existing.createdAt = clock()
            existing.appName = source?.appName
            existing.appBundleID = source?.bundleID
            stored.insert(existing, at: 0)
            trimLocked()
            persistManifestLocked()
            return
        }

        let file = "img-\(UUID().uuidString).enc"
        do {
            let ciphertext = try crypto.seal(png)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ciphertext.write(to: imageURL(file), options: .atomic)
        } catch {
            NSLog("Hopkey: не удалось зашифровать картинку истории буфера: \(error)")
            return
        }
        stored.insert(StoredEntry(id: UUID().uuidString, kind: .image, imageFile: file,
                                  pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                  byteSize: png.count, hash: hash, createdAt: clock(),
                                  appName: source?.appName, appBundleID: source?.bundleID), at: 0)
        trimLocked()
        persistManifestLocked()
    }

    /// Расшифровывает и отдаёт PNG-байты картинки по ссылке (для показа миниатюры/вставки).
    /// `nil`, если файла нет или он не расшифровался.
    public func imageData(for ref: ClipboardImageRef) -> Data? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard let crypto,
              let ciphertext = try? Data(contentsOf: imageURL(ref.file)) else { return nil }
        return try? crypto.open(ciphertext)
    }

    /// Полностью очищает историю: манифест, все файлы картинок и кэш.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        for entry in stored { if let f = entry.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) } }
        stored.removeAll()
        try? FileManager.default.removeItem(at: manifestURL)
    }

    // MARK: - Внутреннее (вызывается под замком)

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        setupCrypto()
        loadManifest()
        collectGarbage()
    }

    /// Читает ключ из Keychain (единственное место, где возможен запрос доступа). Нет записи —
    /// первый запуск: генерируем ключ и сохраняем.
    private func setupCrypto() {
        if let b64 = keyStore.value(for: Self.keyAccount), let key = ClipboardCrypto.key(fromBase64: b64) {
            crypto = ClipboardCrypto(key: key)
        } else {
            let key = ClipboardCrypto.generateKey()
            keyStore.set(ClipboardCrypto.base64(of: key), for: Self.keyAccount)
            crypto = ClipboardCrypto(key: key)
        }
    }

    private func loadManifest() {
        // Файла нет — штатный первый запуск (пустая история, не ошибка).
        guard let crypto, let ciphertext = try? Data(contentsOf: manifestURL) else { stored = []; return }
        do {
            let plain = try crypto.open(ciphertext)
            stored = try JSONDecoder().decode([StoredEntry].self, from: plain)
        } catch {
            // Манифест есть, но не читается (битый/ключ сменился) — логируем и стартуем пустыми,
            // а не роняем приложение.
            NSLog("Hopkey: не удалось расшифровать/декодировать историю буфера: \(error)")
            stored = []
        }
    }

    /// Удаляет `img-*.enc`, на которые манифест не ссылается (осиротевшие после сбоя между
    /// записью файла картинки и манифеста).
    private func collectGarbage() {
        let referenced = Set(stored.compactMap { $0.imageFile })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for f in files where f.hasPrefix("img-") && f.hasSuffix(".enc") && !referenced.contains(f) {
            try? FileManager.default.removeItem(at: imageURL(f))
        }
    }

    /// Отбрасывает хвост сверх ёмкости, удаляя файлы вытесненных картинок.
    private func trimLocked() {
        guard stored.count > capacity else { return }
        for entry in stored[capacity...] {
            if let f = entry.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        }
        stored.removeLast(stored.count - capacity)
    }

    private func persistManifestLocked() {
        guard let crypto else { return }
        do {
            let plain = try JSONEncoder().encode(stored)
            let ciphertext = try crypto.seal(plain)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ciphertext.write(to: manifestURL, options: .atomic)
        } catch {
            NSLog("Hopkey: не удалось сохранить историю буфера: \(error)")
        }
    }
}
