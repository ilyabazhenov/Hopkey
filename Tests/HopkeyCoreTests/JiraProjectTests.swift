import XCTest
@testable import HopkeyCore

final class JiraProjectTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let project = JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: ["PROJ", "PAY"])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(JiraProject.self, from: data)
        XCTAssertEqual(decoded, project)
    }

    func testIsValidTrue() {
        XCTAssertTrue(JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: ["PROJ"]).isValid)
    }

    func testIsValidFalseWithoutPrefixes() {
        XCTAssertFalse(JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: []).isValid)
    }

    func testIsValidFalseWithEmptyURL() {
        XCTAssertFalse(JiraProject(baseURL: "", prefixes: ["PROJ"]).isValid)
    }

    func testIsValidFalseWithWhitespaceURL() {
        XCTAssertFalse(JiraProject(baseURL: "   ", prefixes: ["PROJ"]).isValid)
    }
}
