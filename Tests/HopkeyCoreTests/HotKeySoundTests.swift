import XCTest
@testable import HopkeyCore

final class HotKeySoundTests: XCTestCase {

    func testDefaultIsBottle() {
        XCTAssertEqual(HotKeySound.default, .bottle)
    }

    func testAllCasesRoundTripThroughRawValue() {
        XCTAssertEqual(HotKeySound.allCases.count, 8)
        for sound in HotKeySound.allCases {
            XCTAssertEqual(HotKeySound(rawValue: sound.rawValue), sound)
            XCTAssertFalse(sound.systemName.isEmpty)
            XCTAssertEqual(sound.localizationKey, "settings.hotkey.sound.\(sound.rawValue)")
        }
    }

    func testSystemNamesMatchMacOSSounds() {
        XCTAssertEqual(HotKeySound.bottle.systemName, "Bottle")
        XCTAssertEqual(HotKeySound.submarine.systemName, "Submarine")
    }
}
