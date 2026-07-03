import Foundation

/// История буфера обмена: кольцо последних скопированных текстов для быстрой повторной вставки.
///
/// Только в памяти — на диск не пишем (в приложении и так строго с секретами). «Скрытые» копии
/// (пароль-менеджеры помечают буфер `org.nspasteboard.ConcealedType`) сюда не попадают — фильтрует
/// вызывающий перед `record`. Дубликаты «всплывают» наверх, а не плодятся.
public final class ClipboardHistory {

    private(set) public var entries: [String] = []
    private let capacity: Int

    public init(capacity: Int = 15) {
        self.capacity = max(1, capacity)
    }

    /// Добавляет текст в начало. Пустой/пробельный игнорируется. Повтор — перемещается наверх
    /// (без дубля). Хвост сверх ёмкости отбрасывается.
    public func record(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0 == text }
        entries.insert(text, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    public func clear() {
        entries.removeAll()
    }
}
