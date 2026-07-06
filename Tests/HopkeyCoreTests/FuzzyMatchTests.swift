import XCTest
@testable import HopkeyCore

final class FuzzyMatchTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score(query: "saf", candidate: "Safari"))
        XCTAssertNotNil(FuzzyMatch.score(query: "sfr", candidate: "Safari"))   // разрозненно, но по порядку
        XCTAssertNotNil(FuzzyMatch.score(query: "SAFARI", candidate: "safari"))  // регистр не важен
    }

    func testNonSubsequenceRejected() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", candidate: "Safari"))
        XCTAssertNil(FuzzyMatch.score(query: "ras", candidate: "Safari"))  // порядок нарушен
        XCTAssertNil(FuzzyMatch.score(query: "safarii", candidate: "Safari"))  // длиннее кандидата
    }

    func testDiacriticInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "cafe", candidate: "Café"))
    }

    func testPrefixBeatsScattered() {
        let prefix = FuzzyMatch.score(query: "mic", candidate: "Microphone")!
        let scattered = FuzzyMatch.score(query: "mic", candidate: "Dynamic Corner")!
        XCTAssertGreaterThan(prefix, scattered)
    }

    func testExactBeatsPrefix() {
        let exact = FuzzyMatch.score(query: "notes", candidate: "Notes")!
        let longer = FuzzyMatch.score(query: "notes", candidate: "Notes Helper")!
        XCTAssertGreaterThan(exact, longer)
    }

    func testWordBoundaryBonus() {
        // «vc» лучше матчится там, где обе буквы — начала слов.
        let boundary = FuzzyMatch.score(query: "vc", candidate: "Visual Code")!
        let inner = FuzzyMatch.score(query: "vc", candidate: "Avci")!
        XCTAssertGreaterThan(boundary, inner)
    }

    func testEmptyQueryIsZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "Safari"), 0)
    }

    func testBestScoreAcrossNames() {
        // «Калькулятор» (локализованное) + «Calculator» (имя файла) — матчится по любому языку.
        let names = ["Калькулятор", "Calculator"]
        XCTAssertNotNil(FuzzyMatch.bestScore(query: "кальку", candidates: names))
        XCTAssertNotNil(FuzzyMatch.bestScore(query: "calc", candidates: names))
        XCTAssertNil(FuzzyMatch.bestScore(query: "xyz", candidates: names))
    }
}
