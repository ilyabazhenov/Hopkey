import Foundation
import CryptoKit

/// Тонкая обёртка над `AES.GCM` для шифрования истории буфера на диске. Ключ (256 бит)
/// живёт в Keychain (см. `ClipboardHistory`), сюда приходит уже готовым. Формат на диске —
/// `combined` (nonce‖ciphertext‖tag) одним блобом, чтобы читать/писать одним `Data`.
///
/// Крипта вынесена отдельным типом ради round-trip тестов без Keychain и диска.
public struct ClipboardCrypto {

    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Новый случайный 256-битный ключ (первый запуск, когда в Keychain записи ещё нет).
    public static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Восстанавливает ключ из base64-строки (как он лежит в Keychain). `nil`, если строка
    /// не base64 или длина не 32 байта — тогда вызывающий генерирует новый.
    public static func key(fromBase64 string: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: string), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Сырые байты ключа в base64 — для записи в Keychain.
    public static func base64(of key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// SHA-256 контента в hex — используется для дешёвого dedup картинок (сравнить хэши,
    /// а не расшифровывать и сверять байты каждой сохранённой картинки).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Шифрует произвольные данные. Возвращает `combined`-блоб (nonce+ciphertext+tag).
    public func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw ClipboardCryptoError.sealFailed }
        return combined
    }

    /// Расшифровывает `combined`-блоб. Бросает, если данные повреждены или ключ не тот.
    public func open(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }
}

public enum ClipboardCryptoError: Error {
    /// `AES.GCM.seal` не отдал `combined` (в штатной ситуации не случается).
    case sealFailed
}
