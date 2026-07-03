import Foundation

/// Распознаёт двойной тап по одной целевой модификаторной клавише (например, правому ⌘)
/// для вызова панели команд. Чистая state-machine без зависимостей от AppKit: время и
/// события инжектируются, поэтому логика полностью под юнит-тестами (как `ModifierReleaseGate`).
///
/// «Тап» = быстрое нажатие-отпускание целевой клавиши без удержания. «Двойной тап» = два
/// таких тапа подряд, где второе нажатие пришло не позже `maxGap` после первого. Любая другая
/// клавиша/модификатор между ними срывает жест — так двойной тап не путается с обычной работой.
public final class DoubleTapDetector {

    /// Срабатывание двойного тапа.
    public var onTrigger: (() -> Void)?

    private let targetKeyCode: Int
    /// Максимальная длительность одиночного тапа (дольше — это удержание, не тап).
    private let maxTapDuration: TimeInterval
    /// Максимальный разрыв между первым и вторым нажатием.
    private let maxGap: TimeInterval

    private enum State {
        case idle
        /// Целевая клавиша нажата, ждём отпускания.
        case firstDown(downAt: TimeInterval)
        /// Один чистый тап завершён; `upAt` — время ОТПУСКАНИЯ (от него меряем паузу до второго
        /// нажатия). Пауза от отпускания, а не от нажатия — так жест не обязан целиком уложиться
        /// в узкое окно, и двойной тап не приходится «выстукивать» очень быстро.
        case firstTapped(upAt: TimeInterval)
    }
    private var state: State = .idle

    public init(targetKeyCode: Int,
                maxTapDuration: TimeInterval = 0.35,
                maxGap: TimeInterval = 0.40) {
        self.targetKeyCode = targetKeyCode
        self.maxTapDuration = maxTapDuration
        self.maxGap = maxGap
    }

    /// Событие модификатора. `keyCode` — код конкретной клавиши (левый/правый различаются).
    /// Любой НЕ целевой модификатор сбрасывает жест.
    public func handleModifier(keyCode: Int, isDown: Bool, at time: TimeInterval) {
        guard keyCode == targetKeyCode else {
            state = .idle
            return
        }
        if isDown {
            handleDown(at: time)
        } else {
            handleUp(at: time)
        }
    }

    /// Нажата любая обычная (не модификаторная) клавиша — жест сорван.
    public func handleOtherKey() {
        state = .idle
    }

    /// Сброс (например, при отключении/переключении триггера).
    public func reset() {
        state = .idle
    }

    private func handleDown(at time: TimeInterval) {
        if case .firstTapped(let upAt) = state, time - upAt <= maxGap {
            state = .idle
            onTrigger?()
        } else {
            state = .firstDown(downAt: time)
        }
    }

    private func handleUp(at time: TimeInterval) {
        if case .firstDown(let downAt) = state, time - downAt <= maxTapDuration {
            state = .firstTapped(upAt: time)
        } else {
            state = .idle
        }
    }
}
