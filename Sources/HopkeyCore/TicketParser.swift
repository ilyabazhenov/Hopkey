import Foundation

/// Найденный в тексте ID тикета и собранная для него ссылка.
public struct TicketMatch: Equatable {
    /// Нормализованный ID в верхнем регистре, например `PROJ-12345`.
    public let id: String
    /// Полный URL для открытия в браузере.
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }
}

/// Чистое ядро: из произвольного текста достаёт ID тикетов по заданным префиксам
/// и строит для каждого ссылку на базе `baseURL`.
///
/// Никакого UI и состояния — всё передаётся параметрами, поэтому легко тестируется.
public enum TicketParser {

    /// Извлекает все совпадения из текста.
    /// - Parameters:
    ///   - text: произвольный текст (выделение, содержимое буфера обмена и т.п.).
    ///   - prefixes: список префиксов проектов, например `["PROJ", "TEAM"]`.
    ///   - baseURL: базовый URL Jira, например `https://your-jira/browse/`.
    /// - Returns: совпадения в порядке появления, без дубликатов (по ID).
    public static func matches(in text: String, prefixes: [String], baseURL: String) -> [TicketMatch] {
        let cleanPrefixes = prefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanPrefixes.isEmpty, !text.isEmpty else { return [] }

        // (PREFIX1|PREFIX2)-\d+  с границами, чтобы XPROJ-1 не ловился.
        let alternation = cleanPrefixes
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "(?<![A-Za-z0-9])(?:\(alternation))-\\d+(?![A-Za-z0-9])"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)

        var seen = Set<String>()
        var result: [TicketMatch] = []
        let normalizedBase = normalizeBaseURL(baseURL)

        for m in regex.matches(in: text, options: [], range: full) {
            let raw = nsText.substring(with: m.range)
            let id = raw.uppercased()
            guard !seen.contains(id) else { continue }
            guard let url = URL(string: normalizedBase + id) else { continue }
            seen.insert(id)
            result.append(TicketMatch(id: id, url: url))
        }
        return result
    }

    /// Гарантирует один завершающий слэш, чтобы `base` + `ID` всегда был корректным.
    private static func normalizeBaseURL(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }
}
