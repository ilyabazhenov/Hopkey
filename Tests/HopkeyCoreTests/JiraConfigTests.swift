import XCTest
@testable import HopkeyCore

final class JiraConfigTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // Изолированное хранилище на каждый тест, чтобы не трогать .standard.
        suiteName = "JiraConfigTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeConfig() -> JiraConfig {
        JiraConfig(defaults: defaults)
    }

    func testDefaults() {
        let config = makeConfig()
        XCTAssertEqual(config.projects, [])
        XCTAssertFalse(config.autoOpen)
        XCTAssertFalse(config.hotKeyEnabled)
        // По умолчанию ⌃⌥J: keyCode 38, модификаторы controlKey | optionKey = 6144.
        XCTAssertEqual(config.hotKeyKeyCode, 38)
        XCTAssertEqual(config.hotKeyModifiers, 6144)
        XCTAssertEqual(config.defaultAction, .openInBrowser)
    }

    func testDefaultActionRoundTrip() {
        let config = makeConfig()
        config.defaultAction = .copyURL
        XCTAssertEqual(config.defaultAction, .copyURL)
        XCTAssertEqual(makeConfig().defaultAction, .copyURL)
    }

    func testSplitActionsDefault() {
        let config = makeConfig()
        XCTAssertEqual(config.hotKeyAction, .openInBrowser)
        XCTAssertEqual(config.clipboardAction, .openInBrowser)
    }

    func testSplitActionsFallBackToLegacyDefaultAction() {
        let config = makeConfig()
        // Старая версия хранила единственный defaultAction; новые свойства наследуют его.
        config.defaultAction = .copyURL
        XCTAssertEqual(config.hotKeyAction, .copyURL)
        XCTAssertEqual(config.clipboardAction, .copyURL)
        // Пересоздание объекта читает значения из defaults.
        XCTAssertEqual(makeConfig().hotKeyAction, .copyURL)
        XCTAssertEqual(makeConfig().clipboardAction, .copyURL)
    }

    func testSplitActionsAreIndependent() {
        let config = makeConfig()
        config.hotKeyAction = .copyURL
        config.clipboardAction = .openInBrowser
        XCTAssertEqual(config.hotKeyAction, .copyURL)
        XCTAssertEqual(config.clipboardAction, .openInBrowser)
        // И переживают пересоздание объекта, не влияя друг на друга.
        let reloaded = makeConfig()
        XCTAssertEqual(reloaded.hotKeyAction, .copyURL)
        XCTAssertEqual(reloaded.clipboardAction, .openInBrowser)
    }

    // MARK: Два хоткея

    func testHotKeyDefaults() {
        let config = makeConfig()
        XCTAssertFalse(config.openHotKeyEnabled)
        XCTAssertFalse(config.copyHotKeyEnabled)
        // ⌃⌥J по умолчанию для «открыть», ⌃⌥K для «скопировать» (6144 = control|option).
        XCTAssertEqual(config.openHotKeyKeyCode, 38)
        XCTAssertEqual(config.openHotKeyModifiers, 6144)
        XCTAssertEqual(config.copyHotKeyKeyCode, 40)
        XCTAssertEqual(config.copyHotKeyModifiers, 6144)
    }

    func testHotKeyRoundTrip() {
        let config = makeConfig()
        config.openHotKeyEnabled = true
        config.openHotKeyKeyCode = 1
        config.copyHotKeyEnabled = true
        config.copyHotKeyKeyCode = 2
        let reloaded = makeConfig()
        XCTAssertTrue(reloaded.openHotKeyEnabled)
        XCTAssertEqual(reloaded.openHotKeyKeyCode, 1)
        XCTAssertTrue(reloaded.copyHotKeyEnabled)
        XCTAssertEqual(reloaded.copyHotKeyKeyCode, 2)
    }

    func testMigrationRoutesLegacyHotkeyToCopySlot() {
        // Старый единственный хоткей с действием «скопировать» и комбинацией keyCode 3.
        defaults.set(true, forKey: "hotKeyEnabled")
        defaults.set("copyURL", forKey: "hotKeyAction")
        defaults.set(3, forKey: "hotKeyKeyCode")
        defaults.set(6144, forKey: "hotKeyModifiers")

        let config = makeConfig() // миграция выполняется в init
        XCTAssertTrue(config.copyHotKeyEnabled)
        XCTAssertEqual(config.copyHotKeyKeyCode, 3)
        XCTAssertEqual(config.copyHotKeyModifiers, 6144)
        // Слот «открыть» остаётся выключенным с дефолтной комбинацией ⌃⌥J.
        XCTAssertFalse(config.openHotKeyEnabled)
        XCTAssertEqual(config.openHotKeyKeyCode, 38)
    }

    func testMigrationRoutesLegacyHotkeyToOpenSlot() {
        defaults.set(true, forKey: "hotKeyEnabled")
        defaults.set("openInBrowser", forKey: "hotKeyAction")
        defaults.set(38, forKey: "hotKeyKeyCode")
        defaults.set(6144, forKey: "hotKeyModifiers")

        let config = makeConfig()
        XCTAssertTrue(config.openHotKeyEnabled)
        XCTAssertEqual(config.openHotKeyKeyCode, 38)
        // Слот «скопировать» остаётся выключенным с дефолтной комбинацией ⌃⌥K.
        XCTAssertFalse(config.copyHotKeyEnabled)
        XCTAssertEqual(config.copyHotKeyKeyCode, 40)
    }

    func testMigrationRunsOnce() {
        // Первый конфиг мигрирует и выставляет слот «открыть».
        defaults.set(true, forKey: "hotKeyEnabled")
        defaults.set("openInBrowser", forKey: "hotKeyAction")
        _ = makeConfig()
        // Пользователь вручную выключил хоткей «открыть».
        let config = makeConfig()
        config.openHotKeyEnabled = false
        // Повторное создание не должно заново «воскрешать» миграцию.
        XCTAssertFalse(makeConfig().openHotKeyEnabled)
    }

    // MARK: Сброс настроек

    func testResetToDefaultsRestoresEverything() {
        let config = makeConfig()
        config.projects = [JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: ["PROJ"])]
        config.autoOpen = true
        // Legacy-ключ defaultAction, который наследует clipboardAction, тоже должен сброситься.
        config.defaultAction = .copyURL
        config.clipboardAction = .copyURL
        config.openHotKeyEnabled = true
        config.openHotKeyKeyCode = 1
        config.copyHotKeyEnabled = true
        config.copyHotKeyKeyCode = 2

        config.resetToDefaults()

        XCTAssertEqual(config.projects, [])
        XCTAssertFalse(config.autoOpen)
        XCTAssertEqual(config.defaultAction, .openInBrowser)
        XCTAssertEqual(config.clipboardAction, .openInBrowser)
        // Хоткеи возвращаются к дефолтам ⌃⌥J / ⌃⌥K и выключаются.
        XCTAssertFalse(config.openHotKeyEnabled)
        XCTAssertEqual(config.openHotKeyKeyCode, 38)
        XCTAssertEqual(config.openHotKeyModifiers, 6144)
        XCTAssertFalse(config.copyHotKeyEnabled)
        XCTAssertEqual(config.copyHotKeyKeyCode, 40)
        XCTAssertEqual(config.copyHotKeyModifiers, 6144)
    }

    func testResetToDefaultsPersistsAndSurvivesReload() {
        let config = makeConfig()
        config.projects = [JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: ["PROJ"])]
        config.copyHotKeyKeyCode = 9

        config.resetToDefaults()

        // Новый объект (в т.ч. его миграция) не должен «воскрешать» прежние значения.
        let reloaded = makeConfig()
        XCTAssertEqual(reloaded.projects, [])
        XCTAssertEqual(reloaded.copyHotKeyKeyCode, 40)
        XCTAssertFalse(reloaded.openHotKeyEnabled)
        XCTAssertFalse(reloaded.copyHotKeyEnabled)
    }

    func testProjectsRoundTrip() {
        let config = makeConfig()
        let projects = [
            JiraProject(baseURL: "https://a.example.com/browse/", prefixes: ["PROJ", "PAY"]),
            JiraProject(baseURL: "https://b.example.com/browse/", prefixes: ["ABC"]),
        ]
        config.projects = projects
        XCTAssertEqual(config.projects, projects)
        // Значение должно переживать пересоздание объекта (читается из defaults).
        XCTAssertEqual(makeConfig().projects, projects)
    }

    func testAutoOpenRoundTrip() {
        let config = makeConfig()
        config.autoOpen = true
        XCTAssertTrue(config.autoOpen)
        XCTAssertTrue(makeConfig().autoOpen)
    }

    func testHotKeyEnabledRoundTrip() {
        let config = makeConfig()
        config.hotKeyEnabled = true
        XCTAssertTrue(config.hotKeyEnabled)
        XCTAssertTrue(makeConfig().hotKeyEnabled)
    }

    func testHotKeyKeyCodeRoundTrip() {
        let config = makeConfig()
        config.hotKeyKeyCode = 40 // K
        XCTAssertEqual(config.hotKeyKeyCode, 40)
        XCTAssertEqual(makeConfig().hotKeyKeyCode, 40)
    }

    func testHotKeyModifiersRoundTrip() {
        let config = makeConfig()
        config.hotKeyModifiers = 0x0100 | 0x0200 // cmdKey | shiftKey
        XCTAssertEqual(config.hotKeyModifiers, 0x0300)
        XCTAssertEqual(makeConfig().hotKeyModifiers, 0x0300)
    }

    func testIsConfiguredFalseWhenEmpty() {
        XCTAssertFalse(makeConfig().isConfigured)
    }

    func testIsConfiguredFalseWithoutPrefixes() {
        let config = makeConfig()
        config.projects = [JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: [])]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWithoutBaseURL() {
        let config = makeConfig()
        config.projects = [JiraProject(baseURL: "", prefixes: ["PROJ"])]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWhenBaseURLIsWhitespace() {
        let config = makeConfig()
        config.projects = [JiraProject(baseURL: "   ", prefixes: ["PROJ"])]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredTrueWhenAtLeastOneValidProject() {
        let config = makeConfig()
        config.projects = [
            JiraProject(baseURL: "", prefixes: []),
            JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: ["PROJ"]),
        ]
        XCTAssertTrue(config.isConfigured)
    }
}
