import AppKit
import Foundation

// Watchlist quotes from Tencent's free endpoint (no key, realtime for A-shares,
// supports sh/sz/hk/us prefixes in one batch request, GBK-encoded response):
//   http://qt.gtimg.cn/q=sh600519,hk00700,usAAPL
// Polled every 5s; the device and the mirror both render the pre-formatted
// strings so the firmware stays dumb (and ASCII-only: it shows the code, the
// CJK company name is only used by the Mac mirror).
final class StockMonitor {
    struct Row {
        let code: String  // ASCII display code: "600519", "00700", "AAPL"
        let name: String  // CJK name, mirror only
        let price: String // pre-formatted
        let pct: String   // "+1.24%"
        let up: Int       // 1 rising / -1 falling / 0 flat
    }

    static let symbolsKey = "stock_symbols"
    /// Comma-separated Tencent symbols ("sh600519,hk00700,usAAPL").
    static var symbols: [String] {
        get {
            let raw = UserDefaults.standard.string(forKey: symbolsKey) ?? "sh000001"
            return raw.replacingOccurrences(of: "，", with: ",") // CN comma happens
                .split(separator: ",")
                .map { normalize(String($0)) }
                .filter { !$0.isEmpty }
        }
        set { UserDefaults.standard.set(newValue.joined(separator: ","), forKey: symbolsKey) }
    }

    /// Market prefix must be lowercase but the US ticker must stay UPPERCASE
    /// ("usaapl" gets v_pv_none_match back), so normalize both halves.
    static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count > 2 else { return t.lowercased() }
        return t.prefix(2).lowercased() + String(t.dropFirst(2)).uppercased()
    }

    private let lock = NSLock()
    private var rows: [Row] = []
    private var timer: Timer?

    // The device's font is ASCII-only, so CJK company names go down as Mac-
    // rendered RGB565 strips (same trick as the music title strip): one
    // NAME_W x NAME_H strip per row, wire format [1 byte count][strips...].
    // names_rev in /stock tells the device when to re-fetch.
    static let nameW = 156, nameH = 16
    private var namesRev = 0
    private var namesData = Data([0])
    private var lastNamesKey = ""

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    var snapshot: [Row] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    func jsonData() -> Data {
        let stocks = snapshot.map { r -> [String: Any] in
            ["code": r.code, "name": r.name, "price": r.price, "pct": r.pct, "up": r.up]
        }
        lock.lock()
        let rev = namesRev
        lock.unlock()
        let dict: [String: Any] = ["stocks": stocks, "names_rev": rev]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    /// [1 byte count][NAME_W x NAME_H RGB565 big-endian per row...]
    func namesRGB565() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return namesData
    }

    private func renderNamesIfNeeded(_ parsed: [Row]) {
        let key = parsed.prefix(4).map { $0.name }.joined(separator: "\n")
        lock.lock()
        let dirty = key != lastNamesKey
        lock.unlock()
        guard dirty else { return }
        var data = Data([UInt8(min(parsed.count, 4))])
        for row in parsed.prefix(4) {
            data.append(Self.renderNameStrip(row.name) ?? Data(count: Self.nameW * Self.nameH * 2))
        }
        lock.lock()
        lastNamesKey = key
        namesData = data
        namesRev += 1
        lock.unlock()
    }

    private static func renderNameStrip(_ name: String) -> Data? {
        let w = nameW, h = nameH
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
        style.alignment = .right // sits left of the row's right edge, code is on the left
        style.lineBreakMode = .byTruncatingTail
        (name as NSString).draw(in: NSRect(x: 0, y: 1, width: w, height: h - 1), withAttributes: [
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

    private func fetch() {
        let symbols = Self.symbols
        guard !symbols.isEmpty,
              let url = URL(string: "http://qt.gtimg.cn/q=" + symbols.joined(separator: ",")) else {
            lock.lock(); rows = []; lock.unlock()
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let text = String(data: data, encoding: gbk)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
            let parsed = Self.parse(text: text, order: symbols)
            self.lock.lock()
            self.rows = parsed
            self.lock.unlock()
            self.renderNamesIfNeeded(parsed)
        }.resume()
    }

    /// Response is lines of `v_sh600519="1~贵州茅台~600519~1212.00~...";`
    /// fields split by "~": [1]=name [3]=price [31]=change [32]=change%.
    static func parse(text: String, order: [String]) -> [Row] {
        var bySymbol: [String: Row] = [:]
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let eq = line.firstIndex(of: "="), line.hasPrefix("v_") else { continue }
            let symbol = String(line[line.index(line.startIndex, offsetBy: 2)..<eq]).lowercased()
            let f = line[line.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
                .components(separatedBy: "~")
            guard f.count > 32, let price = Double(f[3]), let chg = Double(f[31]),
                  let pct = Double(f[32]) else { continue }
            // lowercase key so the case-normalized query symbol still matches
            bySymbol[symbol.lowercased()] = Row(
                code: displayCode(symbol),
                name: f[1],
                price: formatPrice(price),
                pct: String(format: "%+.2f%%", pct),
                up: chg > 0 ? 1 : (chg < 0 ? -1 : 0))
        }
        return order.compactMap { bySymbol[$0.lowercased()] }
    }

    /// "sh600519" -> "600519", "usAAPL" -> "AAPL", "hk00700" -> "00700"
    static func displayCode(_ symbol: String) -> String {
        for p in ["sh", "sz", "bj", "hk", "us"] where symbol.hasPrefix(p) && symbol.count > 2 {
            return String(symbol.dropFirst(2)).uppercased()
        }
        return symbol.uppercased()
    }

    static func formatPrice(_ p: Double) -> String {
        if p >= 10000 { return String(format: "%.0f", p) }
        if p >= 1000 { return String(format: "%.1f", p) }
        return String(format: "%.2f", p)
    }
}
