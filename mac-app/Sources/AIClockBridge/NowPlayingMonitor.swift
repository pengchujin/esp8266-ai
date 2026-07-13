import AppKit

// System now-playing bridge for the clock's music page. MediaRemote is a
// private macOS framework, so everything is resolved dynamically; if the
// framework or symbols are unavailable, the monitor simply reports idle.
final class NowPlayingMonitor {
    struct Snapshot {
        var title = ""
        var artist = ""
        var album = ""
        var playing = false
        var elapsed: Double = 0
        var duration: Double = 0
        var artworkRev = 0
        var updatedAt = Date()
    }

    private typealias GetNowPlayingInfoFn = @convention(c)
        (DispatchQueue, @escaping ([AnyHashable: Any]?) -> Void) -> Void

    private let lock = NSLock()
    private var timer: Timer?
    private var getNowPlayingInfo: GetNowPlayingInfoFn?
    private var _snapshot = Snapshot()
    private var _coverRGB565 = Data()
    private var lastArtworkHash = 0
    private var helperRunning = false
    // Pre-rendered title/artist strip for the device. The ESP8266's built-in
    // fonts are ASCII-only, so CJK titles drew as nothing — instead the Mac
    // renders the text with real system fonts into a 232x44 RGB565 bitmap
    // that the firmware blits like the cover art. rev bumps on text change.
    private var _textRGB565 = Data()
    private var textRev = 0
    private var lastTextKey: String? = nil

    static let textW = 232
    static let textH = 44
    // MediaRemote returns a transient empty payload around track changes,
    // probe timeouts, or system load spikes. Only accept "nothing playing"
    // after several consecutive empties so real metadata isn't wiped by a
    // single hiccup (the visible bug: title/artist randomly disappearing).
    private var emptyStreak = 0
    private let emptyStreakToClear = 3

    private let coverW = 128
    private let coverH = 128

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked()
    }

    var coverRGB565: Data {
        lock.lock()
        defer { lock.unlock() }
        return _coverRGB565
    }

    var textRGB565: Data {
        lock.lock()
        defer { lock.unlock() }
        return _textRGB565
    }

    init() {
        loadMediaRemote()
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func jsonData() -> Data {
        renderTextIfNeeded()
        let s = snapshot
        lock.lock()
        let tRev = textRev
        lock.unlock()
        let dict: [String: Any] = [
            "title": s.title,
            "artist": s.artist,
            "album": s.album,
            "playing": s.playing,
            "elapsed": Int(s.elapsed.rounded()),
            "duration": Int(s.duration.rounded()),
            "progress": s.duration > 0 ? max(0, min(1, s.elapsed / s.duration)) : 0,
            "artwork_rev": s.artworkRev,
            "has_artwork": !coverRGB565.isEmpty,
            "text_rev": tRev,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    /// Re-renders the title/artist strip when the strings change. Called on
    /// the /music request path (cheap no-op when nothing changed).
    private func renderTextIfNeeded() {
        let s = snapshot
        let key = s.title + "\n" + s.artist
        lock.lock()
        let dirty = key != lastTextKey
        lock.unlock()
        guard dirty else { return }
        let rendered = Self.renderTextStrip(
            title: s.title.isEmpty ? "No Music" : s.title,
            titleColor: s.title.isEmpty ? .gray : .white,
            artist: s.artist)
        lock.lock()
        if key != lastTextKey { // re-check under lock (poll may race)
            lastTextKey = key
            _textRGB565 = rendered ?? Data()
            textRev += 1
        }
        lock.unlock()
    }

    /// 232x44 strip: title (16pt semibold, centered, truncated) over artist
    /// (12pt, grey). Black background, output big-endian RGB565 like the cover.
    private static func renderTextStrip(title: String, titleColor: NSColor, artist: String) -> Data? {
        let w = textW, h = textH
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
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        // non-flipped context: y measures from the bottom
        (title as NSString).draw(in: NSRect(x: 2, y: 19, width: w - 4, height: 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: titleColor,
            .paragraphStyle: style,
        ])
        (artist as NSString).draw(in: NSRect(x: 2, y: 1, width: w - 4, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
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

    private func poll() {
        lock.lock()
        if helperRunning {
            lock.unlock()
            return
        }
        helperRunning = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runProbe()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let result {
                    self.applyProbe(result)
                } else if let getNowPlayingInfo = self.getNowPlayingInfo {
                    getNowPlayingInfo(.main) { [weak self] info in
                        self?.apply(info: info ?? [:])
                    }
                }
                self.lock.lock()
                self.helperRunning = false
                self.lock.unlock()
            }
        }
    }

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            return
        }
        getNowPlayingInfo = unsafeBitCast(sym, to: GetNowPlayingInfoFn.self)
    }

    // MediaRemote keeps serving the last snapshot after a player stops or
    // quits, playbackRate included. Since elapsed is extrapolated from that
    // snapshot (elapsed += now - timestamp), a stale rate > 0 walks elapsed all
    // the way to duration, where the clamp pins it forever: playing stays true,
    // the clock parks on the music page, and the quota page never comes back.
    //
    // A player that is genuinely playing does not sit at the last second - it
    // rolls into the next track and the snapshot moves. So elapsed sitting on
    // duration means nobody is playing anything.
    private static func stalledAtEnd(_ elapsed: Double, _ duration: Double) -> Bool {
        duration > 0 && elapsed >= duration - 0.5
    }

    private func apply(info: [AnyHashable: Any]) {
        let now = Date()
        let timestamp = dateValue(info["kMRMediaRemoteNowPlayingInfoTimestamp"])
        let rate = doubleValue(info["kMRMediaRemoteNowPlayingInfoPlaybackRate"]) ?? 0
        let rawElapsed = doubleValue(info["kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?? 0
        let duration = doubleValue(info["kMRMediaRemoteNowPlayingInfoDuration"]) ?? 0
        var elapsed = rawElapsed
        if rate > 0, let timestamp {
            elapsed += now.timeIntervalSince(timestamp) * rate
        }
        elapsed = duration > 0 ? max(0, min(duration, elapsed)) : max(0, elapsed)

        var next = Snapshot()
        next.title = stringValue(info["kMRMediaRemoteNowPlayingInfoTitle"])
        next.artist = stringValue(info["kMRMediaRemoteNowPlayingInfoArtist"])
        next.album = stringValue(info["kMRMediaRemoteNowPlayingInfoAlbum"])
        next.playing = rate > 0.01 && !next.title.isEmpty && !Self.stalledAtEnd(elapsed, duration)
        next.elapsed = elapsed
        next.duration = duration
        next.updatedAt = now
        if shouldIgnoreAsTransientEmpty(next) { return }

        let artworkData = dataValue(info["kMRMediaRemoteNowPlayingInfoArtworkData"])
        let artworkHash = artworkData?.hashValue ?? 0
        let cover = artworkData.flatMap { Self.makeCoverRGB565(from: $0, w: coverW, h: coverH) }

        lock.lock()
        next.artworkRev = _snapshot.artworkRev
        if artworkHash != 0, artworkHash != lastArtworkHash, let cover {
            _coverRGB565 = cover
            lastArtworkHash = artworkHash
            next.artworkRev += 1
        } else if artworkHash == 0, lastArtworkHash != 0 {
            _coverRGB565 = Data()
            lastArtworkHash = 0
            next.artworkRev += 1
        }
        _snapshot = next
        lock.unlock()
    }

    private func applyProbe(_ obj: [String: Any]) {
        let now = Date()
        let title = stringValue(obj["title"])
        let artist = stringValue(obj["artist"])
        let album = stringValue(obj["album"])
        let playing = (obj["playing"] as? Bool) ?? false
        let elapsed = doubleValue(obj["elapsed"]) ?? 0
        let duration = doubleValue(obj["duration"]) ?? 0
        let artworkString = stringValue(obj["artwork_b64"])
        let artworkData = artworkString.isEmpty ? nil : Data(base64Encoded: artworkString)
        let artworkHash = artworkData?.hashValue ?? 0
        let cover = artworkData.flatMap { Self.makeCoverRGB565(from: $0, w: coverW, h: coverH) }

        var next = Snapshot()
        next.title = title
        next.artist = artist
        next.album = album
        next.elapsed = duration > 0 ? max(0, min(duration, elapsed)) : max(0, elapsed)
        next.playing = playing && !title.isEmpty && !Self.stalledAtEnd(next.elapsed, duration)
        next.duration = duration
        next.updatedAt = now
        if shouldIgnoreAsTransientEmpty(next) { return }

        lock.lock()
        next.artworkRev = _snapshot.artworkRev
        if artworkHash != 0, artworkHash != lastArtworkHash, let cover {
            _coverRGB565 = cover
            lastArtworkHash = artworkHash
            next.artworkRev += 1
        } else if artworkHash == 0, lastArtworkHash != 0 {
            _coverRGB565 = Data()
            lastArtworkHash = 0
            next.artworkRev += 1
        }
        _snapshot = next
        lock.unlock()
    }

    /// True (and swallows the update) when the payload shouldn't replace
    /// what we're showing yet:
    ///  - empty payload (MediaRemote hiccup around track changes / probe
    ///    timeout): ignored for up to 3 polls (~6s) while we hold metadata
    ///  - "low quality" payload — title only, no artist/album/duration —
    ///    which is what a web page's media element reports when it briefly
    ///    grabs the system Now Playing slot: ignored for up to 5 polls
    ///    (~10s) while we hold a real song. If it persists longer, it *is*
    ///    what's playing, so it shows through.
    /// Any full-quality payload resets the streak and always applies.
    private func shouldIgnoreAsTransientEmpty(_ next: Snapshot) -> Bool {
        let isEmpty = next.title.isEmpty && next.artist.isEmpty && next.duration <= 0
        let isGood = !next.title.isEmpty
            && (!next.artist.isEmpty || !next.album.isEmpty || next.duration > 0)
        lock.lock()
        defer { lock.unlock() }
        if isGood {
            emptyStreak = 0
            return false
        }
        emptyStreak += 1
        let holdingRealSong = !_snapshot.title.isEmpty && !_snapshot.artist.isEmpty
        if isEmpty {
            return !_snapshot.title.isEmpty && emptyStreak < emptyStreakToClear
        }
        return holdingRealSong && emptyStreak < 5 // low-quality (web page) source
    }

    private func currentLocked() -> Snapshot {
        var s = _snapshot
        if s.playing, s.duration > 0 {
            s.elapsed = max(0, min(s.duration, s.elapsed + Date().timeIntervalSince(s.updatedAt)))
        }
        return s
    }

    private static func makeCoverRGB565(from data: Data, w: Int, h: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let scale = max(CGFloat(w) / CGFloat(image.width), CGFloat(h) / CGFloat(image.height))
        let dw = CGFloat(image.width) * scale
        let dh = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2,
                                   width: dw, height: dh))
        guard let rendered = ctx.data else { return nil }
        let pixels = rendered.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out = Data(capacity: w * h * 2)
        for i in 0..<(w * h) {
            let r = pixels[i * 4 + 0]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            let rgb565 = (UInt16(r & 0xF8) << 8) | (UInt16(g & 0xFC) << 3) | UInt16(b >> 3)
            out.append(UInt8((rgb565 >> 8) & 0xFF))
            out.append(UInt8(rgb565 & 0xFF))
        }
        return out
    }

    private static func runProbe() -> [String: Any]? {
        guard let script = ensureProbeScript() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [script.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func ensureProbeScript() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aiclock-nowplaying-probe.swift")
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try probeScript.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return url
    }

    private static let probeScript = #"""
import Foundation
import Dispatch

typealias Fn = @convention(c) (DispatchQueue, @escaping ([AnyHashable: Any]?) -> Void) -> Void

func stringValue(_ any: Any?) -> String {
    (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func doubleValue(_ any: Any?) -> Double? {
    if let n = any as? NSNumber { return n.doubleValue }
    if let d = any as? Double { return d }
    return nil
}

func dateValue(_ any: Any?) -> Date? {
    if let d = any as? Date { return d }
    if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
    return nil
}

func dataValue(_ any: Any?) -> Data? {
    if let d = any as? Data { return d }
    if let d = any as? NSData { return d as Data }
    return nil
}

let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(path, RTLD_NOW),
      let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
    print("{}")
    exit(0)
}
let fn = unsafeBitCast(sym, to: Fn.self)
let sem = DispatchSemaphore(value: 0)
var output: [String: Any] = [:]
fn(.main) { info in
    let info = info ?? [:]
    let now = Date()
    let timestamp = dateValue(info["kMRMediaRemoteNowPlayingInfoTimestamp"])
    let rate = doubleValue(info["kMRMediaRemoteNowPlayingInfoPlaybackRate"]) ?? 0
    let rawElapsed = doubleValue(info["kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?? 0
    let duration = doubleValue(info["kMRMediaRemoteNowPlayingInfoDuration"]) ?? 0
    var elapsed = rawElapsed
    if rate > 0, let timestamp {
        elapsed += now.timeIntervalSince(timestamp) * rate
    }
    elapsed = duration > 0 ? max(0, min(duration, elapsed)) : max(0, elapsed)
    let artwork = dataValue(info["kMRMediaRemoteNowPlayingInfoArtworkData"])
    output = [
        "title": stringValue(info["kMRMediaRemoteNowPlayingInfoTitle"]),
        "artist": stringValue(info["kMRMediaRemoteNowPlayingInfoArtist"]),
        "album": stringValue(info["kMRMediaRemoteNowPlayingInfoAlbum"]),
        "playing": rate > 0.01,
        "elapsed": elapsed,
        "duration": duration,
        "artwork_b64": artwork?.base64EncodedString() ?? "",
    ]
    sem.signal()
}
RunLoop.main.perform { }
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    sem.signal()
}
while sem.wait(timeout: .now()) != .success {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
let data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data("{}".utf8)
FileHandle.standardOutput.write(data)
"""#

    private func stringValue(_ any: Any?) -> String {
        (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        return nil
    }

    private func dateValue(_ any: Any?) -> Date? {
        if let d = any as? Date { return d }
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    private func dataValue(_ any: Any?) -> Data? {
        if let d = any as? Data { return d }
        if let d = any as? NSData { return d as Data }
        return nil
    }
}
