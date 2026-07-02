import Foundation
import IOKit.pwr_mgt

/// «Не давать засыпать»: держит IOKit power assertion, пока включено — дисплей (и система) не
/// уходят в сон по простою (аналог `caffeinate -d`). Ассершен освобождается при выключении и
/// в `deinit`, иначе «завис» бы в системе после выхода.
final class KeepAwakeController {

    /// Вызывается при изменении состояния — для иконки/строки в панели.
    var onStateChange: ((Bool) -> Void)?

    private(set) var isOn = false {
        didSet { if oldValue != isOn { onStateChange?(isOn) } }
    }

    private var assertionID = IOPMAssertionID(0)

    func toggle() { setOn(!isOn) }

    func setOn(_ on: Bool) {
        on ? enable() : disable()
    }

    private func enable() {
        guard !isOn else { return }
        var id = IOPMAssertionID(0)
        let reason = "Hopkey: не давать засыпать" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &id)
        if result == kIOReturnSuccess {
            assertionID = id
            isOn = true
            NSLog("Hopkey.awake: ассершен создан (id=\(id))")
        } else {
            NSLog("Hopkey.awake: не удалось создать power assertion (\(result))")
        }
    }

    private func disable() {
        guard isOn else { return }
        IOPMAssertionRelease(assertionID)
        NSLog("Hopkey.awake: ассершен освобождён (id=\(assertionID))")
        assertionID = IOPMAssertionID(0)
        isOn = false
    }

    deinit {
        if isOn { IOPMAssertionRelease(assertionID) }
    }
}
