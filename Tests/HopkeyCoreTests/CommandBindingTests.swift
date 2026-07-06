import XCTest
@testable import HopkeyCore

final class CommandBindingTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "CommandBindingTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeConfig() -> JiraConfig {
        JiraConfig(defaults: defaults)
    }

    // MARK: Значения по умолчанию

    func testDefaultBindings() {
        let config = makeConfig()
        let ctrlOpt = CarbonModifier.control | CarbonModifier.option
        let shiftCmd = CarbonModifier.shift | CarbonModifier.command

        XCTAssertEqual(config.binding(for: .quickInput),
                       HotKeyBinding(enabled: true, keyCode: 8, modifiers: ctrlOpt))
        XCTAssertEqual(config.binding(for: .snippets),
                       HotKeyBinding(enabled: true, keyCode: 9, modifiers: ctrlOpt))
        XCTAssertEqual(config.binding(for: .micToggle),
                       HotKeyBinding(enabled: true, keyCode: 46, modifiers: shiftCmd))
        // keep-awake / paste-plain — без прямой комбинации по умолчанию.
        XCTAssertFalse(config.binding(for: .keepAwake).isValid)
        XCTAssertFalse(config.binding(for: .pastePlain).isRegisterable)
    }

    func testBindingValidity() {
        XCTAssertTrue(HotKeyBinding(enabled: true, keyCode: 46, modifiers: CarbonModifier.command).isRegisterable)
        // Валидна по модификатору, но выключена → не регистрируется.
        XCTAssertFalse(HotKeyBinding(enabled: false, keyCode: 46, modifiers: CarbonModifier.command).isRegisterable)
        // Нет модификатора → невалидна.
        XCTAssertFalse(HotKeyBinding(enabled: true, keyCode: 46, modifiers: 0).isValid)
    }

    // MARK: Чтение/запись

    func testSetBindingPersists() {
        let config = makeConfig()
        let b = HotKeyBinding(enabled: true, keyCode: 3, modifiers: CarbonModifier.command)
        config.setBinding(b, for: .keepAwake)
        // Новый экземпляр поверх тех же defaults видит запись.
        XCTAssertEqual(makeConfig().binding(for: .keepAwake), b)
    }

    // MARK: Миграция из legacy-полей

    func testMigrationCarriesOverLegacyHotKeys() {
        // Симулируем апгрейд: пользователь ранее перенастроил комбинации (сырые legacy-ключи).
        defaults.set(false, forKey: "showInputHotKeyEnabled")
        defaults.set(50, forKey: "showInputHotKeyKeyCode")
        defaults.set(CarbonModifier.command, forKey: "showInputHotKeyModifiers")
        defaults.set(51, forKey: "snippetsHotKeyKeyCode")
        defaults.set(CarbonModifier.shift, forKey: "snippetsHotKeyModifiers")

        let config = makeConfig()  // миграция в init
        XCTAssertEqual(config.binding(for: .quickInput),
                       HotKeyBinding(enabled: false, keyCode: 50, modifiers: CarbonModifier.command))
        XCTAssertEqual(config.binding(for: .snippets).keyCode, 51)
        XCTAssertEqual(config.binding(for: .snippets).modifiers, CarbonModifier.shift)
    }

    func testMigrationRunsOnceAndDoesNotClobber() {
        let c1 = makeConfig()  // миграция, флаг выставлен
        c1.setBinding(HotKeyBinding(enabled: true, keyCode: 99, modifiers: CarbonModifier.command),
                      for: .quickInput)
        // Повторная инициализация не должна перезатирать словарь legacy-значениями.
        let c2 = makeConfig()
        XCTAssertEqual(c2.binding(for: .quickInput).keyCode, 99)
    }

    // MARK: Legacy-шимы

    func testLegacyShimsReadWriteThroughDict() {
        let config = makeConfig()
        config.showInputHotKeyKeyCode = 40
        XCTAssertEqual(config.binding(for: .quickInput).keyCode, 40)

        config.setBinding(HotKeyBinding(enabled: false, keyCode: 7, modifiers: CarbonModifier.shift),
                          for: .quickInput)
        XCTAssertEqual(config.showInputHotKeyKeyCode, 7)
        XCTAssertFalse(config.showInputHotKeyEnabled)
        XCTAssertEqual(config.showInputHotKeyModifiers, CarbonModifier.shift)
    }

    // MARK: Триггер панели

    func testPaletteTriggerDefaultAndRoundTrip() {
        let config = makeConfig()
        XCTAssertEqual(config.paletteTrigger, .doubleTap(.rightCommand))

        config.paletteTrigger = .doubleTap(.rightOption)
        XCTAssertEqual(makeConfig().paletteTrigger, .doubleTap(.rightOption))

        config.paletteTrigger = .disabled
        XCTAssertEqual(makeConfig().paletteTrigger, .disabled)
    }

    func testPaletteTriggerRawValueParsing() {
        XCTAssertEqual(PaletteTrigger(rawValue: "doubleTap:rightCommand"), .doubleTap(.rightCommand))
        XCTAssertEqual(PaletteTrigger(rawValue: "doubleTap:rightOption"), .doubleTap(.rightOption))
        XCTAssertEqual(PaletteTrigger(rawValue: "disabled"), .disabled)
        XCTAssertNil(PaletteTrigger(rawValue: "garbage"))
        XCTAssertNil(PaletteTrigger(rawValue: "doubleTap:leftShift"))
        // rawValue round-trips.
        XCTAssertEqual(PaletteTrigger(rawValue: PaletteTrigger.doubleTap(.rightOption).rawValue),
                       .doubleTap(.rightOption))
    }

    func testModifierSideKeyCodes() {
        XCTAssertEqual(ModifierSide.leftCommand.keyCode, 55)
        XCTAssertEqual(ModifierSide.rightCommand.keyCode, 54)
        XCTAssertEqual(ModifierSide.leftOption.keyCode, 58)
        XCTAssertEqual(ModifierSide.rightOption.keyCode, 61)
    }

    // MARK: Буквенные хоткеи команд в панели

    func testPanelKeyCodesAreUniqueAndAvoidReservedKeys() {
        // Служебные клавиши панели, которые нельзя занимать буквой команды.
        let reserved: Set<UInt16> = [36, 76, 53, 48, 123, 124, 125, 126]  // ↩/↩(num) Esc Tab ←→↑↓
        var seen: Set<UInt16> = []
        for id in CommandID.allCases {
            let code = id.panelKeyCode
            XCTAssertFalse(reserved.contains(code), "\(id) сидит на служебной клавише \(code)")
            XCTAssertTrue(seen.insert(code).inserted, "keyCode \(code) уже занят другой командой (коллизия у \(id))")
        }
    }

    func testPanelKeyCodeBadgeLetters() {
        // Бейдж и матч идут от одного физического кода → буква на плитке = клавиша нажатия.
        XCTAssertEqual(keyName(forKeyCode: UInt32(CommandID.micToggle.panelKeyCode)), "M")
        XCTAssertEqual(keyName(forKeyCode: UInt32(CommandID.snippets.panelKeyCode)), "S")
        XCTAssertEqual(keyName(forKeyCode: UInt32(CommandID.pastePlain.panelKeyCode)), "V")
    }

    // MARK: Сброс

    func testResetRestoresDefaults() {
        let config = makeConfig()
        config.setBinding(HotKeyBinding(enabled: false, keyCode: 1, modifiers: CarbonModifier.command),
                          for: .micToggle)
        config.paletteTrigger = .disabled

        config.resetToDefaults()

        XCTAssertEqual(config.binding(for: .micToggle), JiraConfig.defaultBinding(for: .micToggle))
        XCTAssertEqual(config.paletteTrigger, .doubleTap(.rightCommand))
    }
}
