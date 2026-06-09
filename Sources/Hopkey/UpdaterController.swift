import Sparkle

/// Тонкая обёртка над Sparkle. Хранит `SPUStandardUpdaterController`, который сам
/// поднимает фоновую проверку обновлений по расписанию (читает `SUFeedURL` и
/// `SUPublicEDKey` из Info.plist — их прописывает build.sh).
final class UpdaterController {

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true — Sparkle запускает апдейтер сразу и при первом
        // запуске показывает системный запрос разрешения на автопроверку.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private var updater: SPUUpdater { controller.updater }

    /// Ручная проверка обновлений (пункт меню «Проверить обновления…»).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Состояние автоматической проверки — для галочки в меню.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
}
