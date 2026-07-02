import CoreAudio
import Foundation

/// Системный мьют микрофона через CoreAudio: глушим устройство ввода по умолчанию на уровне
/// драйвера, поэтому «немым» его видят все приложения сразу. Захвата звука нет — **TCC-разрешение
/// на микрофон не требуется**.
///
/// Основной путь — свойство `kAudioDevicePropertyMute` (scope Input). Часть устройств (AirPods,
/// многие USB-микрофоны) его не поддерживают — тогда фолбэк: обнуление входной громкости
/// (`kAudioDevicePropertyVolumeScalar`) с сохранением прежнего значения для размьюта.
final class MicrophoneController {

    /// Вызывается при изменении состояния мьюта — для иконки статус-бара и строки в панели/меню.
    var onStateChange: ((Bool) -> Void)?

    private(set) var isMuted: Bool = false {
        didSet { if oldValue != isMuted { onStateChange?(isMuted) } }
    }

    /// Сохранённая входная громкость для восстановления при размьюте через фолбэк-путь.
    private var savedVolume: Float32 = 1.0

    init() {
        // Начальное состояние: если устройство умеет Mute — читаем его; иначе считаем «не замьючен».
        if let device = defaultInputDevice(), let muted = readMuteProperty(device) {
            isMuted = muted
        }
    }

    func toggle() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        guard let device = defaultInputDevice() else {
            NSLog("Hopkey.mic: нет устройства ввода по умолчанию — мьют невозможен")
            return
        }

        if setMuteProperty(device, muted: muted) {
            let readBack = readMuteProperty(device)
            NSLog("Hopkey.mic: Mute=\(muted) через kAudioDevicePropertyMute, read-back=\(String(describing: readBack))")
            isMuted = muted
            return
        }

        // Фолбэк: громкость. При мьюте сохраняем текущее значение, при размьюте — восстанавливаем.
        if muted { savedVolume = readInputVolume(device) ?? savedVolume }
        let target: Float32 = muted ? 0 : savedVolume
        if setInputVolume(device, target) {
            let readBack = readInputVolume(device)
            NSLog("Hopkey.mic: Mute=\(muted) через VolumeScalar=\(target), read-back=\(String(describing: readBack))")
            isMuted = muted
        } else {
            NSLog("Hopkey.mic: устройство \(device) не поддерживает ни Mute, ни VolumeScalar на входе")
        }
    }

    // MARK: - CoreAudio

    private func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func setMuteProperty(_ device: AudioDeviceID, muted: Bool) -> Bool {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
        else { return false }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    private func readMuteProperty(_ device: AudioDeviceID) -> Bool? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// Элементы входной громкости, которые пробуем по очереди: мастер (0) и первые два канала —
    /// у части устройств мастер-элемент не настраивается, а каналы 1/2 — да.
    private static let volumeElements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

    private func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element)
    }

    private func setInputVolume(_ device: AudioDeviceID, _ volume: Float32) -> Bool {
        var didSet = false
        for element in Self.volumeElements {
            var addr = volumeAddress(element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue
            else { continue }
            var value = volume
            if AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                didSet = true
            }
        }
        return didSet
    }

    private func readInputVolume(_ device: AudioDeviceID) -> Float32? {
        for element in Self.volumeElements {
            var addr = volumeAddress(element: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }
}
