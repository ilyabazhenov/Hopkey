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
        XCTAssertEqual(config.baseURL, "")
        XCTAssertEqual(config.prefixes, [])
        XCTAssertFalse(config.autoOpen)
        XCTAssertFalse(config.hotKeyEnabled)
    }

    func testBaseURLRoundTrip() {
        let config = makeConfig()
        config.baseURL = "https://jira.example.com/browse/"
        XCTAssertEqual(config.baseURL, "https://jira.example.com/browse/")
        // Значение должно переживать пересоздание объекта (читается из defaults).
        XCTAssertEqual(makeConfig().baseURL, "https://jira.example.com/browse/")
    }

    func testPrefixesRoundTrip() {
        let config = makeConfig()
        config.prefixes = ["PROJ", "PAY"]
        XCTAssertEqual(config.prefixes, ["PROJ", "PAY"])
        XCTAssertEqual(makeConfig().prefixes, ["PROJ", "PAY"])
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

    func testIsConfiguredFalseWhenEmpty() {
        XCTAssertFalse(makeConfig().isConfigured)
    }

    func testIsConfiguredFalseWithoutPrefixes() {
        let config = makeConfig()
        config.baseURL = "https://jira.example.com/browse/"
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWithoutBaseURL() {
        let config = makeConfig()
        config.prefixes = ["PROJ"]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWhenBaseURLIsWhitespace() {
        let config = makeConfig()
        config.baseURL = "   "
        config.prefixes = ["PROJ"]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredTrueWhenBothSet() {
        let config = makeConfig()
        config.baseURL = "https://jira.example.com/browse/"
        config.prefixes = ["PROJ"]
        XCTAssertTrue(config.isConfigured)
    }
}
