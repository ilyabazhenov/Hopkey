import XCTest
@testable import HopkeyCore

/// Защищает поведение, из-за отсутствия которого подстановка выделения молча ломалась:
/// синтетический Cmd+C нельзя слать, пока зажаты модификаторы хоткея (⌃⌥), — иначе
/// получается ⌃⌥⌘C и «Копировать» не срабатывает. Здесь проверяется чистая логика
/// ожидания их отпускания (конкретные значения битов неважны — берём произвольные).
final class ModifierReleaseGateTests: XCTestCase {

    private let control: UInt64 = 1 << 0
    private let option: UInt64 = 1 << 1
    private let command: UInt64 = 1 << 2
    private let shift: UInt64 = 1 << 3
    private let capsLock: UInt64 = 1 << 8   // намеренно НЕ в watched
    private var watched: UInt64 { control | option | command | shift }

    // MARK: - Gate (чистое решение)

    func testProceedsWhenNothingHeld() {
        let gate = ModifierReleaseGate(watched: watched, maxAttempts: 25)
        XCTAssertTrue(gate.shouldProceed(modifiers: 0, attempt: 0))
    }

    func testWaitsWhileWatchedModifierHeld() {
        let gate = ModifierReleaseGate(watched: watched, maxAttempts: 25)
        XCTAssertFalse(gate.shouldProceed(modifiers: control, attempt: 0))
        XCTAssertFalse(gate.shouldProceed(modifiers: control | option, attempt: 10))
        XCTAssertFalse(gate.shouldProceed(modifiers: command, attempt: 24))
    }

    func testProceedsAtMaxAttemptsEvenIfHeld() {
        // Страховка: пользователь держит клавиши — по таймауту всё равно действуем.
        let gate = ModifierReleaseGate(watched: watched, maxAttempts: 25)
        XCTAssertTrue(gate.shouldProceed(modifiers: control, attempt: 25))
        XCTAssertTrue(gate.shouldProceed(modifiers: control | option, attempt: 99))
    }

    func testUnwatchedModifierDoesNotBlock() {
        // Caps Lock / Fn не отслеживаем — они не должны заставлять ждать.
        let gate = ModifierReleaseGate(watched: watched, maxAttempts: 25)
        XCTAssertTrue(gate.shouldProceed(modifiers: capsLock, attempt: 0))
    }

    // MARK: - Waiter (поллинг с внедрёнными зависимостями)

    func testWaiterFiresOnlyAfterModifiersRelease() {
        // Модификаторы зажаты на первых трёх опросах, на четвёртом — отпущены.
        let sequence = [control, control, control, 0, 0]
        var index = 0
        let flags: () -> UInt64 = {
            defer { index += 1 }
            return sequence[min(index, sequence.count - 1)]
        }
        var scheduled = 0
        let schedule: (@escaping () -> Void) -> Void = { work in
            scheduled += 1
            work()   // синхронно — как будто задержка прошла мгновенно
        }
        let waiter = ModifierReleaseWaiter(
            gate: ModifierReleaseGate(watched: watched, maxAttempts: 25),
            flags: flags, schedule: schedule)

        var fired = 0
        waiter.wait { fired += 1 }

        XCTAssertEqual(fired, 1, "действие должно сработать ровно один раз")
        XCTAssertEqual(scheduled, 3, "ровно три ожидания до отпускания модификаторов")
    }

    func testWaiterGivesUpAfterMaxAttemptsIfNeverReleased() {
        let flags: () -> UInt64 = { self.control }   // держим всегда
        var scheduled = 0
        let schedule: (@escaping () -> Void) -> Void = { work in
            scheduled += 1
            work()
        }
        let waiter = ModifierReleaseWaiter(
            gate: ModifierReleaseGate(watched: watched, maxAttempts: 5),
            flags: flags, schedule: schedule)

        var fired = 0
        waiter.wait { fired += 1 }

        XCTAssertEqual(fired, 1, "по таймауту всё равно срабатываем один раз")
        XCTAssertEqual(scheduled, 5, "ровно maxAttempts ожиданий")
    }

    func testWaiterFiresImmediatelyWhenAlreadyClear() {
        let flags: () -> UInt64 = { 0 }
        var scheduled = 0
        let waiter = ModifierReleaseWaiter(
            gate: ModifierReleaseGate(watched: watched, maxAttempts: 25),
            flags: flags, schedule: { _ in scheduled += 1 })

        var fired = 0
        waiter.wait { fired += 1 }

        XCTAssertEqual(fired, 1)
        XCTAssertEqual(scheduled, 0, "если модификаторы уже отпущены — без ожиданий")
    }
}
