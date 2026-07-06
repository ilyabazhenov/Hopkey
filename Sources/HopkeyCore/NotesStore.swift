import Foundation

/// Хранилище «заметок-точек» — семь постоянных черновиков в идиоме Tot (семь цветных слотов).
/// В отличие от сниппетов (секреты в Keychain одним блобом, см. `SnippetStore`) заметки —
/// обычный текст, поэтому лежат простыми файлами `dot1.md … dot7.md` в Application Support.
/// Побочный бонус: если пользователь положит эту папку в iCloud Drive/Dropbox, заметки
/// «синхронизируются» между машинами без iCloud-энтайтлментов (недоступных self-signed сборке).
///
/// Значения держим в памяти (читаются один раз при инициализации), запись на диск — по явному
/// `persist`. UI дебаунсит запись (по паузе в наборе, при переключении точки и закрытии окна),
/// поэтому файловый I/O здесь синхронный и намеренно простой.
public final class NotesStore {

    /// Число точек фиксировано, как семь дотов Tot — ни папок, ни добавления восьмой.
    public static let count = 7

    /// Общий экземпляр для приложения (директория по умолчанию — Application Support).
    public static let shared = NotesStore()

    /// Куда пишем файлы точек. Инъекция нужна тестам (временная директория).
    private let directory: URL
    /// Текст каждой точки в памяти (индексы 0…count-1). Правки UI идут сюда, на диск — по `persist`.
    private var texts: [String]
    /// Правки идут с главного потока (UI), но замок дёшев и убирает класс гонок на будущее.
    private let lock = NSLock()

    /// - Parameter directory: каталог файлов точек; `nil` — стандартный Application Support/Hopkey/notes.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.texts = Array(repeating: "", count: Self.count)
        loadAll()
    }

    /// `Application Support/Hopkey/notes` в домашней директории пользователя. Fallback на temp —
    /// чтобы отсутствие Application Support (экзотика) не роняло инициализацию.
    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Hopkey", isDirectory: true)
                   .appendingPathComponent("notes", isDirectory: true)
    }

    /// Файл точки по индексу: `dot1.md … dot7.md` (человекочитаемо, номер = номер точки).
    private func fileURL(for index: Int) -> URL {
        directory.appendingPathComponent("dot\(index + 1).md", isDirectory: false)
    }

    /// Валиден ли индекс точки.
    private func isValid(_ index: Int) -> Bool { index >= 0 && index < Self.count }

    /// Читает все существующие файлы точек в память. Отсутствующий файл — пустая точка (не ошибка).
    private func loadAll() {
        for index in 0..<Self.count {
            if let text = try? String(contentsOf: fileURL(for: index), encoding: .utf8) {
                texts[index] = text
            }
        }
    }

    /// Текст точки по индексу (пусто для несуществующего индекса — вызывающему не нужно проверять).
    public func text(at index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard isValid(index) else { return "" }
        return texts[index]
    }

    /// Обновляет текст точки в памяти (без записи на диск — её делает `persist`). Так UI может
    /// звать это на каждое нажатие клавиши, а на диск сбрасывать по паузе/переключению/закрытию.
    public func update(_ text: String, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard isValid(index) else { return }
        texts[index] = text
    }

    /// Пуста ли точка (после обрезки пробелов) — для бледной отрисовки «пустых» точек в UI.
    public func isEmpty(at index: Int) -> Bool {
        text(at: index).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Однострочный предпросмотр точки для списков/подписей: первая непустая строка, обрезанная
    /// по длине. Пусто — если точка пустая. Логика в ядре, чтобы покрыть тестом без UI.
    public func preview(at index: Int, maxLength: Int = 60) -> String {
        let text = self.text(at: index)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "…" : trimmed
    }

    /// Сбрасывает текст точки на диск (создавая каталог при необходимости). Ошибки записи глушим:
    /// заметка это не критичные к потере данные, и падать из-за них смысла нет.
    @discardableResult
    public func persist(at index: Int) -> Bool {
        guard isValid(index) else { return false }
        let text = self.text(at: index)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: fileURL(for: index), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Сбрасывает все точки на диск (например, при завершении приложения).
    public func persistAll() {
        for index in 0..<Self.count { persist(at: index) }
    }
}
