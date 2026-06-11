import Foundation

/// Один шаблон распознавания: regex → URL. Заменяет прежний жёстко зашитый
/// «проект Jira» — теперь формула живёт в данных, поэтому Hopkey открывает не
/// только Jira, но и любые ID (GitHub `#123`, CVE и т.п.). Jira — просто пресет.
///
/// `pattern` ищется в тексте; группы совпадения подставляются в `url`
/// (`$0` — всё совпадение, `$1…` — захваченные группы) с percent-encoding.
public struct LinkTemplate: Codable, Equatable {
    /// Человекочитаемое имя — для выпадашки окна ввода и таблицы настроек.
    public var name: String
    /// Регулярное выражение, например `PROJ-(\d+)` или `#(\d+)`.
    public var pattern: String
    /// Шаблон URL с плейсхолдерами `$0…$9`, например `https://jira/browse/PROJ-$1`.
    public var url: String
    /// Обернуть `pattern` в границы `(?<![A-Za-z0-9])…(?![A-Za-z0-9])`,
    /// чтобы `XPROJ-1` не ловился. Для большинства ключей — `true`.
    public var wholeWord: Bool
    /// Нормализовать всё совпадение (`$0`) в ВЕРХНИЙ регистр — и в `id`, и в URL
    /// (нужно Jira-ключам и CVE). Захваченные подгруппы `$1+` остаются как есть.
    public var uppercase: Bool
    /// Участвует ли шаблон в распознавании.
    public var enabled: Bool

    public init(name: String, pattern: String, url: String,
                wholeWord: Bool = true, uppercase: Bool = false, enabled: Bool = true) {
        self.name = name
        self.pattern = pattern
        self.url = url
        self.wholeWord = wholeWord
        self.uppercase = uppercase
        self.enabled = enabled
    }

    /// Причина невалидности шаблона (для редактора) — `nil`, если всё в порядке.
    public enum Invalid: Equatable {
        case emptyPattern   // пустой regex
        case invalidRegex   // regex не компилируется
        case emptyURL       // пустой URL
        case noPlaceholder  // в URL нет ни одного $0…$9
    }

    /// Что не так с шаблоном; `nil` — валиден.
    public var validation: Invalid? {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyPattern }
        if compiledRegex() == nil { return .invalidRegex }
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyURL }
        if urlPlaceholders.isEmpty { return .noPlaceholder }
        return nil
    }

    /// Пригоден к использованию: см. `validation`.
    public var isValid: Bool { validation == nil }

    /// Можно ли заполнить шаблон одним числом в окне ручного ввода — то есть
    /// `url` использует ровно один плейсхолдер `$1` (типичная форма `…/PROJ-$1`,
    /// `…/issues/$1`). Шаблоны на `$0`/несколько групп открываются полным вводом и детектом.
    public var isFillableByNumber: Bool {
        isValid && urlPlaceholders == [1]
    }

    /// Имя для показа: само `name`, либо `pattern` как фолбэк, если имя пустое.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? pattern : trimmed
    }

    // MARK: - Сборка совпадений

    /// Скомпилированный regex (с границами слова при `wholeWord`). Кривой паттерн → `nil`.
    /// Обёртка `(?:…)` не вводит новых групп, поэтому пользовательские `$1…` сохраняют номера.
    func compiledRegex() -> NSRegularExpression? {
        let raw = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let wrapped = wholeWord ? "(?<![A-Za-z0-9])(?:\(raw))(?![A-Za-z0-9])" : raw
        return try? NSRegularExpression(pattern: wrapped, options: [.caseInsensitive])
    }

    /// Собирает `TicketMatch` из найденного в тексте совпадения.
    func match(from result: NSTextCheckingResult, in text: NSString) -> TicketMatch? {
        var groups: [String] = []
        for i in 0..<result.numberOfRanges {
            let range = result.range(at: i)
            groups.append(range.location == NSNotFound ? "" : text.substring(with: range))
        }
        // uppercase нормализует всё совпадение ($0) — и отображаемый id, и его
        // подстановку в URL (для $0-шаблонов вроде CVE). Захваченные подгруппы
        // ($1+) не трогаем: они могут быть регистрозависимы (имена репозиториев и т.п.).
        if uppercase, !groups.isEmpty { groups[0] = groups[0].uppercased() }
        let id = groups.first ?? ""
        guard let url = buildURL(groups: groups) else { return nil }
        return TicketMatch(id: id, url: url)
    }

    /// Совпадает ли шаблон со ВСЕМ текстом целиком (без пробелов по краям). Нужно окну
    /// ввода для предвыбора: выделил полный ключ `ONECOLLECT-123` → сразу выбран его шаблон.
    public func matchesWhole(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let regex = compiledRegex() else { return false }
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.firstMatch(in: trimmed, options: [], range: full)?.range == full
    }

    /// Собирает `TicketMatch` из одного числа (ручной ввод): число идёт в `$1`.
    /// `id` для показа — последний компонент пути URL (`…/browse/PROJ-123` → `PROJ-123`).
    func fillMatch(number: String) -> TicketMatch? {
        guard let url = buildURL(groups: ["", number]) else { return nil }
        let last = url.pathComponents.last { $0 != "/" && !$0.isEmpty } ?? number
        return TicketMatch(id: uppercase ? last.uppercased() : last, url: url)
    }

    /// Подставляет группы в `url`: `$n` → `groups[n]` с percent-encoding значения
    /// (литералы шаблона, включая `://` и `/`, не трогаем). Возвращает `nil`, если
    /// итог — невалидный URL (например, пробел в литеральной части адреса).
    func buildURL(groups: [String]) -> URL? {
        let template = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count,
               let d = chars[i + 1].wholeNumberValue, (0...9).contains(d) {
                let value = d < groups.count ? groups[d] : ""
                out += value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return URL(string: out)
    }

    /// Номера плейсхолдеров `$0…$9`, встречающиеся в `url`.
    var urlPlaceholders: Set<Int> {
        var set = Set<Int>()
        let chars = Array(url)
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count,
               let d = chars[i + 1].wholeNumberValue, (0...9).contains(d) {
                set.insert(d)
                i += 2
            } else {
                i += 1
            }
        }
        return set
    }

    // MARK: - Пресеты

    /// Готовые заготовки для кнопки «Из пресета». Пользователь правит домен/репозиторий.
    public static let presets: [LinkTemplate] = [
        LinkTemplate(name: "Jira", pattern: "PROJ-(\\d+)",
                     url: "https://YOUR-JIRA/browse/PROJ-$1",
                     wholeWord: true, uppercase: true),
        LinkTemplate(name: "GitHub issue", pattern: "#(\\d+)",
                     url: "https://github.com/OWNER/REPO/issues/$1",
                     wholeWord: true, uppercase: false),
        LinkTemplate(name: "GitLab issue", pattern: "#(\\d+)",
                     url: "https://gitlab.com/OWNER/REPO/-/issues/$1",
                     wholeWord: true, uppercase: false),
        LinkTemplate(name: "CVE", pattern: "CVE-\\d{4}-\\d+",
                     url: "https://nvd.nist.gov/vuln/detail/$0",
                     wholeWord: true, uppercase: true),
    ]
}
