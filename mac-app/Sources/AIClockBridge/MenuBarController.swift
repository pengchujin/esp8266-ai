import AppKit

// Menu-bar item: a retro Macintosh icon (drawn in code, template so it adapts
// to light/dark menu bars). Left click opens a live mirror of the ESP8266
// screen (MirrorPopover); right click opens the control menu with usage
// meters and device remote control. No quota text lives in the bar itself.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let service: StatusService
    private let usage: UsageFetcher
    private let port: UInt16
    private let controlMenu = NSMenu()
    private let mirrorPopover: MirrorPopoverController

    private let claudeUsageItem = NSMenuItem(title: "Claude …", action: nil, keyEquivalent: "")
    private let codexUsageItem = NSMenuItem(title: "Codex …", action: nil, keyEquivalent: "")
    private let deviceInfoItem = NSMenuItem(title: "设备：未设置", action: nil, keyEquivalent: "")
    private var modeItems: [String: NSMenuItem] = [:]

    init(service: StatusService, usage: UsageFetcher, netMonitor: NetSpeedMonitor,
         nowPlaying: NowPlayingMonitor, stockMonitor: StockMonitor, port: UInt16) {
        self.service = service
        self.usage = usage
        self.port = port
        self.mirrorPopover = MirrorPopoverController(service: service, netMonitor: netMonitor,
                                                     nowPlaying: nowPlaying, stockMonitor: stockMonitor)
        super.init()
        buildMenu()
        if let button = statusItem.button {
            button.image = Self.retroMacIcon()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// User-supplied device logo (bezel + dark screen + smiley + green status
    /// dot). Full-color, so NOT a template image — it keeps its colors in
    /// both light and dark menu bars.
    private static func retroMacIcon() -> NSImage {
        guard let img = Bundle.module.image(forResource: "happy-mac") else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }

    /// Left click -> mirror popover; right click -> control menu.
    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = controlMenu
            button.performClick(nil)
            statusItem.menu = nil // detach so left click keeps toggling the popover
        } else {
            mirrorPopover.toggle(relativeTo: button)
        }
    }

    // MARK: - menu construction

    private func buildMenu() {
        let menu = controlMenu
        menu.delegate = self

        claudeUsageItem.isEnabled = false
        codexUsageItem.isEnabled = false
        menu.addItem(claudeUsageItem)
        menu.addItem(codexUsageItem)
        menu.addItem(.separator())

        deviceInfoItem.isEnabled = false
        menu.addItem(deviceInfoItem)

        menu.addItem(makeItem("自动查找并配对设备", #selector(autoPairAction)))
        menu.addItem(makeItem("设置设备地址…", #selector(setDeviceAddress)))
        menu.addItem(makeItem("打开设备网页", #selector(openDevicePage)))

        let displayMenu = NSMenu()
        for (title, mode) in [("自动（谁在干活显示谁）", "auto"), ("固定 Claude", "claude"),
                              ("固定 Codex", "codex"), ("时钟页", "clock"), ("网速曲线", "net"),
                              ("音乐播放", "music"), ("股票行情", "stock")] {
            let item = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            modeItems[mode] = item
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "屏幕显示", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        // (屏幕亮度在左键弹出的镜像页底部，做成滑条了)

        menu.addItem(makeItem("设置自选股…", #selector(setStockSymbols)))
        menu.addItem(makeItem("设置天气城市…", #selector(setWeatherCity)))
        menu.addItem(makeItem("设置 DeepSeek API Key…", #selector(setDeepSeekKey)))

        menu.addItem(makeItem("更换桌宠动画…（petdex）", #selector(openPetPicker)))

        let resetMenu = NSMenu()
        for (title, slot) in [("Claude 恢复默认", "claude"), ("Codex 恢复默认", "codex")] {
            let item = NSMenuItem(title: title, action: #selector(resetSprite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = slot
            resetMenu.addItem(item)
        }
        let resetItem = NSMenuItem(title: "恢复默认动画", action: nil, keyEquivalent: "")
        resetItem.submenu = resetMenu
        menu.addItem(resetItem)

        menu.addItem(makeItem("把本机设为设备桥接", #selector(pointBridgeHere)))
        menu.addItem(.separator())
        menu.addItem(makeItem("刷新", #selector(refreshAction), key: "r"))
        menu.addItem(makeItem("桥接服务地址", #selector(showAddress)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - refresh

    func menuWillOpen(_ menu: NSMenu) {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    private func refreshUsageLines() {
        claudeUsageItem.title = Self.usageLine(name: "Claude", u: usage.claude, weeklyLabel: "7天")
        codexUsageItem.title = Self.usageLine(name: "Codex", u: usage.codex, weeklyLabel: "周")
    }

    private static func usageLine(name: String, u: ProviderUsage, weeklyLabel: String) -> String {
        if let err = u.error, u.primaryPct == nil { return "\(name)：\(err)" }
        var parts: [String] = []
        if let p = u.primaryPct {
            var s = "5h \(Int(p))%"
            if let m = u.primaryResetMin { s += "（\(fmtMin(m))后重置）" }
            parts.append(s)
        }
        if let p = u.weeklyPct {
            var s = "\(weeklyLabel) \(Int(p))%"
            if let m = u.weeklyResetMin { s += "（\(fmtMin(m))）" }
            parts.append(s)
        }
        return parts.isEmpty ? "\(name)：额度未知" : "\(name)　" + parts.joined(separator: "　")
    }

    private static func fmtMin(_ min: Int) -> String {
        if min >= 48 * 60 { return "\(min / (24 * 60))天" }
        if min >= 60 { return "\(min / 60)h\(min % 60 > 0 ? "\(min % 60)m" : "")" }
        return "\(min)m"
    }

    private func refreshDeviceSection() {
        let host = DeviceClient.host
        guard !host.isEmpty else {
            deviceInfoItem.title = "设备：未设置地址"
            modeItems.values.forEach { $0.state = .off }
            return
        }
        deviceInfoItem.title = "设备：\(host)（连接中…）"
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(info):
                let sprites = [info.claudeCustomSprite ? "C:自定义" : "C:默认",
                               info.codexCustomSprite ? "X:自定义" : "X:默认"]
                let showing = info.mode == "net" ? "网速"
                    : info.mode == "music" ? "音乐"
                    : info.mode == "clock" ? "时钟"
                    : (info.showing == "claude" ? "Claude" : "Codex")
                self.deviceInfoItem.title =
                    "设备：\(info.ip) · 正在显示 \(showing) · \(sprites.joined(separator: " "))"
                for (mode, item) in self.modeItems { item.state = mode == info.mode ? .on : .off }
            case .failure:
                self.deviceInfoItem.title = "设备：\(host)（无法连接）"
                self.modeItems.values.forEach { $0.state = .off }
                // self-heal: the device may have moved to a new DHCP address;
                // if it recently polled us from a different IP, adopt that.
                let seen = DeviceClient.lastSeenIP
                if !seen.isEmpty, !host.hasPrefix(seen) {
                    DeviceClient.verifyDevice(ip: seen) { ok in
                        if ok {
                            DeviceClient.host = seen
                            self.refreshDeviceSection()
                        }
                    }
                }
            }
        }
    }

    // MARK: - pairing

    @objc private func autoPairAction() {
        deviceInfoItem.title = "设备：正在查找…"
        DeviceClient.autoPair(progress: { [weak self] msg in
            self?.deviceInfoItem.title = "设备：\(msg)"
        }, completion: { [weak self] ip in
            if let ip = ip {
                Self.toast("配对成功", "已找到设备并配对：\(ip)")
                self?.refreshDeviceSection()
            } else {
                Self.toast("未找到设备", """
                局域网内没有发现 ESP8266 时钟。请确认：
                1. 设备已通电并连上同一个 WiFi（首次使用需通过 AI-Clock-Setup 热点配网）
                2. 路由器未开启"客户端隔离"
                """)
                self?.refreshDeviceSection()
            }
        })
    }

    // MARK: - actions

    @objc private func refreshAction() {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    @objc private func setDeviceAddress() {
        let alert = NSAlert()
        alert.messageText = "设备地址"
        alert.informativeText = "ESP8266 时钟的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = DeviceClient.host
        input.placeholderString = "192.168.1.50"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            DeviceClient.host = input.stringValue.trimmingCharacters(in: .whitespaces)
            refreshDeviceSection()
        }
    }

    @objc private func openDevicePage() {
        guard let url = DeviceClient.baseURL else {
            setDeviceAddress()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DeviceClient.setDisplayMode(mode) { [weak self] error in
            if let error = error {
                Self.toast("切换失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func setStockSymbols() {
        let alert = NSAlert()
        alert.messageText = "自选股"
        alert.informativeText = "逗号分隔的腾讯行情代码：sh/sz=A股、hk=港股、us=美股\n例如 sh600519,hk00700,usAAPL（设备最多显示 4 只）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = StockMonitor.symbols.joined(separator: ",")
        input.placeholderString = "sh000001,usAAPL"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            StockMonitor.symbols = input.stringValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    @objc private func setWeatherCity() {
        let alert = NSAlert()
        alert.messageText = "天气城市"
        alert.informativeText = "时钟页天气的数据城市，支持中文（Open-Meteo 地理编码）。例如：上海、北京、杭州"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = WeatherMonitor.city
        input.placeholderString = "上海"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WeatherMonitor.setCity(input.stringValue) { ok in
            if !ok {
                let err = NSAlert()
                err.messageText = "城市未找到"
                err.informativeText = "Open-Meteo 地理编码没有找到这个城市，保留原设置。"
                NSApp.activate(ignoringOtherApps: true)
                err.runModal()
            }
        }
    }

    @objc private func setDeepSeekKey() {
        let alert = NSAlert()
        alert.messageText = "DeepSeek API Key"
        alert.informativeText = "在 platform.deepseek.com 创建、以 sk- 开头的官方 Key，粘贴到这里。时钟页底部会显示账户余额；留空保存则关闭该显示。（第三方中转 Key 无法查询官方余额）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = DeepSeekMonitor.apiKey
        input.placeholderString = "sk-..."
        alert.accessoryView = input
        alert.addButton(withTitle: "保存并验证")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DeepSeekMonitor.setKey(input.stringValue) { ok, detail in
            let result = NSAlert()
            if ok {
                result.messageText = DeepSeekMonitor.apiKey.isEmpty ? "已关闭 DeepSeek 余额显示" : "Key 有效"
                result.informativeText = DeepSeekMonitor.apiKey.isEmpty ? "" : "当前余额 \(detail)，屏幕会在下一次刷新时显示。"
            } else {
                result.messageText = "验证失败"
                result.informativeText = "\(detail)\nKey 已保存，稍后会自动重试；如需更换请重新打开本菜单。"
            }
            NSApp.activate(ignoringOtherApps: true)
            result.runModal()
        }
    }

    @objc private func openPetPicker() {
        if DeviceClient.host.isEmpty { setDeviceAddress() }
        PetPickerWindowController.shared.show()
    }

    @objc private func resetSprite(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? String else { return }
        DeviceClient.resetSprite(slot: slot) { [weak self] error in
            if let error = error {
                Self.toast("恢复失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func pointBridgeHere() {
        guard let ip = DeviceClient.localIPv4() else {
            Self.toast("失败", "获取本机局域网 IP 失败")
            return
        }
        let bridge = "\(ip):\(port)"
        DeviceClient.setBridgeHost(bridge) { error in
            if let error = error {
                Self.toast("设置失败", error.localizedDescription)
            } else {
                Self.toast("已设置", "设备将从 http://\(bridge)/status 拉取状态")
            }
        }
    }

    @objc private func showAddress() {
        let ip = DeviceClient.localIPv4() ?? "<本机局域网IP>"
        Self.toast("桥接服务地址", "http://\(ip):\(port)/status\n\n设备端 Bridge host 填：\(ip):\(port)")
    }

    private static func toast(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
