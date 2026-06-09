import AppKit

/// Следит за буфером обмена через опрос `NSPasteboard.changeCount`.
/// Не требует никаких разрешений.
final class ClipboardWatcher {

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    /// Вызывается, когда в буфер попал новый текст.
    var onChange: ((String) -> Void)?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common — чтобы таймер не вставал во время взаимодействия с меню.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Синхронизировать счётчик без срабатывания (например, после программной записи в буфер).
    func syncChangeCount() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onChange?(text)
        }
    }
}
