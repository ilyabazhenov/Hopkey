import Foundation

/// Чистая логика разбора ручного ввода тикета (окно «Открыть тикет…»).
///
/// Пользователь вводит либо ключ целиком (`PROJ-123`), либо только номер (`123`).
/// В первом случае ключ парсится строго; во втором нужен префикс — если во всём
/// конфиге он ровно один, ключ собирается сразу, иначе требуется выбор проекта.
///
/// Без UI и состояния — легко тестируется.
public enum QuickTicketInput {

    /// Результат разбора ввода.
    public enum Resolution: Equatable {
        /// Готово открывать/копировать.
        case resolved(TicketMatch)
        /// Введён только номер, а подходящих (проект, префикс) больше одного — нужен выбор.
        case needsProject(number: String)
        /// Пустой ввод.
        case empty
        /// Не похоже на ключ тикета (мусор или нет ни одного валидного проекта).
        case invalid
    }

    /// Разбирает произвольный ввод из поля.
    public static func resolve(_ raw: String, projects: [JiraProject]) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let validProjects = projects.filter(\.isValid)

        // Чистый номер: нужен префикс. Один (проект, префикс) во всём конфиге — собираем сразу,
        // несколько — просим выбрать, ни одного — невалидно.
        if trimmed.allSatisfy(\.isNumber) {
            let pairs = pickerPairs(in: validProjects)
            switch pairs.count {
            case 0: return .invalid
            case 1: return resolve(number: trimmed, project: pairs[0].project, prefix: pairs[0].prefix)
            default: return .needsProject(number: trimmed)
            }
        }

        // Иначе считаем, что введён ключ целиком — парсим строго (весь текст = ровно ключ).
        if let match = TicketParser.exactMatch(in: trimmed, projects: validProjects) {
            return .resolved(match)
        }
        return .invalid
    }

    /// Собирает тикет по номеру и явно выбранным проекту/префиксу (после выбора в окне).
    public static func resolve(number: String, project: JiraProject, prefix: String) -> Resolution {
        let digits = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), !cleanPrefix.isEmpty,
              let match = TicketParser.makeMatch(id: "\(cleanPrefix)-\(digits)", baseURL: project.baseURL)
        else { return .invalid }
        return .resolved(match)
    }

    /// Все пары (проект, префикс) для выбора при вводе одного номера —
    /// по одной на каждый префикс каждого валидного проекта, в порядке конфига.
    public static func pickerPairs(in projects: [JiraProject]) -> [(project: JiraProject, prefix: String)] {
        projects.filter(\.isValid).flatMap { project in
            project.prefixes.map { (project: project, prefix: $0) }
        }
    }
}
