import AppKit
import HopkeyCore

/// Короткий звук при срабатывании глобальных хоткеев (если включено в настройках).
enum HotKeySoundFeedback {
    private static var cache: [HotKeySound: NSSound] = [:]

    static func playIfEnabled(config: JiraConfig = .shared) {
        guard config.hotKeySoundsEnabled else { return }
        play(config.hotKeySound)
    }

    static func play(_ sound: HotKeySound) {
        let instance = cache[sound] ?? {
            let created = NSSound(named: NSSound.Name(sound.systemName))
            if let created { cache[sound] = created }
            return created
        }()
        instance?.stop()
        instance?.play()
    }
}
