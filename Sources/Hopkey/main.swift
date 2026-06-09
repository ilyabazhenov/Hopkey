import AppKit

// Приложение без иконки в Dock — живёт только в строке меню.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
