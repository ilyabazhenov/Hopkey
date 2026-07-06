import Foundation

/// Нечёткий (subsequence) матчер для строки поиска палитры. Общий скоринг для команд, сниппетов и
/// приложений — чтобы результаты разных типов можно было сравнивать в одном плоском списке.
///
/// `score` возвращает nil, если запрос не является подпоследовательностью кандидата (совсем не
/// подходит), иначе — целочисленную оценку: чем выше, тем лучше. Матч регистронезависимый и
/// нечувствителен к диакритике (é == e), поэтому «saf» находит «Safari», а «телега» — «Telegram»
/// не найдёт (разные алфавиты), но «tele» найдёт.
public enum FuzzyMatch {
    /// Нормализация обеих сторон: тримминг, нижний регистр, сворачивание диакритики.
    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Символ-граница слова: следующий за ним матч получает бонус (начало «слова» в имени).
    private static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "." || ch == "/" || ch == "("
    }

    /// Оценка совпадения `query` в `candidate` (nil — не подпоследовательность). Награда за
    /// непрерывные серии, старт на границе слова, префикс и точное равенство; лёгкий бонус за
    /// короткое имя (при равных — «Notes» выигрывает у «Notes Helper»).
    public static func score(query rawQuery: String, candidate rawCandidate: String) -> Int? {
        let q = normalize(rawQuery)
        let c = normalize(rawCandidate)
        guard !q.isEmpty else { return 0 }
        guard !c.isEmpty else { return nil }

        let qs = Array(q)
        let cs = Array(c)
        var qi = 0
        var score = 0
        var prevMatch = -2
        var streak = 0

        for (ci, ch) in cs.enumerated() {
            guard qi < qs.count, ch == qs[qi] else { continue }
            var bonus = 1
            if ci == prevMatch + 1 {
                streak += 1
                bonus += streak * 3          // непрерывная серия — сильный сигнал
            } else {
                streak = 0
            }
            if ci == 0 || isBoundary(cs[ci - 1]) { bonus += 8 }  // старт слова
            score += bonus
            prevMatch = ci
            qi += 1
        }
        guard qi == qs.count else { return nil }  // не все символы запроса найдены по порядку

        if c.hasPrefix(q) { score += 15 }
        if c == q { score += 30 }
        score += max(0, 10 - cs.count / 4)  // короче — чуть лучше
        return score
    }

    /// Лучшая оценка запроса по набору кандидатов (напр. локализованное + базовое имя приложения);
    /// nil — если запрос не подходит ни под один. Позволяет матчить «кальку» И «calc».
    public static func bestScore(query: String, candidates: [String]) -> Int? {
        candidates.compactMap { score(query: query, candidate: $0) }.max()
    }
}
