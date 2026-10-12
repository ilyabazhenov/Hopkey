import AppKit

/// Отдаёт значение буфера по запросу и сообщает о первом чтении.
///
/// Вместо самой строки в буфер кладётся обещание (`NSPasteboardItemDataProvider`): macOS
/// просит у нас данные ровно тогда, когда какое-то приложение читает буфер, — то есть в момент
/// вставки. Так мы узнаём, что секрет вставили, и можем стереть его, не дожидаясь таймера.
/// После первой выдачи данные кешируются буфером, повторные чтения нас уже не зовут.
final class OneShotPasteProvider: NSObject, NSPasteboardItemDataProvider {
    private let value: String
    private let onFirstRead: () -> Void
    private var didProvide = false

    init(value: String, onFirstRead: @escaping () -> Void) {
        self.value = value
        self.onFirstRead = onFirstRead
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(value, forType: type)
        guard !didProvide else { return }
        didProvide = true
        DispatchQueue.main.async(execute: onFirstRead)
    }
}
