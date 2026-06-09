import AppKit
import UserNotifications
import HopkeyCore

/// Показывает кликабельный баннер «Открыть тикет». Клик по баннеру открывает ссылку(и).
/// Если уведомления недоступны (нет авторизации / запуск вне бандла) — открывает напрямую,
/// чтобы приложение оставалось рабочим в любом случае.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    private var center: UNUserNotificationCenter? {
        // Вне .app-бандла UNUserNotificationCenter недоступен и кидает исключение — гасим.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Запрашивает разрешение на уведомления (один раз при старте).
    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Показать кликабельное уведомление по найденным тикетам.
    /// Клик по баннеру выполнит `action` — открыть в браузере или скопировать ссылку.
    func notify(matches: [TicketMatch], action: TicketAction) {
        guard !matches.isEmpty else { return }

        guard let center else {
            // Фолбэк: уведомления недоступны — выполняем действие сразу.
            perform(action, urls: matches.map(\.url))
            return
        }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else {
                self.perform(action, urls: matches.map(\.url))
                return
            }

            let content = UNMutableNotificationContent()
            let count = matches.count
            switch action {
            case .openInBrowser:
                content.title = count == 1 ? "Нажмите, чтобы открыть тикет" : "Нажмите, чтобы открыть тикеты (\(count))"
            case .copyURL:
                content.title = count == 1 ? "Нажмите, чтобы скопировать ссылку" : "Нажмите, чтобы скопировать ссылки (\(count))"
            }
            content.body = matches.map(\.id).joined(separator: ", ")
            content.userInfo = [
                "urls": matches.map { $0.url.absoluteString },
                "action": action.rawValue,
            ]
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    /// Выполняет действие над ссылками. Копирование URL в буфер безопасно: целиком
    /// он не является ключом тикета, поэтому наблюдатель буфера его не подхватит.
    private func perform(_ action: TicketAction, urls: [URL]) {
        switch action {
        case .openInBrowser:
            URLOpener.open(urls)
        case .copyURL:
            URLOpener.copy(urls.map(\.absoluteString).joined(separator: "\n"))
        }
    }

    /// Короткое подтверждение, что ссылки скопированы. Клика не требует.
    /// Если уведомления недоступны — тихо ничего не делает (буфер уже заполнен).
    func confirmCopy(matches: [TicketMatch]) {
        guard !matches.isEmpty, let center else { return }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = matches.count == 1 ? "Ссылка скопирована" : "Ссылки скопированы (\(matches.count))"
            content.body = matches.map(\.id).joined(separator: ", ")
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    // Показывать баннер, даже когда приложение активно.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // Клик по баннеру → выполнить сохранённое действие (открыть или скопировать).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let strings = info["urls"] as? [String] {
            let urls = strings.compactMap(URL.init(string:))
            let action = TicketAction(rawValue: info["action"] as? String ?? "") ?? .openInBrowser
            perform(action, urls: urls)
        }
        completionHandler()
    }
}

/// Небольшая обёртка над действиями с найденными тикетами.
enum URLOpener {
    static func open(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    /// Кладёт строку в общий буфер обмена как обычный текст.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
