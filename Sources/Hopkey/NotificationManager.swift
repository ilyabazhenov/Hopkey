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

    /// Показать уведомление по найденным тикетам.
    func notify(matches: [TicketMatch]) {
        guard !matches.isEmpty else { return }

        guard let center else {
            // Фолбэк: уведомления недоступны — просто открыть.
            URLOpener.open(matches.map(\.url))
            return
        }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else {
                URLOpener.open(matches.map(\.url))
                return
            }

            let content = UNMutableNotificationContent()
            if matches.count == 1 {
                content.title = "Открыть тикет"
                content.body = matches[0].id
            } else {
                content.title = "Открыть тикеты (\(matches.count))"
                content.body = matches.map(\.id).joined(separator: ", ")
            }
            content.userInfo = ["urls": matches.map { $0.url.absoluteString }]
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

    // Клик по баннеру → открыть ссылки.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let strings = response.notification.request.content.userInfo["urls"] as? [String] {
            let urls = strings.compactMap(URL.init(string:))
            URLOpener.open(urls)
        }
        completionHandler()
    }
}

/// Небольшая обёртка над открытием URL в браузере по умолчанию.
enum URLOpener {
    static func open(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }
}
