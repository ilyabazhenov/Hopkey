import CoreAudio
import Foundation

/// Аудиоустройство: id для CoreAudio, имя и тип шины (для иконки).
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    /// `kAudioDevicePropertyTransportType` (bltn/blue/usb /hdmi/airp…).
    let transport: UInt32
}

/// Переключение аудиоустройств (вход/выход) через CoreAudio: перечислить, узнать текущее,
/// назначить дефолтное. По образцу `MicrophoneController`. TCC не требует.
final class AudioDeviceController {

    /// Устройства с выходными потоками (динамики/наушники).
    func outputDevices() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }
    /// Устройства с входными потоками (микрофоны).
    func inputDevices() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeInput) }

    func currentOutputDeviceID() -> AudioDeviceID? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }
    func currentInputDeviceID() -> AudioDeviceID? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Делает устройство дефолтным выходом (и системным — чтобы туда шли и звуки системы).
    func setOutput(_ id: AudioDeviceID) {
        setDefault(id, selectors: [kAudioHardwarePropertyDefaultOutputDevice,
                                   kAudioHardwarePropertyDefaultSystemOutputDevice])
    }
    func setInput(_ id: AudioDeviceID) {
        setDefault(id, selectors: [kAudioHardwarePropertyDefaultInputDevice])
    }

    // MARK: - CoreAudio helpers

    private func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids.filter { hasStreams($0, scope: scope) }.map {
            AudioDevice(id: $0, name: name(of: $0), transport: transport(of: $0))
        }
    }

    private func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func setDefault(_ id: AudioDeviceID, selectors: [AudioObjectPropertySelector]) {
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value = id
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &value)
            NSLog("Hopkey.audio: setDefault(\(id)) selector=\(selector) status=\(status)")
        }
    }

    private func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Свойство возвращает CFString с +1 ссылкой — читаем как Unmanaged и освобождаем
        // через takeRetainedValue (и это убирает предупреждение про object reference).
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &cfName) == noErr,
              let cfName else { return "—" }
        return cfName.takeRetainedValue() as String
    }

    private func transport(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }
}
