import Foundation

/// Логика быстрого выбора сниппета цифрой в окне-пикере. Вынесена из UI, чтобы границы
/// (пустой список, цифра вне диапазона, номер больше числа сниппетов) были под тестами.
public enum SnippetQuickSelect {

    /// Сколько первых сниппетов доступны быстрым выбором цифрой (1–9).
    public static let maxDigits = 9

    /// Индекс сниппета для нажатой цифры, если такой сниппет есть; иначе `nil`
    /// (цифра вне 1…9 или в списке меньше сниппетов).
    public static func index(forDigit digit: Int, count: Int) -> Int? {
        guard digit >= 1, digit <= maxDigits else { return nil }
        let index = digit - 1
        return index < count ? index : nil
    }

    /// Подпись-номер строки: "1"…"9" для первых девяти, иначе пусто (быстрый выбор
    /// только для них).
    public static func label(forRow row: Int) -> String {
        row < maxDigits ? String(row + 1) : ""
    }
}
