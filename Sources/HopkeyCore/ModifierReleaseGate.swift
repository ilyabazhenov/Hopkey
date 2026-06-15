import Foundation

/// Решает, КОГДА можно синтезировать клавишу-сочетание (Cmd+C / Cmd+V) после
/// срабатывания глобального хоткея.
///
/// Хоткей сам удерживает свои модификаторы (например, ⌃⌥) в момент срабатывания. Если
/// синтезировать Cmd+C прямо сейчас, система подмешает зажатые ⌃⌥ к синтетическому
/// событию → получится ⌃⌥⌘C вместо ⌘C, и «Копировать» не сработает (буфер не меняется).
/// Поэтому перед синтезом нужно дождаться отпускания модификаторов.
///
/// Логика чистая (без AppKit/Carbon/таймеров) и потому тестируется. Конкретные значения
/// битов модификаторов неважны — важно лишь «есть пересечение с отслеживаемыми или нет».
public struct ModifierReleaseGate {
    /// Маска отслеживаемых модификаторов (в терминах вызывающего). В проде — ⌃⌥⇧⌘
    /// из `CGEventFlags`. Caps Lock / Fn сюда НЕ входят, иначе ждали бы их отпускания зря.
    public let watched: UInt64
    /// Сколько раз опрашиваем состояние, прежде чем сдаться и действовать всё равно
    /// (страховка: пользователь может удерживать клавиши сколь угодно долго).
    public let maxAttempts: Int

    public init(watched: UInt64, maxAttempts: Int = 25) {
        self.watched = watched
        self.maxAttempts = maxAttempts
    }

    /// Пора ли действовать: все отслеживаемые модификаторы отпущены ИЛИ исчерпан лимит
    /// попыток. Иначе — ждать дальше.
    public func shouldProceed(modifiers: UInt64, attempt: Int) -> Bool {
        modifiers & watched == 0 || attempt >= maxAttempts
    }
}

/// Поллит состояние модификаторов через `ModifierReleaseGate` и вызывает действие, как
/// только их можно отпустить (или по таймауту). Источник флагов и планировщик задержки
/// внедряются: в проде — `CGEventSource.flagsState` и `DispatchQueue.main.asyncAfter`,
/// в тестах — фейки (синхронный планировщик + заранее заданная последовательность флагов).
public final class ModifierReleaseWaiter {
    private let gate: ModifierReleaseGate
    private let flags: () -> UInt64
    private let schedule: (@escaping () -> Void) -> Void

    public init(gate: ModifierReleaseGate,
                flags: @escaping () -> UInt64,
                schedule: @escaping (@escaping () -> Void) -> Void) {
        self.gate = gate
        self.flags = flags
        self.schedule = schedule
    }

    /// Вызывает `work` ровно один раз — как только отслеживаемые модификаторы отпущены
    /// либо исчерпан лимит попыток.
    public func wait(_ work: @escaping () -> Void) {
        poll(attempt: 0, work)
    }

    private func poll(attempt: Int, _ work: @escaping () -> Void) {
        if gate.shouldProceed(modifiers: flags(), attempt: attempt) {
            work()
        } else {
            schedule { [self] in poll(attempt: attempt + 1, work) }
        }
    }
}
