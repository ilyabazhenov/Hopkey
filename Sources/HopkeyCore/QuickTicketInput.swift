import Foundation

/// Чистая логика разбора ручного ввода (окно «Открыть тикет…»).
///
/// Пользователь вводит либо что-то целиком (`PROJ-123`, `#42`), либо только число
/// (`123`). В первом случае текст парсится строго по всем шаблонам; во втором
/// число подставляется в выбранный шаблон — если заполнимый шаблон ровно один,
/// сразу, иначе нужен выбор.
///
/// Без UI и состояния — легко тестируется.
public enum QuickTicketInput {

    /// Результат разбора ввода.
    public enum Resolution: Equatable {
        /// Готово открывать/копировать.
        case resolved(TicketMatch)
        /// Введено только число, а заполнимых шаблонов больше одного — нужен выбор.
        case needsTemplate(number: String)
        /// Пустой ввод.
        case empty
        /// Не похоже на ключ (мусор или нет ни одного подходящего шаблона).
        case invalid
    }

    /// Разбирает произвольный ввод из поля.
    public static func resolve(_ raw: String, templates: [LinkTemplate]) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let valid = templates.filter(\.isValid)

        // Чистое число: нужен шаблон. Один заполнимый — собираем сразу,
        // несколько — просим выбрать, ни одного — невалидно.
        if trimmed.allSatisfy(\.isNumber) {
            let fillable = fillableTemplates(in: valid)
            switch fillable.count {
            case 0: return .invalid
            case 1: return resolve(number: trimmed, template: fillable[0])
            default: return .needsTemplate(number: trimmed)
            }
        }

        // Иначе считаем, что введён ключ целиком — парсим строго (весь текст = ровно ключ).
        if let match = TicketParser.exactMatch(in: trimmed, templates: valid) {
            return .resolved(match)
        }
        return .invalid
    }

    /// Собирает совпадение по числу и явно выбранному шаблону (после выбора в окне).
    public static func resolve(number: String, template: LinkTemplate) -> Resolution {
        let digits = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let match = template.fillMatch(number: digits)
        else { return .invalid }
        return .resolved(match)
    }

    /// Заполнимые числом шаблоны (с единственным плейсхолдером `$1`) для выбора в окне,
    /// в порядке конфига.
    public static func fillableTemplates(in templates: [LinkTemplate]) -> [LinkTemplate] {
        templates.filter(\.isFillableByNumber)
    }
}
