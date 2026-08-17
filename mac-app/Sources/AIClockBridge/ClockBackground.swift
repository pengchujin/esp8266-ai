import AppKit
import CoreGraphics

/// 把当前 Mac 桌面壁纸加工成 240×240 的时钟页背景：
///   等比裁剪为正方形 → 55% 黑色蒙版 → 底部叠加三行中文信息
/// （城市 / 天气·温区 / 日期），输出 RGB565 大端字节流，设备整屏 blit 显示。
/// 壁纸文件变化或内容变化时 rev 自增，设备据此决定何时重新拉取。
final class ClockBackground {
    static let shared = ClockBackground()
    static let size = 240

    private(set) var rev: Int = 1
    private var bytes = [UInt8](repeating: 0, count: size * size * 2)
    private var lastKey = ""
    private var timer: Timer?

    private init() {}

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 天气/城市/日期变化时重渲染（WeatherMonitor 每次 fetch 完会调用）。
    func refresh() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let tempText = Self.tempLine()
        let key = "\(url.path)|\(mtime)|\(WeatherMonitor.city)|\(tempText)|\(Self.dateLine())"
        guard key != lastKey else { return }
        lastKey = key
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        render(cg, tempText: tempText)
        // rev must differ from anything the device ever drew, even across
        // bridge restarts: use the render timestamp (monotonic), not a counter
        rev = Int(Date().timeIntervalSince1970) & 0x7FFFFFFF
    }

    /// “多云 26~33°” 形式的温区行；天气未就绪时退化为“--”。
    private static func tempLine() -> String {
        let s = WeatherMonitor.shared.snapshot
        guard s.ok else { return "--" }
        return String(format: "%@ %.0f~%.0f°", WeatherMonitor.zhDescription(s.code), s.tmin, s.tmax)
    }

    /// “7月25日 周一” 形式的日期行。
    private static func dateLine() -> String {
        let cal = Calendar.current
        let now = Date()
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let wd = weekdays[max(1, min(7, cal.component(.weekday, from: now))) - 1]
        return "\(cal.component(.month, from: now))月\(cal.component(.day, from: now))日 \(wd)"
    }

    func rgb565() -> Data { Data(bytes) }

    // MARK: - 合成

    private func render(_ src: CGImage, tempText: String) {
        let s = ClockBackground.size
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8,
                                  bytesPerRow: s * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        // 等比填满后居中裁剪为正方形（不模糊，保留壁纸原貌）
        let scale = max(CGFloat(s) / CGFloat(src.width), CGFloat(s) / CGFloat(src.height))
        let dw = CGFloat(src.width) * scale, dh = CGFloat(src.height) * scale
        ctx.draw(src, in: CGRect(x: (CGFloat(s) - dw) / 2, y: (CGFloat(s) - dh) / 2, width: dw, height: dh))

        // 55% 黑色蒙版保证文字对比度
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        // 三行中文，纯白加大（y 从上往下：城市 8 / 天气温区 30 / 日期 112）
        drawText(ctx, WeatherMonitor.city, y: 8, size: 16, weight: .semibold)
        drawText(ctx, tempText, y: 30, size: 13, weight: .medium)
        drawText(ctx, Self.dateLine(), y: 112, size: 16, weight: .semibold)

        // RGBA → RGB565 大端
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        var outB = [UInt8](repeating: 0, count: s * s * 2)
        for i in 0..<(s * s) {
            let r = UInt16(px[i * 4]), g = UInt16(px[i * 4 + 1]), b = UInt16(px[i * 4 + 2])
            let v: UInt16 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            outB[i * 2] = UInt8(v >> 8)
            outB[i * 2 + 1] = UInt8(v & 0xFF)
        }
        bytes = outB
    }

    private func drawText(_ ctx: CGContext, _ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        // soft dark shadow first (1px offset), then solid white on top —
        // readable on any wallpaper without a heavy outline
        let shadow = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(white: 0, alpha: 0.75),
        ])
        let white = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(white: 1, alpha: 1),
        ])
        // CGContext 原点在左下，翻转 y
        let base = CGFloat(ClockBackground.size) - y - size
        ctx.textPosition = CGPoint(x: 16.8, y: base - 0.8)
        CTLineDraw(CTLineCreateWithAttributedString(shadow), ctx)
        ctx.textPosition = CGPoint(x: 16, y: base)
        CTLineDraw(CTLineCreateWithAttributedString(white), ctx)
    }
}
