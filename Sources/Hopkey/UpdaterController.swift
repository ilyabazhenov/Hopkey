import AppKit
import Sparkle

/// Тонкая обёртка над Sparkle. Хранит `SPUStandardUpdaterController`, который сам
/// поднимает фоновую проверку обновлений по расписанию (читает `SUFeedURL` и
/// `SUPublicEDKey` из Info.plist — их прописывает build.sh).
final class UpdaterController: NSObject, SPUStandardUserDriverDelegate {

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // startingUpdater: true — Sparkle запускает апдейтер сразу и при первом
        // запуске показывает системный запрос разрешения на автопроверку.
        // userDriverDelegate: self — чтобы активировать приложение перед показом
        // окна обновления (см. ниже).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    private var updater: SPUUpdater { controller.updater }

    /// Ручная проверка обновлений (пункт меню «Проверить обновления…»).
    /// Активируем приложение заранее: делегат `…WillHandleShowingUpdate` срабатывает
    /// только когда обновление найдено, а диалоги «последняя версия»/ошибки идут мимо
    /// него — без этого они тоже всплыли бы под чужим окном.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Состояние автоматической проверки — для галочки в меню.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Приложение работает как `.accessory` и почти никогда не активно, поэтому окно
    /// Sparkle всплывало бы под окном текущей программы. Перед показом любого окна
    /// обновления (ручная проверка или фоновая по расписанию) активируем приложение —
    /// тогда диалог выходит поверх.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
