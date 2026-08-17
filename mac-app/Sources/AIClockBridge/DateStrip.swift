import Foundation

// Renders the Chinese date line for the clock page ("7月25日 周一") as an
// RGB565 strip. The device can't draw CJK itself, so it pulls this over
// HTTP once per local-date change. Rendered on demand and cached per day.
enum DateStrip {
    static let W = 120, H = 16

    private static let lock = NSLock()
    private static var cachedKey = ""
    private static var cachedData = Data(count: W * H * 2)

    static func rgb565() -> Data {
        let now = Date()
        let cal = Calendar.current
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = weekdays[max(1, min(7, cal.component(.weekday, from: now))) - 1]
        let text = "\(cal.component(.month, from: now))月\(cal.component(.day, from: now))日 \(weekday)"
        lock.lock()
        defer { lock.unlock() }
        if text != cachedKey {
            cachedKey = text
            cachedData = WeatherMonitor.renderStrip(text, w: W, h: H) ?? Data(count: W * H * 2)
        }
        return cachedData
    }
}
