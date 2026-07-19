import Foundation

// Wired (USB serial) transport to the clock, for WiFi networks with client
// isolation - or for skipping WiFi setup entirely. Scans for CH340-style
// serial ports, handshakes, then pushes the same payloads the device would
// otherwise poll over HTTP, as newline-terminated frames:
//   bridge -> device:  #HELLO   #STATUS {json}   #NET {json}   #STOCK {json}
//                      #WEATHER {json}   #DEEPSEEK {json}   #MUSIC {json}   #CMD {json}
//                      #BG <rev> <b64len> / #STRIP <id> <rev> <b64len>
//                      / #COVER <rev> <b64len> / #MTEXT <rev> <b64len>
//                      + #C <base64> chunks + #E   (wallpaper, CJK strips, music art)
//   device -> bridge:  #DEVICE {"name":"aiclock","fw":"x.y.z"}   #NEED (re-push request)
// Device log lines (anything not starting with '#') are ignored.
//
// NOTE: the port is opened non-exclusively so esptool/pio can still flash,
// but quit the app before flashing to avoid the two readers fighting.
final class SerialLink {
    private let service: StatusService
    private let netMonitor: NetSpeedMonitor
    private let stockMonitor: StockMonitor
    private let nowPlaying: NowPlayingMonitor

    private var fd: Int32 = -1
    private var portPath = ""
    private var linked = false // saw #DEVICE from the clock on this port
    private var openedAt = Date.distantPast
    private var lastHelloAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var lastNetAt = Date.distantPast
    private var rxBuf = Data()
    private var timer: Timer?

    // Bulk push (wallpaper + CJK strips + music art) for wired-only devices
    // that can't reach the HTTP endpoints. One transfer at a time, base64
    // chunk lines ("#C ..."), paced at ~2 chunks per 250ms tick so the
    // 115200-baud line and the device's 2KB UART buffer are never overrun.
    // Control frames (#STATUS/#NET/...) always jump the queue ahead of bulk
    // chunks.
    private var ctrlQueue: [Data] = []
    private var bulkChunks: [Data] = []
    private var bulkActive = false
    private var pushedBgRev = -1
    private var pushedNameRev = -1
    private var pushedHiloRev = -1
    private var pushedDateRev = -1
    private var pushedCoverRev = -1
    private var pushedMTextRev = -1
    private static let chunkChars = 960 // base64 chars per #C line (720 raw bytes)
    private static let chunksPerTick = 2

    init(service: StatusService, netMonitor: NetSpeedMonitor, stockMonitor: StockMonitor,
         nowPlaying: NowPlayingMonitor) {
        self.service = service
        self.netMonitor = netMonitor
        self.stockMonitor = stockMonitor
        self.nowPlaying = nowPlaying
    }

    func start() {
        // one 250ms tick drives everything: port scan, handshake, reads, pushes
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    var isLinked: Bool { linked }

    private func tick() {
        if fd < 0 {
            scanAndOpen()
            return
        }
        readPending()
        let now = Date()
        if !linked {
            // handshake: #HELLO every 3s; give up on this port after 30s
            if now.timeIntervalSince(openedAt) > 30 {
                closePort()
                return
            }
            if now.timeIntervalSince(lastHelloAt) > 3 {
                lastHelloAt = now
                send("#HELLO\n".data(using: .utf8)!)
            }
            return
        }
        if now.timeIntervalSince(lastStatusAt) > 5 {
            lastStatusAt = now
            ctrlQueue.append(frame("#STATUS ", service.snapshot().jsonData()))
            ctrlQueue.append(frame("#STOCK ", stockMonitor.jsonData()))
            ctrlQueue.append(frame("#WEATHER ", WeatherMonitor.shared.jsonData()))
            ctrlQueue.append(frame("#DEEPSEEK ", DeepSeekMonitor.shared.jsonData()))
            checkBulkPush()
        }
        if now.timeIntervalSince(lastNetAt) > 2 {
            lastNetAt = now
            let stats = SystemStatsMonitor.shared.snapshot()
            ctrlQueue.append(frame("#NET ", netMonitor.jsonData(cpu: stats.cpu, mem: stats.mem)))
            ctrlQueue.append(frame("#MUSIC ", nowPlaying.jsonData()))
        }
        drainQueue()
    }

    // MARK: - bulk push (wallpaper + strips + music art)

    /// Queue a bulk transfer when any rev moved. Wallpaper first (it carries
    /// the baked-in CJK lines), then the standalone strips for devices with
    /// the wallpaper toggled off, then music cover / title strip.
    private func checkBulkPush() {
        let bgRev = ClockBackground.shared.rev
        if bgRev != pushedBgRev {
            let data = ClockBackground.shared.rgb565()
            if data.count == 240 * 240 * 2, startBulk(header: "#BG \(bgRev)", payload: data) {
                pushedBgRev = bgRev
                return // one transfer at a time; the rest follow on later ticks
            }
        }
        guard !bulkActive else { return }
        let name = WeatherMonitor.shared.nameStrip()
        if name.rev != pushedNameRev, !name.data.isEmpty {
            if startBulk(header: "#STRIP 0 \(name.rev)", payload: name.data) { pushedNameRev = name.rev }
            return
        }
        let hilo = WeatherMonitor.shared.hiloStrip()
        if hilo.rev != pushedHiloRev, !hilo.data.isEmpty {
            if startBulk(header: "#STRIP 1 \(hilo.rev)", payload: hilo.data) { pushedHiloRev = hilo.rev }
            return
        }
        let dateRev = Self.dateRev()
        if dateRev != pushedDateRev {
            let data = DateStrip.rgb565()
            if data.count == DateStrip.W * DateStrip.H * 2,
               startBulk(header: "#STRIP 2 \(dateRev)", payload: data) { pushedDateRev = dateRev }
            return
        }
        let cover = nowPlaying.coverStrip()
        if cover.rev != pushedCoverRev, cover.data.count == 128 * 128 * 2 {
            if startBulk(header: "#COVER \(cover.rev)", payload: cover.data) { pushedCoverRev = cover.rev }
            return
        }
        let mtext = nowPlaying.textStrip()
        if mtext.rev != pushedMTextRev, mtext.data.count == NowPlayingMonitor.textW * NowPlayingMonitor.textH * 2 {
            if startBulk(header: "#MTEXT \(mtext.rev)", payload: mtext.data) { pushedMTextRev = mtext.rev }
        }
    }

    /// Day-of-year based rev: bumps once per local day, like the device's
    /// tmYdayRev used for the /date.raw pull.
    private static func dateRev() -> Int {
        let cal = Calendar.current
        let now = Date()
        return cal.component(.year, from: now) * 1000 + cal.ordinality(of: .day, in: .year, for: now)!
    }

    private func startBulk(header: String, payload: Data) -> Bool {
        guard !bulkActive else { return false }
        let b64 = payload.base64EncodedString()
        bulkChunks.removeAll(keepingCapacity: true)
        bulkChunks.append(Data("\(header) \(b64.count)\n".utf8))
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: Self.chunkChars, limitedBy: b64.endIndex) ?? b64.endIndex
            bulkChunks.append(Data("#C \(b64[i..<j])\n".utf8))
            i = j
        }
        bulkChunks.append(Data("#E\n".utf8))
        bulkActive = true
        FileHandle.standardError.write(Data("[serial] bulk push \(header): \(payload.count) B, \(bulkChunks.count - 2) chunks\n".utf8))
        return true
    }

    /// Control frames first, then up to chunksPerTick bulk chunks — keeps the
    /// line under its ~11.5 KB/s rate and #STATUS latency under a second even
    /// while a 115 KB wallpaper is streaming.
    private func drainQueue() {
        while let d = ctrlQueue.first {
            ctrlQueue.removeFirst()
            send(d)
        }
        guard bulkActive else { return }
        for _ in 0..<Self.chunksPerTick {
            guard !bulkChunks.isEmpty else { break }
            send(bulkChunks.removeFirst())
        }
        if bulkChunks.isEmpty {
            bulkActive = false
        }
    }

    private func frame(_ prefix: String, _ json: Data) -> Data {
        var d = Data(prefix.utf8)
        d.append(json) // JSONSerialization output is single-line
        d.append(0x0A)
        return d
    }

    // MARK: - port lifecycle

    private func scanAndOpen() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let candidates = names.filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial")
        }.sorted()
        for name in candidates where openPort("/dev/" + name) {
            return
        }
    }

    private func openPort(_ path: String) -> Bool {
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return false }
        var tio = termios()
        tcgetattr(f, &tio)
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(HUPCL) // don't hang-up-reset the board on close
        tcsetattr(f, TCSANOW, &tio)
        // Deassert DTR+RTS so the CH340 auto-reset circuit lets the ESP run.
        // TIOCMBIC = _IOW('t', 107, int); TIOCM_DTR|TIOCM_RTS = 0x006.
        var bits: Int32 = 0x006
        _ = ioctl(f, 0x8004_746B, &bits)
        fd = f
        portPath = path
        linked = false
        openedAt = Date()
        lastHelloAt = .distantPast
        rxBuf.removeAll()
        FileHandle.standardError.write(Data("[serial] trying \(path)\n".utf8))
        return true
    }

    private func closePort() {
        if fd >= 0 { close(fd) }
        if linked || fd >= 0 {
            FileHandle.standardError.write(Data("[serial] closed \(portPath)\n".utf8))
        }
        fd = -1
        portPath = ""
        linked = false
        ctrlQueue.removeAll()
        bulkChunks.removeAll()
        bulkActive = false
    }

    // MARK: - I/O

    private let writeQueue = DispatchQueue(label: "aiclock.serial.write")

    private func send(_ data: Data) {
        guard fd >= 0 else { return }
        let port = fd
        // Writes go through a serial queue with a partial-write loop: the
        // port is O_NONBLOCK, so a plain write() silently drops bytes once
        // the OS buffer fills (that corrupted bulk pushes before).
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < data.count {
                    if self.fd != port { return } // port closed/reopened mid-stream
                    let n = write(port, base + off, data.count - off)
                    if n > 0 {
                        off += n
                    } else if n < 0 && (errno == ENXIO || errno == EIO || errno == EBADF || errno == ENODEV) {
                        DispatchQueue.main.async { self.closePort() } // unplugged
                        return
                    } else {
                        usleep(2000) // EAGAIN: OS buffer full, retry shortly
                    }
                }
            }
        }
    }

    private func readPending() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                rxBuf.append(contentsOf: buf[0..<n])
                if rxBuf.count > 16384 { rxBuf.removeAll() } // runaway noise
                continue
            }
            if n == 0 || (n < 0 && errno != EAGAIN) { closePort() } // EOF / unplugged
            break
        }
        while let nl = rxBuf.firstIndex(of: 0x0A) {
            let lineData = rxBuf.prefix(upTo: nl)
            rxBuf.removeSubrange(...nl)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if line.hasPrefix("#DEVICE") {
                if !linked {
                    linked = true
                    lastStatusAt = .distantPast // push a status immediately
                    lastNetAt = .distantPast
                    // fresh device: re-push wallpaper + strips even if the revs
                    // didn't change on our side (its flash may hold another rev)
                    pushedBgRev = -1
                    pushedNameRev = -1
                    pushedHiloRev = -1
                    pushedDateRev = -1
                    pushedCoverRev = -1
                    pushedMTextRev = -1
                    FileHandle.standardError.write(Data("[serial] linked \(portPath): \(line)\n".utf8))
                }
            } else if line.hasPrefix("#NEED") {
                // device missed a bulk transfer (e.g. a corrupted one): re-push
                pushedBgRev = -1
                pushedNameRev = -1
                pushedHiloRev = -1
                pushedDateRev = -1
                pushedCoverRev = -1
                pushedMTextRev = -1
                checkBulkPush()
            }
            // anything else is the device's debug log - ignore
        }
    }
}
