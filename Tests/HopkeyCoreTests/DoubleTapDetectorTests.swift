import XCTest
@testable import HopkeyCore

final class DoubleTapDetectorTests: XCTestCase {

    private let target = 54  // правый ⌘

    private func makeDetector() -> (DoubleTapDetector, () -> Int) {
        let detector = DoubleTapDetector(targetKeyCode: target)
        var count = 0
        detector.onTrigger = { count += 1 }
        return (detector, { count })
    }

    /// Быстрый down-up-down по целевой клавише → срабатывание ровно один раз.
    func testFiresOnCleanDoubleTap() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: target, isDown: true, at: 0.00)
        d.handleModifier(keyCode: target, isDown: false, at: 0.04)
        d.handleModifier(keyCode: target, isDown: true, at: 0.18)
        XCTAssertEqual(count(), 1)
    }

    /// Второе нажатие позже `maxGap` — не двойной тап; но становится новым «первым».
    func testNoFireWhenGapTooLong() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: target, isDown: true, at: 0.00)
        d.handleModifier(keyCode: target, isDown: false, at: 0.04)
        d.handleModifier(keyCode: target, isDown: true, at: 0.50)  // gap > 0.30
        XCTAssertEqual(count(), 0)

        // Продолжение — уже как новый жест — срабатывает.
        d.handleModifier(keyCode: target, isDown: false, at: 0.54)
        d.handleModifier(keyCode: target, isDown: true, at: 0.66)
        XCTAssertEqual(count(), 1)
    }

    /// Удержание (долгое нажатие) не считается тапом — двойной клик из него не рождается.
    func testHoldIsNotATap() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: target, isDown: true, at: 0.00)
        d.handleModifier(keyCode: target, isDown: false, at: 0.40)  // удержание > maxTapDuration
        d.handleModifier(keyCode: target, isDown: true, at: 0.45)   // только «первый» тап
        XCTAssertEqual(count(), 0)
    }

    /// Обычная клавиша между тапами срывает жест.
    func testOtherKeyResets() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: target, isDown: true, at: 0.00)
        d.handleModifier(keyCode: target, isDown: false, at: 0.04)
        d.handleOtherKey()
        d.handleModifier(keyCode: target, isDown: true, at: 0.10)
        XCTAssertEqual(count(), 0)
    }

    /// Чужой модификатор между тапами срывает жест.
    func testForeignModifierResets() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: target, isDown: true, at: 0.00)
        d.handleModifier(keyCode: target, isDown: false, at: 0.04)
        d.handleModifier(keyCode: 56, isDown: true, at: 0.08)  // левый Shift
        d.handleModifier(keyCode: target, isDown: true, at: 0.14)
        XCTAssertEqual(count(), 0)
    }

    /// Чужой keycode в простое не мешает последующему честному двойному тапу.
    func testForeignModifierWhenIdleIsHarmless() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: 61, isDown: true, at: 0.00)   // правый ⌥ — не цель
        d.handleModifier(keyCode: 61, isDown: false, at: 0.03)
        d.handleModifier(keyCode: target, isDown: true, at: 0.10)
        d.handleModifier(keyCode: target, isDown: false, at: 0.14)
        d.handleModifier(keyCode: target, isDown: true, at: 0.26)
        XCTAssertEqual(count(), 1)
    }

    /// Тройной тап не даёт двойного срабатывания.
    func testTripleTapFiresOnce() {
        let (d, count) = makeDetector()
        d.handleModifier(keyCode: target, isDown: true, at: 0.00)
        d.handleModifier(keyCode: target, isDown: false, at: 0.04)
        d.handleModifier(keyCode: target, isDown: true, at: 0.16)   // fire
        d.handleModifier(keyCode: target, isDown: false, at: 0.20)
        d.handleModifier(keyCode: target, isDown: true, at: 0.30)   // новый «первый», не fire
        XCTAssertEqual(count(), 1)
    }
}
