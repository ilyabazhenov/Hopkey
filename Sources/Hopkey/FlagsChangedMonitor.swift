import AppKit
import HopkeyCore

/// Пассивный глобальный монитор нажатий модификаторов — кормит `DoubleTapDetector` для вызова
/// панели двойным тапом правого ⌘/⌥. `.flagsChanged` даёт нажатия/отпускания модификаторов,
/// `.keyDown` — сигнал «нажата другая клавиша» (срывает жест). Требует Accessibility (как хоткеи).
///
/// Монитор пассивный (не «съедает» событие), но двойной тап правого модификатора сам по себе
/// ничего в системе не делает, поэтому гасить нечего.
final class FlagsChangedMonitor {

    private var monitor: Any?
    /// Локальный монитор — ловит события, когда ключевое окно наше (открытая панель), чтобы
    /// двойной тап при открытой панели закрывал её (глобальный монитор наши события не видит).
    private var localMonitor: Any?
    private let detector: DoubleTapDetector
    /// Направление (нажат/отпущен) считаем по keyCode, а не по общему биту флага —
    /// иначе отпускание правого модификатора при зажатом левом читалось бы как нажатие.
    private let tracker = ModifierKeyTracker()

    init(detector: DoubleTapDetector) {
        self.detector = detector
    }

    func start() {
        guard monitor == nil else { return }
        tracker.reset()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event  // не поглощаем — окно продолжает получать событие
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        tracker.reset()
    }

    /// Сбрасывает состояние жеста (трекер модификаторов + детектор). Нужно вокруг показа панели:
    /// пока панель — ключевое окно, глобальный монитор НЕ видит события нашего приложения,
    /// поэтому отпускание клавиши, завершившей жест, теряется и трекер остаётся рассинхронным
    /// («зажатый» правый ⌘). Без сброса следующий двойной тап сразу после закрытия не срабатывает.
    func resetGesture() {
        tracker.reset()
        detector.reset()
    }

    deinit { stop() }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            detector.handleOtherKey()
        case .flagsChanged:
            let keyCode = Int(event.keyCode)
            guard let bit = flagBit(for: keyCode) else {
                // Не отслеживаемый модификатор (Caps Lock, Fn) — считаем посторонней активностью.
                detector.handleOtherKey()
                return
            }
            let isDown = tracker.update(keyCode: keyCode, bitSet: event.modifierFlags.contains(bit))
            detector.handleModifier(keyCode: keyCode, isDown: isDown, at: event.timestamp)
        default:
            break
        }
    }

    /// Общий бит флага для keyCode модификатора (левый/правый вариант делят один бит).
    private func flagBit(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default: return nil
        }
    }
}
