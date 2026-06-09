import Foundation

/// Что Hopkey делает с найденными в тексте тикетами.
///
/// `rawValue` стабилен — он используется как значение в `UserDefaults`.
public enum TicketAction: String, CaseIterable {
    /// Открыть ссылку(и) в браузере по умолчанию. Поведение по умолчанию.
    case openInBrowser
    /// Скопировать URL(ы) тикетов в буфер обмена.
    case copyURL

    /// Строка для буфера обмена: URL'ы, по одному на строку, в порядке появления.
    public static func clipboardString(for matches: [TicketMatch]) -> String {
        matches.map { $0.url.absoluteString }.joined(separator: "\n")
    }
}
