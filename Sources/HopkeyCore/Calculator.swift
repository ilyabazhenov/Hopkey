import Foundation

/// Мини-калькулятор строки поиска палитры: безопасно вычисляет арифметику (`+ - * / %`, скобки,
/// унарный минус, десятичные). Свой рекурсивно-нисходящий парсер, а НЕ `NSExpression`: последний на
/// «мусорном» вводе бросает ObjC-исключение, которое из Swift не поймать (краш всего приложения).
///
/// Возвращает отформатированную строку результата или nil, если ввод не похож на выражение (буквы,
/// не разобрался, деление на ноль → не число). «Похоже на выражение» = есть хотя бы один оператор
/// или скобка И хотя бы одна цифра, иначе бесполезно показывать «= 5» для запроса «5».
public enum Calculator {
    public static func evaluate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        // Ранний отсев: только разрешённые символы (цифры, операторы, скобки, точка, пробел).
        let allowed = Set("0123456789+-*/%(). ")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Должен быть оператор/скобка и цифра — иначе это не «вычисление».
        guard trimmed.contains(where: { "+-*/%()".contains($0) }),
              trimmed.contains(where: { $0.isNumber }) else { return nil }

        var parser = Parser(Array(trimmed))
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return format(value)
    }

    /// Целое печатаем без дробной части; иначе — кратчайшее представление (`%g`, до 10 значащих).
    private static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.10g", value)
    }

    /// Рекурсивно-нисходящий разбор:
    ///   expression = term (('+' | '-') term)*
    ///   term       = factor (('*' | '/' | '%') factor)*
    ///   factor     = ('+' | '-') factor | primary
    ///   primary    = number | '(' expression ')'
    private struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ chars: [Character]) { self.chars = chars }

        var isAtEnd: Bool {
            var i = pos
            while i < chars.count, chars[i] == " " { i += 1 }
            return i >= chars.count
        }

        private mutating func skipSpaces() {
            while pos < chars.count, chars[pos] == " " { pos += 1 }
        }

        private func peek() -> Character? {
            var i = pos
            while i < chars.count, chars[i] == " " { i += 1 }
            return i < chars.count ? chars[i] : nil
        }

        private mutating func consume(_ ch: Character) -> Bool {
            skipSpaces()
            guard pos < chars.count, chars[pos] == ch else { return false }
            pos += 1
            return true
        }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                _ = consume(op)
                guard let rhs = parseTerm() else { return nil }
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                _ = consume(op)
                guard let rhs = parseFactor() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default:  value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        private mutating func parseFactor() -> Double? {
            if let op = peek(), op == "+" || op == "-" {
                _ = consume(op)
                guard let operand = parseFactor() else { return nil }
                return op == "-" ? -operand : operand
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            if consume("(") {
                guard let value = parseExpression(), consume(")") else { return nil }
                return value
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            skipSpaces()
            let start = pos
            while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { pos += 1 }
            guard pos > start else { return nil }
            return Double(String(chars[start..<pos]))
        }
    }
}
