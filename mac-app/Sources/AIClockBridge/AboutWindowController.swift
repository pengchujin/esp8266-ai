import AppKit

// "About" panel shown from the menu bar. Displays the current version and a
// button to manually check for updates via Sparkle.
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private let checkForUpdatesAction: () -> Void

    init(checkForUpdates: @escaping () -> Void = {}) {
        self.checkForUpdatesAction = checkForUpdates
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于 AIClockBridge"
        window.isFloatingPanel = true
        window.center()
        super.init(window: window)
        window.contentView = makeContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContent() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))

        let imageView = NSImageView(frame: NSRect(x: 24, y: 80, width: 64, height: 64))
        imageView.image = Bundle.module.image(forResource: "happy-mac")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(imageView)

        let title = NSTextField(labelWithString: "AIClockBridge")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 104, y: 118, width: 192, height: 24)
        view.addSubview(title)

        let version = NSTextField(labelWithString: "版本 \(AppVersion.bundleShort) (build \(AppVersion.bundleBuild))")
        version.font = NSFont.systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 104, y: 96, width: 192, height: 18)
        view.addSubview(version)

        let copyright = NSTextField(labelWithString: "ESP8266 AI 状态时钟桥接端")
        copyright.font = NSFont.systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        copyright.frame = NSRect(x: 104, y: 76, width: 192, height: 16)
        view.addSubview(copyright)

        let updateButton = NSButton(title: "检查更新…", target: self, action: #selector(checkForUpdates))
        updateButton.frame = NSRect(x: 104, y: 20, width: 100, height: 28)
        view.addSubview(updateButton)

        let okButton = NSButton(title: "好", target: self, action: #selector(closeWindow))
        okButton.frame = NSRect(x: 216, y: 20, width: 80, height: 28)
        view.addSubview(okButton)

        return view
    }

    @objc private func checkForUpdates() {
        checkForUpdatesAction()
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
