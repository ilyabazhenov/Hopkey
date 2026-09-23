import XCTest
import CryptoKit
@testable import HopkeyCore

final class ClipboardCryptoTests: XCTestCase {

    func testSealOpenRoundTrip() throws {
        let crypto = ClipboardCrypto(key: ClipboardCrypto.generateKey())
        let plain = Data("секрет + 🧷 + \u{00}\u{01}\u{02}".utf8)
        let sealed = try crypto.seal(plain)
        XCTAssertNotEqual(sealed, plain)
        XCTAssertEqual(try crypto.open(sealed), plain)
    }

    func testOpenWithWrongKeyThrows() throws {
        let sealed = try ClipboardCrypto(key: ClipboardCrypto.generateKey()).seal(Data("x".utf8))
        let other = ClipboardCrypto(key: ClipboardCrypto.generateKey())
        XCTAssertThrowsError(try other.open(sealed))
    }

    func testKeyBase64RoundTrip() {
        let key = ClipboardCrypto.generateKey()
        let b64 = ClipboardCrypto.base64(of: key)
        let restored = ClipboardCrypto.key(fromBase64: b64)
        XCTAssertNotNil(restored)
        // Один и тот же ключ → расшифровка кросс-экземпляром работает.
        let sealed = try? ClipboardCrypto(key: key).seal(Data("hi".utf8))
        XCTAssertEqual(try? ClipboardCrypto(key: restored!).open(sealed!), Data("hi".utf8))
    }

    func testKeyFromBadBase64IsNil() {
        XCTAssertNil(ClipboardCrypto.key(fromBase64: "not-base64!!!"))
        XCTAssertNil(ClipboardCrypto.key(fromBase64: Data("short".utf8).base64EncodedString()))
    }

    func testSha256IsStable() {
        let a = ClipboardCrypto.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(a, ClipboardCrypto.sha256Hex(Data("abc".utf8)))
        XCTAssertNotEqual(a, ClipboardCrypto.sha256Hex(Data("abd".utf8)))
        // Известный вектор SHA-256("abc").
        XCTAssertEqual(a, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
