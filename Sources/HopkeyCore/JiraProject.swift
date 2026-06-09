import Foundation

/// Один проект Jira: свой базовый URL и свой набор префиксов.
///
/// Несколько проектов работают одновременно — префикс найденного тикета
/// определяет, по какому `baseURL` его открывать (см. `TicketParser.matches(in:projects:)`).
public struct JiraProject: Codable, Equatable {
    /// Базовый URL Jira, например `https://your-jira/browse/` (слэш нормализуется в парсере).
    public var baseURL: String
    /// Список префиксов проектов, например `["PROJ", "TEAM"]`.
    public var prefixes: [String]

    public init(baseURL: String, prefixes: [String]) {
        self.baseURL = baseURL
        self.prefixes = prefixes
    }

    /// Проект пригоден к использованию, если задан URL и хотя бы один префикс.
    public var isValid: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prefixes.isEmpty
    }
}
