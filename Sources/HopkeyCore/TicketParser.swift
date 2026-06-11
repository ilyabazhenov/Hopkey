import Foundation

/// Найденный в тексте ID и собранная для него ссылка.
public struct TicketMatch: Equatable {
    /// Отображаемый ID совпадения (всё совпадение `$0`, поднятое в верхний регистр
    /// при `LinkTemplate.uppercase`), например `PROJ-12345` или `#123`.
    public let id: String
    /// Полный URL для открытия в браузере.
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }
}

/// Чистое ядро: прогоняет текст через набор `LinkTemplate` и строит ссылки.
///
/// Никакого UI и состояния — всё передаётся параметрами, поэтому легко тестируется.
public enum TicketParser {

    /// Извлекает все совпадения из текста по включённым шаблонам.
    /// Дубликаты по `id` не повторяются — выигрывает первый шаблон (порядок важен).
    /// Кривой regex молча пропускается (как и шаблон без валидного URL).
    public static func matches(in text: String, templates: [LinkTemplate]) -> [TicketMatch] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var seen = Set<String>()
        var result: [TicketMatch] = []
        for template in templates where template.enabled {
            guard let regex = template.compiledRegex() else { continue }
            for m in regex.matches(in: text, options: [], range: full) {
                guard let match = template.match(from: m, in: ns), !seen.contains(match.id)
                else { continue }
                seen.insert(match.id)
                result.append(match)
            }
        }
        return result
    }

    /// Точное совпадение: текст целиком (без пробелов по краям) — ровно один ключ.
    /// URL, предложения и любой лишний текст не срабатывают. Нужно для автонаблюдения
    /// за буфером, чтобы случайно скопированная ссылка не открывала браузер сама собой.
    /// Выигрывает первый включённый шаблон, чьё совпадение занимает всю строку.
    public static func exactMatch(in text: String, templates: [LinkTemplate]) -> TicketMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)

        for template in templates where template.enabled {
            guard let regex = template.compiledRegex(),
                  let m = regex.firstMatch(in: trimmed, options: [], range: full),
                  m.range == full,
                  let match = template.match(from: m, in: ns)
            else { continue }
            return match
        }
        return nil
    }
}
