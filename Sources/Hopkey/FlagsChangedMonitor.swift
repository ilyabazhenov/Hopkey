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

    init(detector: DoubleTapDetector) {
        self.detector = detector
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            detector.handleOtherKey()
        case .flagsChanged:
            let keyCode = Int(event.keyCode)
            detector.handleModifier(keyCode: keyCode,
                                    isDown: modifierIsDown(keyCode: keyCode, flags: event.modifierFlags),
                                    at: event.timestamp)
        default:
            break
        }
    }

    /// В `.flagsChanged` нет явного «нажата/отпущена» — выводим по наличию флага того модификатора,
    /// к которому относится клавиша (левый/правый вариант делят один флаг, но разные keyCode).
    private func modifierIsDown(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        default: return false
        }
    }
}
