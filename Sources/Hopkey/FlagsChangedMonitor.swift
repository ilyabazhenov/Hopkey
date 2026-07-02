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
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tracker.reset()
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
