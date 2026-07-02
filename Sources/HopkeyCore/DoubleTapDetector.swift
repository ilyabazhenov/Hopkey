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
        /// Один чистый тап завершён; `downAt` — время его нажатия (от него меряем `maxGap`).
        case firstTapped(downAt: TimeInterval)
    }
    private var state: State = .idle

    public init(targetKeyCode: Int,
                maxTapDuration: TimeInterval = 0.25,
                maxGap: TimeInterval = 0.30) {
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
        if case .firstTapped(let downAt) = state, time - downAt <= maxGap {
            state = .idle
            onTrigger?()
        } else {
            state = .firstDown(downAt: time)
        }
    }

    private func handleUp(at time: TimeInterval) {
        if case .firstDown(let downAt) = state, time - downAt <= maxTapDuration {
            state = .firstTapped(downAt: downAt)
        } else {
            state = .idle
        }
    }
}
