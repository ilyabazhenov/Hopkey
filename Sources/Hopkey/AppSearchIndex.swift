import AppKit
import HopkeyCore

/// Одно приложение в индексе поиска палитры. `name` — отображаемое (локализованное) имя;
/// `searchNames` — по чему матчим: локализованное имя + базовое имя файла на диске, чтобы
/// «Калькулятор» находился и по «кальку», и по «calc» (у системных приложений имя файла латиницей,
/// а отображаемое — на языке системы).
struct AppEntry {
    let name: String
    let url: URL
    let searchNames: [String]
}

/// Индекс установленных приложений для строки поиска палитры. Сканирует стандартные папки один раз
/// (в фоне при первом показе панели), кэширует результат и матчит запрос через `FuzzyMatch`.
/// Иконку не держим в кэше — тянем лениво при отрисовке строки (`NSWorkspace.icon`), их немного.
final class AppSearchIndex {
    private var apps: [AppEntry] = []
    private var started = false

    /// Где ищем «.app». Вложенность на один уровень — ради `Utilities` внутри системных папок.
    private static let roots: [URL] = {
        var urls = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent("Applications"))
        return urls
    }()

    /// Строит индекс в фоне (однократно). Безопасно звать при каждом показе панели — после первого
    /// раза no-op. Результат публикуем на главном потоке (чтение `apps` идёт с него же).
    func warmUp() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = Self.scan()
            DispatchQueue.main.async { self?.apps = scanned }
        }
    }

    /// Топ-N приложений по убыванию оценки совпадения; при равной оценке — по имени.
    func search(_ query: String, limit: Int = 6) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let scored: [(app: AppEntry, score: Int)] = apps.compactMap { app in
            guard let score = FuzzyMatch.bestScore(query: q, candidates: app.searchNames) else { return nil }
            return (app, score)
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.app.name < $1.app.name }
            .prefix(limit)
            .map { $0.app }
    }

    private static func scan() -> [AppEntry] {
        var result: [String: AppEntry] = [:]  // дедуп по имени; порядок roots задаёт приоритет
        for root in roots { collect(root, depth: 0, into: &result) }
        return Array(result.values)
    }

    private static func collect(_ dir: URL, depth: Int, into result: inout [String: AppEntry]) {
        guard depth <= 1 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }
        for url in items {
            if url.pathExtension == "app" {
                let base = url.deletingPathExtension().lastPathComponent
                // Локализованное отображаемое имя (в Finder «.app» скрыт → уже без расширения).
                var localized = fm.displayName(atPath: url.path)
                if localized.hasSuffix(".app") { localized = String(localized.dropLast(4)) }
                let display = localized.isEmpty ? base : localized
                // Матчим по локализованному И по базовому имени (уникально, без пустых).
                var names = [display, base].filter { !$0.isEmpty }
                names = Array(NSOrderedSet(array: names)) as? [String] ?? names
                if result[base] == nil {
                    result[base] = AppEntry(name: display, url: url, searchNames: names)
                }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collect(url, depth: depth + 1, into: &result)  // напр. Utilities
            }
        }
    }
}
