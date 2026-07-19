import AppKit

// Entry point. Runs as an "accessory" app (menu-bar only, no Dock icon, no main
// window) and starts the /status HTTP server that the ESP8266 clock polls.
// Headless smoke test for the petdex -> GIF -> device pipeline (same code the
// pet picker window uses): AIClockBridge --test-pet <slug> <claude|codex> <host>
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--test-pet" {
    let slug = CommandLine.arguments[2]
    let slot = CommandLine.arguments[3]
    if CommandLine.arguments.count >= 5 { DeviceClient.host = CommandLine.arguments[4] }
    let size = slot == "claude" ? (w: 111, h: 120) : (w: 120, h: 120)
    let state = PetdexService.states.first { $0.id == "running" }!
    PetdexService.loadManifest { result in
        guard case let .success(pets) = result, let pet = pets.first(where: { $0.slug == slug }) else {
            print("manifest load failed or slug not found"); exit(1)
        }
        print("pet: \(pet.displayName) \(pet.spritesheetUrl)")
        PetdexService.downloadSpritesheet(pet) { result in
            guard case let .success(sheet) = result else { print("sheet download failed"); exit(1) }
            print("sheet: \(sheet.width)x\(sheet.height)")
            guard let gif = PetdexService.buildGif(sheet: sheet, state: state,
                                                   targetW: size.w, targetH: size.h) else {
                print("gif build failed"); exit(1)
            }
            print("gif: \(gif.count) bytes, uploading to \(DeviceClient.host) slot \(slot)...")
            DeviceClient.uploadGif(gif, slot: slot) { error in
                print(error.map { "upload failed: \($0.localizedDescription)" } ?? "upload ok")
                exit(error == nil ? 0 : 1)
            }
        }
    }
    RunLoop.main.run() // completions land on the main queue; exit() above ends us
    exit(0)
}

let port: UInt16 = 8765
let service = StatusService()
let usage = UsageFetcher()
service.usage = usage
let netMonitor = NetSpeedMonitor()
netMonitor.start()
let nowPlaying = NowPlayingMonitor()
nowPlaying.start()
service.musicPlayingProvider = { nowPlaying.snapshot.playing }

let stockMonitor = StockMonitor()
stockMonitor.start()
let weatherMonitor = WeatherMonitor.shared
weatherMonitor.start()
let deepSeekMonitor = DeepSeekMonitor.shared
deepSeekMonitor.start()
ClockBackground.shared.start()

// Wired fallback: if the clock is plugged in over USB, push status/net down
// the serial line (works around AP client isolation; no WiFi setup needed).
let serialLink = SerialLink(service: service, netMonitor: netMonitor, stockMonitor: stockMonitor,
                            nowPlaying: nowPlaying)
serialLink.start()

let server = HTTPServer(port: port, routes: [
    "/": { service.snapshot().jsonData() },
    "/status": { service.snapshot().jsonData() },
    "/net": {
        let stats = SystemStatsMonitor.shared.snapshot()
        return netMonitor.jsonData(cpu: stats.cpu, mem: stats.mem)
    },
    "/music": { nowPlaying.jsonData() },
    "/stock": { stockMonitor.jsonData() },
    "/weather": { weatherMonitor.jsonData() },
    "/deepseek": { deepSeekMonitor.jsonData() },
], binaryRoutes: [
    "/music/cover.raw": { nowPlaying.coverRGB565 },
    "/music/text.raw": { nowPlaying.textRGB565 },
    "/stock/names.raw": { stockMonitor.namesRGB565() },
    "/weather/name.raw": { weatherMonitor.nameRGB565() },
    "/weather/hilo.raw": { weatherMonitor.hiloRGB565() },
    "/date.raw": { DateStrip.rgb565() },
    "/clockbg.raw": { ClockBackground.shared.rgb565() },
], postRoutes: [
    // Claude Code / Codex hooks push lifecycle events here (see README §7):
    // curl -d '{"agent":"claude","event":"PreToolUse"}' http://127.0.0.1:8765/event
    "/event": { body in
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let agent = obj["agent"] as? String, let event = obj["event"] as? String {
            service.recordEvent(agent: agent, event: event, message: obj["message"] as? String)
            return Data("{\"ok\":true}".utf8)
        }
        return Data("{\"ok\":false}".utf8)
    },
])
// Passive discovery: the clock polls us, so its source IP identifies it.
// Remember it (for auto-pairing / DHCP-change self-healing) and adopt it
// outright when no device is configured yet.
server.onRequest = { path, ip in
    guard path == "/status" || path == "/net" || path == "/music" || path == "/weather" || path == "/deepseek",
          ip != "127.0.0.1", ip != "::1", !ip.isEmpty else { return }
    DeviceClient.devicePollAt = Date()
    DeviceClient.lastSeenIP = ip
    if DeviceClient.host.isEmpty { DeviceClient.host = ip }
}
// Active fallback for when the passive route can't fire at all (fresh /
// erased device knows no bridge host, so it never polls anyone): if the
// device stays silent, find it ourselves and hand it our address.
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    DeviceClient.healPairingIfNeeded(port: port)
}

do {
    try server.start()
    FileHandle.standardError.write(Data("[bridge] serving /status on 0.0.0.0:\(port)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("[bridge] failed to bind port \(port): \(error)\n".utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// A main menu with a working Edit menu is required for keyboard shortcuts
// (⌘A/⌘C/⌘V/⌘X) in text fields — without it, alerts like the DeepSeek key
// input only accept mouse-right-click paste. The menu bar itself is hidden
// in accessory mode; the Edit menu still drives the key equivalents.
let mainMenu = NSMenu()
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
app.mainMenu = mainMenu

let menuBar = MenuBarController(service: service, usage: usage, netMonitor: netMonitor,
                                nowPlaying: nowPlaying, stockMonitor: stockMonitor, port: port)
_ = menuBar // retain
usage.startAutoRefresh()
app.run()
