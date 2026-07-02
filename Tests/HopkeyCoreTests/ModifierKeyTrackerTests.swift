import XCTest
@testable import HopkeyCore

final class ModifierKeyTrackerTests: XCTestCase {

    private let rightCommand = 54
    private let leftCommand = 55

    func testSimpleDownUp() {
        let t = ModifierKeyTracker()
        XCTAssertTrue(t.update(keyCode: rightCommand, bitSet: true))   // нажат
        XCTAssertFalse(t.update(keyCode: rightCommand, bitSet: false)) // отпущен (бит сброшен)
    }

    /// Ключевой сценарий регресса: держим левый ⌘ и дважды тапаем правый.
    /// Отпускание правого приходит с ВЫСТАВЛЕННЫМ битом (левый ещё зажат) — раньше это
    /// ошибочно читалось как нажатие, и двойной тап не завершался.
    func testRightReleaseWhileLeftHeldIsUp() {
        let t = ModifierKeyTracker()
        XCTAssertTrue(t.update(keyCode: leftCommand, bitSet: true))    // левый вниз
        XCTAssertTrue(t.update(keyCode: rightCommand, bitSet: true))   // правый вниз
        XCTAssertFalse(t.update(keyCode: rightCommand, bitSet: true))  // правый ВВЕРХ (бит держит левый)
        XCTAssertTrue(t.update(keyCode: rightCommand, bitSet: true))   // правый снова вниз
        XCTAssertFalse(t.update(keyCode: rightCommand, bitSet: true))  // правый снова вверх
        XCTAssertFalse(t.update(keyCode: leftCommand, bitSet: false))  // левый вверх (бит сброшен)
    }

    func testBitClearForcesUp() {
        let t = ModifierKeyTracker()
        _ = t.update(keyCode: rightCommand, bitSet: true)
        // Даже если пропустили промежуточное событие, сброшенный бит = отпущено.
        XCTAssertFalse(t.update(keyCode: rightCommand, bitSet: false))
        // После этого следующее выставление бита — снова нажатие.
        XCTAssertTrue(t.update(keyCode: rightCommand, bitSet: true))
    }

    func testResetClearsState() {
        let t = ModifierKeyTracker()
        _ = t.update(keyCode: rightCommand, bitSet: true)  // down
        t.reset()
        // После сброса первое событие с выставленным битом снова считается нажатием.
        XCTAssertTrue(t.update(keyCode: rightCommand, bitSet: true))
    }
}
