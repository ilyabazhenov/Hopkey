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

    private func jira(_ prefix: String = "PROJ",
                      base: String = "https://jira.example.com/browse/") -> LinkTemplate {
        LinkTemplate(name: prefix, pattern: "\(prefix)-(\\d+)", url: "\(base)\(prefix)-$1",
                     wholeWord: true, uppercase: true)
    }

    func testDefaults() {
        let config = makeConfig()
        XCTAssertEqual(config.templates, [])
        XCTAssertFalse(config.autoOpen)
        XCTAssertEqual(config.defaultAction, .openInBrowser)
    }

    // MARK: Действие при копировании в буфер

    func testDefaultActionRoundTrip() {
        let config = makeConfig()
        config.defaultAction = .copyURL
        XCTAssertEqual(config.defaultAction, .copyURL)
        XCTAssertEqual(makeConfig().defaultAction, .copyURL)
    }

    func testClipboardActionDefault() {
        XCTAssertEqual(makeConfig().clipboardAction, .openInBrowser)
    }

    func testClipboardActionFallsBackToDefaultAction() {
        let config = makeConfig()
        config.defaultAction = .copyURL
        XCTAssertEqual(config.clipboardAction, .copyURL)
        XCTAssertEqual(makeConfig().clipboardAction, .copyURL)
    }

    func testClipboardActionIndependentOnceSet() {
        let config = makeConfig()
        config.defaultAction = .copyURL
        config.clipboardAction = .openInBrowser
        XCTAssertEqual(config.clipboardAction, .openInBrowser)
        XCTAssertEqual(makeConfig().clipboardAction, .openInBrowser)
    }

    // MARK: Горячие клавиши (две, включены по умолчанию)

    func testHotKeyDefaults() {
        let config = makeConfig()
        // Обе включены. ⌃⌥C — окно ввода (keyCode 8), ⌃⌥V — пикер (keyCode 9). 6144 = control|option.
        XCTAssertTrue(config.showInputHotKeyEnabled)
        XCTAssertEqual(config.showInputHotKeyKeyCode, 8)
        XCTAssertEqual(config.showInputHotKeyModifiers, 6144)
        XCTAssertTrue(config.snippetsHotKeyEnabled)
        XCTAssertEqual(config.snippetsHotKeyKeyCode, 9)
        XCTAssertEqual(config.snippetsHotKeyModifiers, 6144)
        XCTAssertTrue(config.hotKeySoundsEnabled)
        XCTAssertEqual(config.hotKeySound, .bottle)
    }

    func testShowInputHotKeyRoundTrip() {
        let config = makeConfig()
        config.showInputHotKeyEnabled = false
        config.showInputHotKeyKeyCode = 1
        config.showInputHotKeyModifiers = 0x0900
        let reloaded = makeConfig()
        XCTAssertFalse(reloaded.showInputHotKeyEnabled)
        XCTAssertEqual(reloaded.showInputHotKeyKeyCode, 1)
        XCTAssertEqual(reloaded.showInputHotKeyModifiers, 0x0900)
    }

    func testSnippetsHotKeyRoundTrip() {
        let config = makeConfig()
        config.snippetsHotKeyEnabled = false
        config.snippetsHotKeyKeyCode = 11
        config.snippetsHotKeyModifiers = 0x0900
        let reloaded = makeConfig()
        XCTAssertFalse(reloaded.snippetsHotKeyEnabled)
        XCTAssertEqual(reloaded.snippetsHotKeyKeyCode, 11)
        XCTAssertEqual(reloaded.snippetsHotKeyModifiers, 0x0900)
    }

    // MARK: Миграция проектов → шаблоны

    /// Кладёт legacy-`projects` в виде Data (как писала старая версия через JSONEncoder).
    private func setLegacyProjects(_ projects: [(base: String, prefixes: [String])]) {
        let payload = projects.map { ["baseURL": $0.base, "prefixes": $0.prefixes] as [String: Any] }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: "projects")
    }

    func testMigrationExpandsProjectsIntoPerPrefixTemplates() {
        setLegacyProjects([(base: "https://jira.example.com/browse/", prefixes: ["PROJ", "PAY"])])

        let config = makeConfig() // миграция в init
        XCTAssertEqual(config.templates.map(\.name), ["PROJ", "PAY"])
        XCTAssertEqual(config.templates.map(\.pattern), ["PROJ-(\\d+)", "PAY-(\\d+)"])
        XCTAssertEqual(config.templates.map(\.url),
                       ["https://jira.example.com/browse/PROJ-$1",
                        "https://jira.example.com/browse/PAY-$1"])
        XCTAssertTrue(config.templates.allSatisfy { $0.wholeWord && $0.uppercase && $0.enabled })
        let m = TicketParser.exactMatch(in: "PAY-7", templates: config.templates)
        XCTAssertEqual(m?.url.absoluteString, "https://jira.example.com/browse/PAY-7")
    }

    func testMigrationAddsTrailingSlashToBase() {
        setLegacyProjects([(base: "https://jira.example.com/browse", prefixes: ["PROJ"])])
        XCTAssertEqual(makeConfig().templates.first?.url, "https://jira.example.com/browse/PROJ-$1")
    }

    func testMigrationRunsOnceAndDoesNotResurrect() {
        setLegacyProjects([(base: "https://jira.example.com/browse/", prefixes: ["PROJ"])])
        _ = makeConfig() // мигрировали
        let config = makeConfig()
        config.templates = []
        XCTAssertEqual(makeConfig().templates, [])
    }

    func testNoMigrationWhenNoLegacyProjects() {
        XCTAssertEqual(makeConfig().templates, [])
    }

    // MARK: Сброс настроек

    func testResetToDefaultsRestoresEverything() {
        let config = makeConfig()
        config.templates = [jira()]
        config.autoOpen = true
        config.defaultAction = .copyURL
        config.clipboardAction = .copyURL
        config.showInputHotKeyEnabled = false
        config.showInputHotKeyKeyCode = 1
        config.snippetsHotKeyEnabled = false
        config.snippetsHotKeyKeyCode = 2

        config.resetToDefaults()

        XCTAssertEqual(config.templates, [])
        XCTAssertFalse(config.autoOpen)
        XCTAssertEqual(config.defaultAction, .openInBrowser)
        XCTAssertEqual(config.clipboardAction, .openInBrowser)
        // Хоткеи возвращаются к дефолтам ⌃⌥C / ⌃⌥V и включаются.
        XCTAssertTrue(config.showInputHotKeyEnabled)
        XCTAssertEqual(config.showInputHotKeyKeyCode, 8)
        XCTAssertEqual(config.showInputHotKeyModifiers, 6144)
        XCTAssertTrue(config.snippetsHotKeyEnabled)
        XCTAssertEqual(config.snippetsHotKeyKeyCode, 9)
        XCTAssertEqual(config.snippetsHotKeyModifiers, 6144)
    }

    func testResetToDefaultsPersistsAndSurvivesReload() {
        let config = makeConfig()
        config.templates = [jira()]
        config.snippetsHotKeyKeyCode = 11

        config.resetToDefaults()

        let reloaded = makeConfig()
        XCTAssertEqual(reloaded.templates, [])
        XCTAssertEqual(reloaded.snippetsHotKeyKeyCode, 9)
        XCTAssertTrue(reloaded.showInputHotKeyEnabled)
        XCTAssertTrue(reloaded.snippetsHotKeyEnabled)
    }

    func testTemplatesRoundTrip() {
        let config = makeConfig()
        let templates = [
            jira("PROJ", base: "https://a.example.com/browse/"),
            LinkTemplate(name: "GitHub", pattern: "#(\\d+)",
                         url: "https://github.com/o/r/issues/$1", wholeWord: true, uppercase: false),
        ]
        config.templates = templates
        XCTAssertEqual(config.templates, templates)
        XCTAssertEqual(makeConfig().templates, templates)
    }

    func testAutoOpenRoundTrip() {
        let config = makeConfig()
        config.autoOpen = true
        XCTAssertTrue(config.autoOpen)
        XCTAssertTrue(makeConfig().autoOpen)
    }

    func testIsConfiguredFalseWhenEmpty() {
        XCTAssertFalse(makeConfig().isConfigured)
    }

    func testIsConfiguredFalseWithBrokenRegex() {
        let config = makeConfig()
        config.templates = [LinkTemplate(name: "x", pattern: "PROJ-(\\d+", url: "https://x/$1")]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWithoutPlaceholder() {
        let config = makeConfig()
        config.templates = [LinkTemplate(name: "x", pattern: "PROJ-(\\d+)", url: "https://x/static")]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredTrueWhenAtLeastOneValidTemplate() {
        let config = makeConfig()
        config.templates = [
            LinkTemplate(name: "", pattern: "", url: ""),
            jira(),
        ]
        XCTAssertTrue(config.isConfigured)
    }

    func testHotKeySoundsEnabledRoundTrip() {
        let config = makeConfig()
        XCTAssertTrue(config.hotKeySoundsEnabled)
        config.hotKeySoundsEnabled = false
        XCTAssertFalse(makeConfig().hotKeySoundsEnabled)
        config.hotKeySoundsEnabled = true
        XCTAssertTrue(makeConfig().hotKeySoundsEnabled)
    }

    func testHotKeySoundRoundTrip() {
        let config = makeConfig()
        XCTAssertEqual(config.hotKeySound, .bottle)
        config.hotKeySound = .glass
        XCTAssertEqual(makeConfig().hotKeySound, .glass)
        config.hotKeySound = .tink
        XCTAssertEqual(makeConfig().hotKeySound, .tink)
    }

    func testHotKeySoundFallsBackToDefaultForUnknownValue() {
        defaults.set("unknown", forKey: "hotKeySound")
        XCTAssertEqual(makeConfig().hotKeySound, .bottle)
    }
}
