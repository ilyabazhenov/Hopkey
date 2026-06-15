import XCTest
import Carbon.HIToolbox
@testable import HopkeyCore

final class HotKeyFormatterTests: XCTestCase {

    // Модификаторы в Carbon-формате (для наглядности дублируем значения).
    private let control = UInt32(controlKey)   // 0x1000
    private let option = UInt32(optionKey)     // 0x0800
    private let shift = UInt32(shiftKey)       // 0x0200
    private let command = UInt32(cmdKey)       // 0x0100

    func testDefaultComboIsControlOptionJ() {
        // Дефолт приложения: keyCode 38 (J), модификаторы 6144 = control|option.
        XCTAssertEqual(hotKeyDisplayString(keyCode: 38, modifiers: 6144), "⌃⌥J")
    }

    func testCommandShiftF() {
        // Кейс из отладки: 768 = command|shift, keyCode 3 = F.
        // Порядок символов всегда каноничный ⌃⌥⇧⌘, поэтому ⇧ идёт перед ⌘.
        XCTAssertEqual(hotKeyDisplayString(keyCode: 3, modifiers: 768), "⇧⌘F")
    }

    func testModifierSymbolsCanonicalOrder() {
        // Порядок всегда ⌃⌥⇧⌘ независимо от порядка установки бит.
        XCTAssertEqual(carbonModifierSymbols(command | control | shift | option), "⌃⌥⇧⌘")
    }

    func testNoModifiers() {
        XCTAssertEqual(carbonModifierSymbols(0), "")
    }

    func testSingleModifiers() {
        XCTAssertEqual(carbonModifierSymbols(control), "⌃")
        XCTAssertEqual(carbonModifierSymbols(option), "⌥")
        XCTAssertEqual(carbonModifierSymbols(shift), "⇧")
        XCTAssertEqual(carbonModifierSymbols(command), "⌘")
    }

    func testKeyNameLettersAndDigits() {
        XCTAssertEqual(keyName(forKeyCode: UInt32(kVK_ANSI_J)), "J")
        XCTAssertEqual(keyName(forKeyCode: UInt32(kVK_ANSI_0)), "0")
    }

    func testKeyNameSpecialKeys() {
        XCTAssertEqual(keyName(forKeyCode: UInt32(kVK_Space)), "Space")
        XCTAssertEqual(keyName(forKeyCode: UInt32(kVK_Return)), "↩")
        XCTAssertEqual(keyName(forKeyCode: UInt32(kVK_F5)), "F5")
        XCTAssertEqual(keyName(forKeyCode: UInt32(kVK_LeftArrow)), "←")
    }

    func testKeyNameUnknownFallback() {
        // Неизвестный код — предсказуемый фолбэк, а не пустая строка.
        XCTAssertEqual(keyName(forKeyCode: 9999), "key9999")
    }

    func testFullStringCombinesModifiersAndKey() {
        XCTAssertEqual(hotKeyDisplayString(keyCode: UInt32(kVK_ANSI_K), modifiers: control | option), "⌃⌥K")
    }

    // MARK: - hotKeyLikelyConflicts

    func testRiskyWithoutControlOrOption() {
        // ⌘C, ⇧⌘Z, голое ⌘ — без ⌃/⌥ перехватывают сочетания приложений.
        XCTAssertTrue(hotKeyLikelyConflicts(modifiers: command))            // ⌘C
        XCTAssertTrue(hotKeyLikelyConflicts(modifiers: command | shift))    // ⇧⌘Z
        XCTAssertTrue(hotKeyLikelyConflicts(modifiers: shift))              // голый ⇧
    }

    func testSafeWithControlOrOption() {
        // Наличие ⌃ или ⌥ снимает предупреждение — рекомендуемые комбинации.
        XCTAssertFalse(hotKeyLikelyConflicts(modifiers: control | option))  // ⌃⌥ (дефолты)
        XCTAssertFalse(hotKeyLikelyConflicts(modifiers: control))           // ⌃
        XCTAssertFalse(hotKeyLikelyConflicts(modifiers: option))            // ⌥
        XCTAssertFalse(hotKeyLikelyConflicts(modifiers: control | command)) // ⌃⌘
    }

    func testNoModifiersNotFlagged() {
        // Пустые модификаторы рекордер не принимает — отдельным предупреждением не шумим.
        XCTAssertFalse(hotKeyLikelyConflicts(modifiers: 0))
    }
}
