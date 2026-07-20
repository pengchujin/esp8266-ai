import AppKit
import Foundation

// Weather for the device's clock page: Open-Meteo (free, no API key), refreshed
// every 10 minutes. City comes from the tray menu (设置天气城市…); it is geocoded
// once via Open-Meteo's geocoding API and the lat/lon is cached in UserDefaults.
// Defaults to Shanghai so the feature works out of the box.
//
// The device's panel font is ASCII-only, so the CJK city/condition line goes
// down as a Mac-rendered RGB565 strip (same trick as stock names / music
// titles): name_rev in /weather tells the device when to re-fetch the strip.
final class WeatherMonitor {
    static let shared = WeatherMonitor()

    struct Snapshot {
        let ok: Bool
        let temp: Double    // °C, current
        let code: Int       // WMO weather code, -1 = unknown
        let humidity: Int   // %, -1 = unknown
        let tmax: Double    // today's high, °C
        let tmin: Double    // today's low, °C
    }

    static let cityKey = "weather_city"
    static let latKey = "weather_lat"
    static let lonKey = "weather_lon"

    static var city: String {
        get { UserDefaults.standard.string(forKey: cityKey) ?? "上海" }
        set { UserDefaults.standard.set(newValue, forKey: cityKey) }
    }

    static var coordinate: (lat: Double, lon: Double) {
        get {
            let d = UserDefaults.standard
            let lat = d.object(forKey: latKey) as? Double ?? 31.2304
            let lon = d.object(forKey: lonKey) as? Double ?? 121.4737
            return (lat, lon)
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.lat, forKey: latKey)
            d.set(newValue.lon, forKey: lonKey)
        }
    }

    static let stripW = 108, stripH = 16

    private let lock = NSLock()
    private var snap = Snapshot(ok: false, temp: 0, code: -1, humidity: -1, tmax: 0, tmin: 0)
    private var stripRev = 0
    private var stripData = Data()
    private var hiloRev = 0
    private var hiloData = Data()
    private var lastStripKey = ""
    private var timer: Timer?

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snap
    }

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    // MARK: - endpoints

    func jsonData() -> Data {
        let s = snapshot
        lock.lock()
        let rev = stripRev
        let hrev = hiloRev
        lock.unlock()
        let dict: [String: Any] = [
            "ok": s.ok,
            "temp": s.temp,
            "code": s.code,
            "humidity": s.humidity,
            "tmax": s.tmax,
            "tmin": s.tmin,
            "name_rev": rev,
            "hilo_rev": hrev,
            "bg_rev": ClockBackground.shared.rev,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    /// Raw strip bytes, stripW x stripH RGB565 big-endian (no count byte).
    func nameRGB565() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stripData
    }

    /// "最高33° 最低26°" strip, same wire format as the name strip.
    func hiloRGB565() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return hiloData
    }

    /// (rev, bytes) pairs for the serial bulk push (SerialLink), so wired-only
    /// devices get the CJK lines without HTTP.
    func nameStrip() -> (rev: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stripRev, stripData)
    }

    func hiloStrip() -> (rev: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (hiloRev, hiloData)
    }

    // MARK: - city configuration

    /// Geocode a new city name, persist it, and refresh. Calls back on the
    /// main queue with false when the name can't be found.
    static func setCity(_ name: String, completion: @escaping (Bool) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=zh&format=json") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var ok = false
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = obj["results"] as? [[String: Any]], let first = results.first,
               let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double {
                // prefer the API's Chinese display name when it has one
                let display = (first["name"] as? String).map { $0.isEmpty ? trimmed : $0 } ?? trimmed
                Self.city = display
                Self.coordinate = (lat, lon)
                ok = true
            }
            DispatchQueue.main.async {
                if ok { Self.shared.fetch() }
                completion(ok)
            }
        }.resume()
    }

    // MARK: - fetch & render

    private func fetch() {
        let (lat, lon) = Self.coordinate
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = obj["current"] as? [String: Any],
                  let temp = cur["temperature_2m"] as? Double,
                  let code = cur["weather_code"] as? Int else { return }
            let hum = (cur["relative_humidity_2m"] as? NSNumber)?.intValue ?? -1
            var tmax = temp, tmin = temp
            if let daily = obj["daily"] as? [String: Any],
               let maxArr = daily["temperature_2m_max"] as? [Double], let hi = maxArr.first,
               let minArr = daily["temperature_2m_min"] as? [Double], let lo = minArr.first {
                tmax = hi
                tmin = lo
            }
            self.lock.lock()
            self.snap = Snapshot(ok: true, temp: temp, code: code, humidity: hum, tmax: tmax, tmin: tmin)
            self.lock.unlock()
            self.renderStripIfNeeded(code: code, tmax: tmax, tmin: tmin)
        }.resume()
    }

    private func renderStripIfNeeded(code: Int, tmax: Double, tmin: Double) {
        let text = "\(Self.city)·\(Self.zhDescription(code))"
        let hilo = String(format: "最高%.0f° 最低%.0f°", tmax, tmin)
        let key = text + "|" + hilo
        lock.lock()
        let dirty = key != lastStripKey
        lock.unlock()
        guard dirty else { return }
        let rendered = Self.renderStrip(text) ?? Data(count: Self.stripW * Self.stripH * 2)
        let renderedHilo = Self.renderStrip(hilo) ?? Data(count: Self.stripW * Self.stripH * 2)
        lock.lock()
        lastStripKey = key
        stripData = rendered
        stripRev += 1
        hiloData = renderedHilo
        hiloRev += 1
        lock.unlock()
        // 天气内容变了，时钟页壁纸上的温区行也要跟着重渲染
        ClockBackground.shared.refresh()
    }

    /// Left-aligned strip, black background, big-endian RGB565. Internal so
    /// DateStrip can reuse it for the "7月25日 周一" line.
    static func renderStrip(_ text: String, w: Int = stripW, h: Int = stripH) -> Data? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: NSRect(x: 0, y: 1, width: w, height: h - 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.72, alpha: 1),
            .paragraphStyle: style,
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = ctx.data else { return nil }
        let px = rendered.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out = Data(capacity: w * h * 2)
        for i in 0..<(w * h) {
            let v = (UInt16(px[i * 4] & 0xF8) << 8) | (UInt16(px[i * 4 + 1] & 0xFC) << 3)
                | UInt16(px[i * 4 + 2] >> 3)
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    /// WMO weather code -> short Chinese condition (fits the 108px strip).
    static func zhDescription(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "多云间晴"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55, 56, 57: return "毛毛雨"
        case 61, 63, 65, 66, 67: return "雨"
        case 71, 73, 75, 77: return "雪"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95, 96, 99: return "雷暴"
        default: return "--"
        }
    }
}
