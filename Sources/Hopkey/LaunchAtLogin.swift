import ServiceManagement

/// Автозапуск приложения при входе в систему через `SMAppService`.
/// Состояние не дублируется в `UserDefaults` — единственный источник правды это сама
/// служба, поэтому `isEnabled` всегда читает живой статус, а не кешированный флаг.
enum LaunchAtLogin {

    /// Зарегистрирован ли автозапуск сейчас.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Включает или выключает автозапуск. Ошибки логирует и проглатывает —
    /// вызывающему достаточно перечитать `isEnabled`, чтобы показать актуальное состояние.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login error: \(error.localizedDescription)")
        }
    }
}
