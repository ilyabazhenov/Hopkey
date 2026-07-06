import Foundation

/// Преобразование текста над выделением (регистр, чистка, кодирование, строки).
/// Чистая логика без AppKit — под юнит-тестами. `apply` возвращает nil, если преобразование
/// неприменимо к входу (битый JSON/Base64) — вызывающий тогда ничего не делает.
public enum TextTransform: String, CaseIterable {
    // Регистр
    case upper, lower, title, camel, snake, kebab, constant, slug
    // Чистка
    case trim, collapseSpaces, removeEmptyLines, joinLines
    // Кодирование
    case jsonPretty, jsonMinify, urlEncode, urlDecode, base64Encode, base64Decode, jwtDecode
    // Строки
    case sortLines, sortLinesDesc, dedupeLines, reverseLines
    // Пунктуация: добавить символ в конец каждой строки
    case appendPeriod, appendComma, appendSemicolon

    /// Ключ локализации отображаемого имени.
    public var titleKey: String { "transform.\(rawValue)" }

    /// Категория для группировки в UI (заголовки-секции). Порядок `allCases` совпадает с
    /// группировкой, так что секции идут: регистр → чистка → кодирование → строки → пунктуация.
    public enum Category: String, CaseIterable {
        case caseType, cleanup, encoding, lines, punctuation
        public var titleKey: String { "transform.category.\(rawValue)" }
    }

    public var category: Category {
        switch self {
        case .upper, .lower, .title, .camel, .snake, .kebab, .constant, .slug: return .caseType
        case .trim, .collapseSpaces, .removeEmptyLines, .joinLines: return .cleanup
        case .jsonPretty, .jsonMinify, .urlEncode, .urlDecode, .base64Encode, .base64Decode, .jwtDecode:
            return .encoding
        case .sortLines, .sortLinesDesc, .dedupeLines, .reverseLines: return .lines
        case .appendPeriod, .appendComma, .appendSemicolon: return .punctuation
        }
    }

    /// Подходит ли способ под строку поиска. Матчим и по локализованному названию (передаётся
    /// из UI-слоя), и по `rawValue` — чтобы английские термины (`jwt`, `base64`, `json`, `url`,
    /// `sort`) находились даже когда интерфейс на русском. Пустой запрос — совпадает всё.
    public func matches(query: String, localizedTitle: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return localizedTitle.lowercased().contains(q) || rawValue.lowercased().contains(q)
    }

    /// Применяет преобразование. nil — вход не подходит (напр. невалидный JSON).
    public func apply(to text: String) -> String? {
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        case .camel: return Self.camelCase(text)
        case .snake: return Self.joinWords(text, separator: "_", uppercase: false)
        case .kebab: return Self.joinWords(text, separator: "-", uppercase: false)
        case .constant: return Self.joinWords(text, separator: "_", uppercase: true)
        case .slug: return Self.slug(text)

        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseSpaces: return Self.collapseSpaces(text)
        case .removeEmptyLines: return Self.removeEmptyLines(text)
        case .joinLines: return Self.joinLines(text)

        case .jsonPretty: return Self.json(text, pretty: true)
        case .jsonMinify: return Self.json(text, pretty: false)
        case .urlEncode: return Self.urlEncode(text)
        case .urlDecode: return text.removingPercentEncoding
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return Self.base64Decode(text)
        case .jwtDecode: return Self.jwtDecode(text)

        case .sortLines: return Self.sortLines(text, ascending: true)
        case .sortLinesDesc: return Self.sortLines(text, ascending: false)
        case .dedupeLines: return Self.dedupeLines(text)
        case .reverseLines: return Self.lines(text).reversed().joined(separator: "\n")

        case .appendPeriod: return Self.appendToLines(text, ".")
        case .appendComma: return Self.appendToLines(text, ",")
        case .appendSemicolon: return Self.appendToLines(text, ";")
        }
    }

    // MARK: - Слова / регистр

    /// Разбивает на «слова» по неалфанумерическим символам И границам camelCase.
    static func words(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var prevAlnumLower = false
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && prevAlnumLower, !current.isEmpty {
                    result.append(current); current = ""
                }
                current.append(ch)
                prevAlnumLower = ch.isLowercase || ch.isNumber
            } else {
                if !current.isEmpty { result.append(current); current = "" }
                prevAlnumLower = false
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func joinWords(_ text: String, separator: String, uppercase: Bool) -> String {
        let parts = words(text).map { uppercase ? $0.uppercased() : $0.lowercased() }
        return parts.joined(separator: separator)
    }

    static func camelCase(_ text: String) -> String {
        let w = words(text)
        guard let first = w.first else { return "" }
        let head = first.lowercased()
        let tail = w.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return ([head] + tail).joined()
    }

    static func slug(_ text: String) -> String {
        words(text).map { $0.lowercased() }.joined(separator: "-")
    }

    // MARK: - Чистка

    static func collapseSpaces(_ text: String) -> String {
        // Схлопываем подряд идущие пробелы/табы в один пробел; переносы строк и края не трогаем.
        var result = ""
        var lastWasSpace = false
        for ch in text {
            if ch == " " || ch == "\t" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result
    }

    static func removeEmptyLines(_ text: String) -> String {
        lines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }

    static func joinLines(_ text: String) -> String {
        collapseSpaces(lines(text).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " "))
    }

    // MARK: - Строки

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func sortLines(_ text: String, ascending: Bool) -> String {
        let sorted = lines(text).sorted {
            $0.localizedStandardCompare($1) == (ascending ? .orderedAscending : .orderedDescending)
        }
        return sorted.joined(separator: "\n")
    }

    static func dedupeLines(_ text: String) -> String {
        var seen = Set<String>()
        return lines(text).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    /// Добавляет `suffix` в конец каждой непустой строки. Пустые/пробельные строки не трогает;
    /// строку, уже оканчивающуюся на этот символ, не дублирует. Хвостовые пробелы срезает,
    /// чтобы символ вставал сразу за содержимым.
    static func appendToLines(_ text: String, _ suffix: Character) -> String {
        lines(text).map { line in
            let trimmedRight = String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
            guard !trimmedRight.isEmpty else { return line }
            guard trimmedRight.last != suffix else { return trimmedRight }
            return trimmedRight + String(suffix)
        }.joined(separator: "\n")
    }

    // MARK: - Кодирование

    static func json(_ text: String, pretty: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        var options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
        options.insert(.fragmentsAllowed)
        if pretty { options.insert(.withoutEscapingSlashes) }
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: options),
              let string = String(data: out, encoding: .utf8) else { return nil }
        return string
    }

    /// Кодирует, экранируя всё, кроме «незарезервированных» (`A-Za-z0-9-._~`), — так `&`, `=`,
    /// пробел тоже превращаются в %XX (в отличие от `.urlQueryAllowed`).
    static func urlEncode(_ text: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    static func base64Decode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Раскодирует JWT (`header.payload.signature`): base64url-декодирует header и payload и
    /// красиво форматирует их JSON. Подпись бинарна и не декодируется — показываем как есть.
    /// nil — вход не похож на JWT (меньше двух сегментов или сегмент не base64url-JSON).
    static func jwtDecode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: ".")
        guard parts.count >= 2,
              let header = decodeJWTSegment(parts[0]),
              let payload = decodeJWTSegment(parts[1])
        else { return nil }
        var out = "// header\n\(header)\n\n// payload\n\(payload)"
        if parts.count >= 3, !parts[2].isEmpty {
            out += "\n\n// signature\n\(parts[2])"
        }
        return out
    }

    /// base64url-декодирует один сегмент JWT (`-`/`_` вместо `+`/`/`, без паддинга) и красиво
    /// форматирует его как JSON; при неудаче форматирования возвращает сырую строку.
    static func decodeJWTSegment(_ segment: String) -> String? {
        var s = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: s),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return json(raw, pretty: true) ?? raw
    }
}
