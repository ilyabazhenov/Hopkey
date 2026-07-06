import AppKit

/// Кратковременный HUD-«тост»: иконка + сообщение по центру-снизу активного экрана, с плавным
/// появлением и авто-затуханием. Неактивирующая сквозная для мыши панель — фокус целевого
/// приложения не трогает и **не требует разрешений** (в отличие от баннера уведомлений, который
/// молчит без выданного доступа). Используется как мгновенная обратная связь после OCR.
final class HUDWindowController {

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    /// Показывает тост. Повторный вызов заменяет предыдущий (таймер перезапускается).
    func show(symbol: String, message: String) {
        dismissWork?.cancel()
        panel?.orderOut(nil)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: message)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 18, bottom: 13, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Матовый HUD-фон со скруглением (borderless-панель сама углы не рисует).
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 54),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = backdrop
        panel.setContentSize(backdrop.fittingSize)
        positionOnActiveScreen(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        })
    }

    /// По центру по горизонтали, в нижней трети экрана под курсором — чтобы не перекрывать
    /// область, которую только что выделяли для OCR.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                     y: area.minY + area.height * 0.18))
    }
}
