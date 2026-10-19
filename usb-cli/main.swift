import Foundation
import Network
import Darwin
import CoreGraphics

private let defaultPort: UInt16 = 8765

/// The USB-only importer writes the 144x144 AIPET1 format used by the
/// enlarged ESP pet. Keep the desktop app's 120x120 encoder unchanged.
private enum HighResPetPackageBuilder {
    static let targetWidth = 144
    static let targetHeight = 144

    static func buildDeviceFile(from package: CodexPetPackage) throws -> Data {
        let entrySize = 12
        let headerSize = 20 + CodexPetPackageService.states.count * entrySize
        var payload = Data(capacity: CodexPetPackageService.states.reduce(0) { $0 + $1.frames } * targetWidth * targetHeight)
        var entries: [(frames: Int, delay: Int, offset: Int, length: Int)] = []

        for (row, state) in CodexPetPackageService.states.enumerated() {
            let offset = headerSize + payload.count
            for column in 0..<state.frames {
                guard let frame = renderFrame(sheet: package.spritesheet, row: row, column: column) else {
                    throw NSError(domain: "aiclock-usb", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "无法转换 \(state.id) 第 \(column + 1) 帧"])
                }
                payload.append(frame)
            }
            entries.append((state.frames, max(50, state.durationMs / state.frames),
                            offset, state.frames * targetWidth * targetHeight))
        }

        var out = Data("AIPET1".utf8)
        appendLE(UInt16(targetWidth), to: &out)
        appendLE(UInt16(targetHeight), to: &out)
        out.append(UInt8(CodexPetPackageService.states.count))
        out.append(0)
        appendLE(UInt32(headerSize + payload.count), to: &out)
        appendLE(CodexPetPackageService.crc32(payload), to: &out)
        for entry in entries {
            out.append(UInt8(entry.frames))
            out.append(0)
            appendLE(UInt16(entry.delay), to: &out)
            appendLE(UInt32(entry.offset), to: &out)
            appendLE(UInt32(entry.length), to: &out)
        }
        out.append(payload)
        return out
    }

    private static func renderFrame(sheet: CGImage, row: Int, column: Int) -> Data? {
        let cropRect = CGRect(x: column * CodexPetPackageService.cellWidth,
                              y: row * CodexPetPackageService.cellHeight,
                              width: CodexPetPackageService.cellWidth,
                              height: CodexPetPackageService.cellHeight)
        guard let crop = sheet.cropping(to: cropRect) else { return nil }
        let bytesPerRow = targetWidth * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * targetHeight)
        guard let ctx = CGContext(data: &rgba, width: targetWidth, height: targetHeight,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.black)
        ctx.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        let scale = min(CGFloat(targetWidth) / CGFloat(CodexPetPackageService.cellWidth),
                        CGFloat(targetHeight) / CGFloat(CodexPetPackageService.cellHeight))
        let w = CGFloat(CodexPetPackageService.cellWidth) * scale
        let h = CGFloat(CodexPetPackageService.cellHeight) * scale
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: (CGFloat(targetWidth) - w) / 2,
                                  y: (CGFloat(targetHeight) - h) / 2, width: w, height: h))

        var rgb332 = Data(count: targetWidth * targetHeight)
        rgb332.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for i in 0..<(targetWidth * targetHeight) {
                let r = rgba[i * 4]
                let g = rgba[i * 4 + 1]
                let b = rgba[i * 4 + 2]
                dst[i] = (r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6)
            }
        }
        return rgb332
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

final class USBClock {
    private static let codexPetBytes = 1_182_080
    private static let petChunkBytes = 768
    private let service: StatusService
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var port = ""
    private var linked = false
    private var lastTry = Date.distantPast
    private var lastHello = Date.distantPast
    private var lastStatus = Date.distantPast
    private var lastInfo = Date.distantPast
    private var input = Data()
    private var timer: Timer?
    private var nextID = 1
    private var acknowledgements: [Int: [String: Any]] = [:]
    private var brightness: Int?
    private var display: String?
    private var effectiveDisplay: String?
    private var screenOn: Bool?
    private var wiredActive: Bool?
    private var devicePetState: String?
    private var firmware = ""
    private var protocolVersion = 0
    private var customPet = false
    private var petUploadActive = false
    private var petUploadSent = 0
    private var petUploadTotal = 0
    private var petUploadError: String?
    private var petUploadDone = false

    init(service: StatusService) { self.service = service }

    var state: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["connected": linked, "port": port, "brightness": brightness.map { $0 as Any } ?? NSNull(),
                "display": display ?? NSNull(), "screen_on": screenOn.map { $0 as Any } ?? NSNull(),
                "effective_display": effectiveDisplay ?? NSNull(),
                "wired_active": wiredActive.map { $0 as Any } ?? NSNull(),
                "device_pet_state": devicePetState ?? NSNull(),
                "fw": firmware, "protocol": protocolVersion, "custom_pet": customPet,
                "pet_upload": ["active": petUploadActive, "sent": petUploadSent, "total": petUploadTotal,
                               "done": petUploadDone, "error": petUploadError.map { $0 as Any } ?? NSNull()]]
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func setBrightness(_ level: Int) -> [String: Any]? {
        guard (0...100).contains(level) else { return nil }
        return command(["brightness": level])
    }

    func setDisplay(_ mode: String) -> [String: Any]? {
        guard ["auto", "claude", "codex", "net", "music", "stock"].contains(mode) else { return nil }
        return command(["display": mode])
    }

    func setAgentEvent(_ type: String, ttlMs: Int) -> [String: Any]? {
        guard ["thinking", "tool-running", "reviewing", "success", "failure", "attention"].contains(type) else { return nil }
        return command(["event": type, "ttl_ms": min(max(ttlMs, 250), 600_000)])
    }

    /// Hooks are latency-sensitive: push the freshly aggregated status now
    /// instead of waiting for the next periodic serial tick.
    @discardableResult
    func pushStatusNow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard linked, !petUploadActive else { return false }
        lastStatus = Date()
        var frame = Data("#STATUS ".utf8)
        frame.append(service.snapshot().jsonData())
        frame.append(0x0A)
        return writeLocked(frame)
    }

    func resetCodexPet() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard !petUploadActive else { return nil }
        let ack = commandLocked(["pet_reset": true])
        if ack?["ok"] as? Bool == true { customPet = false }
        return ack
    }

    func uploadCodexPet(_ data: Data) -> Bool {
        lock.lock()
        guard linked, protocolVersion >= 3, !petUploadActive,
              data.count == Self.codexPetBytes, data.starts(with: Data("AIPET1".utf8)) else {
            lock.unlock()
            return false
        }
        petUploadActive = true
        petUploadSent = 0
        petUploadTotal = data.count
        petUploadError = nil
        petUploadDone = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performPetUpload(data)
        }
        return true
    }

    private func performPetUpload(_ data: Data) {
        let crc = Self.crc32(data)
        guard let begin = request(prefix: "#PET_BEGIN ", body: ["bytes": data.count, "crc32": crc], timeout: 5),
              begin["ok"] as? Bool == true else {
            return finishPetUpload(error: "设备拒绝开始上传")
        }
        var sequence = 0
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.petChunkBytes, data.count)
            let encoded = data.subdata(in: offset..<end).base64EncodedString()
            guard let ack = request(prefix: "#PET_CHUNK ",
                                    body: ["seq": sequence, "data": encoded], timeout: 5),
                  ack["ok"] as? Bool == true else {
                return finishPetUpload(error: "USB 分块 (sequence) 写入失败")
            }
            offset = end
            sequence += 1
            lock.lock(); petUploadSent = offset; lock.unlock()
        }
        guard let end = request(prefix: "#PET_END ", body: [:], timeout: 30) else {
            return finishPetUpload(error: "设备校验或安装失败")
        }
        guard end["ok"] as? Bool == true else {
            let detail = end["error"] as? String ?? "未知错误"
            return finishPetUpload(error: "设备校验或安装失败：\(detail)")
        }
        lock.lock(); customPet = true; lock.unlock()
        finishPetUpload(error: nil)
    }

    private func finishPetUpload(error: String?) {
        lock.lock()
        petUploadActive = false
        petUploadDone = error == nil
        petUploadError = error
        lock.unlock()
    }

    private func command(_ body: [String: Any]) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return commandLocked(body)
    }

    private func commandLocked(_ body: [String: Any]) -> [String: Any]? {
        requestLocked(prefix: "#CMD ", body: body, timeout: 1)
    }

    private func request(prefix: String, body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return requestLocked(prefix: prefix, body: body, timeout: timeout)
    }

    private func requestLocked(prefix: String, body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard linked else { return nil }
        let id = nextID; nextID += 1
        var payload = body; payload["id"] = id
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var frame = Data(prefix.utf8); frame.append(json); frame.append(0x0A)
        guard writeLocked(frame) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            readPending()
            if let ack = acknowledgements.removeValue(forKey: id) { return ack }
            usleep(10_000)
        }
        return nil
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        if fd < 0 {
            if Date().timeIntervalSince(lastTry) > 2 { lastTry = Date(); openFirstPort() }
            return
        }
        readPending()
        let now = Date()
        if !linked {
            if now.timeIntervalSince(lastHello) > 2 {
                lastHello = now
                _ = writeLocked(Data("#HELLO\n".utf8))
            }
            return
        }
        if petUploadActive { return }
        let mainScreenOn = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if screenOn != mainScreenOn {
            screenOn = mainScreenOn
            _ = commandLocked(["screen": mainScreenOn ? "on" : "off"])
        }
        if now.timeIntervalSince(lastStatus) > 2 {
            lastStatus = now
            var frame = Data("#STATUS ".utf8)
            frame.append(service.snapshot().jsonData())
            frame.append(0x0A)
            _ = writeLocked(frame)
        }
        // Keep device-side telemetry fresh enough to distinguish a real
        // display-state lag from stale bridge cache after short pet events.
        if now.timeIntervalSince(lastInfo) > 2 {
            lastInfo = now
            let id = nextID; nextID += 1
            _ = writeLocked(Data("#INFO? {\"id\":\(id)}\n".utf8))
        }
    }

    private func openFirstPort() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial")
        }.sorted()
        for name in names where openPort("/dev/" + name) { return }
    }

    private func openPort(_ path: String) -> Bool {
        let candidate = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard candidate >= 0 else { return false }
        var tio = termios()
        guard tcgetattr(candidate, &tio) == 0 else { Darwin.close(candidate); return false }
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(candidate, TCSANOW, &tio) == 0 else { Darwin.close(candidate); return false }
        fd = candidate; port = path; linked = false; input.removeAll()
        FileHandle.standardError.write(Data("[usb] trying \(path)\n".utf8))
        return true
    }

    private func closePort() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1; port = ""; linked = false; input.removeAll()
    }

    private func send(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return writeLocked(data)
    }

    private func writeLocked(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        var offset = 0
        let deadline = Date().addingTimeInterval(2)
        while offset < data.count {
            let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if wrote > 0 { offset += wrote; continue }
            if wrote < 0 && errno == EINTR { continue }
            if wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK), Date() < deadline {
                usleep(2_000)
                continue
            }
            closePort(); return false
        }
        return true
    }

    private func readPending() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { input.append(contentsOf: buffer[0..<count]); continue }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { closePort() }
            break
        }
        while let newline = input.firstIndex(of: 0x0A) {
            let line = String(decoding: input[..<newline], as: UTF8.self)
            input.removeSubrange(...newline)
            if line.hasPrefix("#DEVICE") {
                linked = true; lastStatus = .distantPast; lastInfo = .distantPast
                if let data = line.dropFirst(8).data(using: .utf8),
                   let device = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    firmware = device["fw"] as? String ?? firmware
                    protocolVersion = (device["protocol"] as? NSNumber)?.intValue ?? 0
                }
                FileHandle.standardError.write(Data("[usb] connected \(port)\n".utf8))
            }
            if line.hasPrefix("#ACK "), let data = line.dropFirst(5).data(using: .utf8),
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = ack["id"] as? Int {
                acknowledgements[id] = ack
                brightness = (ack["brightness"] as? NSNumber)?.intValue ?? brightness
                display = ack["display"] as? String ?? display
                screenOn = ack["screen_on"] as? Bool ?? screenOn
            }
            if line.hasPrefix("#INFO "), let data = line.dropFirst(6).data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                brightness = (info["brightness"] as? NSNumber)?.intValue ?? brightness
                display = info["display"] as? String ?? display
                effectiveDisplay = info["effective"] as? String ?? effectiveDisplay
                screenOn = info["screen_on"] as? Bool ?? screenOn
                wiredActive = info["wired"] as? Bool ?? wiredActive
                firmware = info["fw"] as? String ?? firmware
                customPet = info["custom_pet"] as? Bool ?? customPet
                devicePetState = info["pet_state"] as? String ?? devicePetState
            }
        }
        if input.count > 16_384 { input.removeAll() }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

final class LocalServer {
    private let service: StatusService
    private let clock: USBClock
    private let listener: NWListener
    private let queue = DispatchQueue(label: "aiclock-usb.http")

    init(port: UInt16, service: StatusService, clock: USBClock) throws {
        self.service = service; self.clock = clock
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    }

    func start() { listener.start(queue: queue) }

    private func accept(_ connection: NWConnection) {
        if case let .hostPort(host, _) = connection.endpoint,
           host != .ipv4(.loopback), host != .ipv6(.loopback) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            var request = buffer
            request.append(data)
            guard request.count <= 900_000 else {
                return self.respond(connection, code: "413 Payload Too Large", type: "text/plain",
                                    payload: Data("pet package too large".utf8))
            }
            let separator = Data("\r\n\r\n".utf8)
            guard let headerRange = request.range(of: separator) else {
                return self.receiveRequest(connection, buffer: request)
            }
            let header = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
            // CRLF is one extended grapheme in Swift, so splitting on the
            // literal "\n" can leave the entire header as one element.
            let contentLength = header.split(whereSeparator: { $0.isNewline })
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") } ?? 0
            let expected = headerRange.upperBound + contentLength
            guard request.count >= expected else {
                return self.receiveRequest(connection, buffer: request)
            }
            self.reply(connection, request: request.prefix(expected))
        }
    }

    private func reply(_ connection: NWConnection, request: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = request.range(of: separator) else {
            return respond(connection, code: "400 Bad Request", type: "text/plain", payload: Data("bad request".utf8))
        }
        let text = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
        let lines = text.split(whereSeparator: { $0.isNewline })
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.dropFirst().first.map { String($0.split(separator: "?").first ?? "") } ?? "/"
        let body = request.subdata(in: headerRange.upperBound..<request.count)
        var code = "200 OK", type = "application/json; charset=utf-8", payload = Data()
        if method == "GET" && path == "/" {
            type = "text/html; charset=utf-8"; payload = Data(Self.page.utf8)
        } else if method == "GET" && path == "/api/status" {
            payload = statusData()
        } else if method == "POST" && path == "/api/brightness" {
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let level = (value?["level"] as? NSNumber)?.intValue ?? -1
            if let ack = clock.setBrightness(level), (ack["ok"] as? Bool) == true { payload = json(ack) }
            else { code = "409 Conflict"; payload = json(["error": "Clock did not confirm the brightness command"]) }
        } else if method == "POST" && path == "/api/display" {
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let mode = value?["mode"] as? String, let ack = clock.setDisplay(mode), (ack["ok"] as? Bool) == true { payload = json(ack) }
            else { code = "409 Conflict"; payload = json(["error": "Clock did not confirm the display command"]) }
        } else if method == "POST" && (path == "/event" || path == "/api/event") {
            guard let event = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return respond(connection, code: "400 Bad Request", type: type,
                               payload: json(["ok": false, "error": "JSON body required"]))
            }
            if let eventType = event["type"] as? String {
                guard ["thinking", "tool-running", "reviewing", "success", "failure", "attention"].contains(eventType) else {
                    return respond(connection, code: "400 Bad Request", type: type,
                                   payload: json(["ok": false, "error": "unsupported agent event type"]))
                }
                let ttlMs = (event["ttlMs"] as? NSNumber)?.intValue ?? 4_000
                if let ack = clock.setAgentEvent(eventType, ttlMs: ttlMs), (ack["ok"] as? Bool) == true {
                    payload = json(["ok": true, "type": eventType, "ttlMs": ttlMs])
                } else {
                    code = "409 Conflict"; payload = json(["ok": false, "error": "Clock did not confirm the agent event"])
                }
            } else if let name = event["event"] as? String {
                let agent = event["agent"] as? String ?? "codex"
                let sessionID = event["session_id"] as? String ?? event["conversation_id"] as? String
                service.recordEvent(agent: agent, event: name, message: event["message"] as? String,
                                    sessionID: sessionID)
                // Lifecycle state is carried by #STATUS. Do not also install
                // a long-lived device event overlay: firmware prioritizes that
                // overlay over pet_state and could stay "running" for 10 min
                // after JSONL already reported task_complete/turn_aborted.
                _ = clock.pushStatusNow()
                payload = json(["ok": true])
            } else {
                code = "400 Bad Request"; payload = json(["ok": false, "error": "type or event required"])
            }
        } else if method == "POST" && path == "/api/pet/codex" {
            if clock.uploadCodexPet(body) {
                code = "202 Accepted"; payload = json(["ok": true, "bytes": body.count])
            } else {
                code = "409 Conflict"
                payload = json(["ok": false, "error": "USB 未连接、固件过旧、包无效或已有上传任务"])
            }
        } else if method == "POST" && path == "/api/pet/reset" {
            if let ack = clock.resetCodexPet(), (ack["ok"] as? Bool) == true {
                payload = json(["ok": true])
            } else {
                code = "409 Conflict"; payload = json(["ok": false, "error": "设备未确认恢复默认宠物"])
            }
        } else { code = "404 Not Found"; type = "text/plain; charset=utf-8"; payload = Data("not found".utf8) }
        respond(connection, code: code, type: type, payload: payload)
    }

    private func respond(_ connection: NWConnection, code: String, type: String, payload: Data) {
        let header = "HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8); response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func statusData() -> Data {
        let s = service.snapshot().codex
        return json([
            "usb": clock.state,
            "codex": ["status": s.status, "pet_state": s.petState, "needs_input": s.needsInput,
                      "active_tasks": s.activeTasks,
                      "weekly_pct": s.weeklyPct.map { $0 as Any } ?? NSNull(), "weekly_reset_min": s.weeklyResetMin.map { $0 as Any } ?? NSNull(),
                      "primary_pct": s.primaryPct.map { $0 as Any } ?? NSNull(), "primary_reset_min": s.primaryResetMin.map { $0 as Any } ?? NSNull()]
        ])
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8) }

    private static let page = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>AI Clock USB</title>
    <style>
    body{margin:0;background:#101114;color:#e8eaed;font:15px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:620px;margin:5vh auto;padding:28px;border:1px solid #2c3038;border-radius:14px;background:#181a1f}h1{font-size:20px;margin:0 0 22px}h2{font-size:17px;margin:28px 0 10px}.row{display:flex;justify-content:space-between;align-items:center;padding:13px 0;border-top:1px solid #2c3038}.muted,#notice,#petNotice{color:#9aa0a6}strong{font-variant-numeric:tabular-nums}input[type=range],input[type=file],progress{width:100%}input{accent-color:#8ab4f8}button{margin:12px 8px 0 0;padding:9px 13px;border:0;border-radius:7px;background:#8ab4f8;color:#101114;font-weight:600}button.secondary{background:#353942;color:#e8eaed}button:disabled{opacity:.45}progress{margin-top:12px;height:12px}code{color:#8ab4f8}
    </style>
    <main><h1>AI Clock · USB</h1>
    <div class="row"><span>USB</span><strong id="usb">连接中</strong></div>
    <div class="row"><span>固件</span><strong id="fw">—</strong></div>
    <div class="row"><span>宠物</span><strong id="petKind">默认</strong></div>
    <div class="row"><span>Codex</span><strong id="status">—</strong></div>
    <div class="row"><span>ESP 实际状态</span><strong id="deviceState">—</strong></div>
    <div class="row"><span>周额度</span><strong id="weekly">—</strong></div>
    <div class="row"><span>重置</span><strong id="reset">—</strong></div>
    <div class="row"><span>显示</span><select id="mode" onchange="setMode()"><option value="auto">自动</option><option value="codex">Codex</option><option value="claude">Claude</option><option value="net">网速</option><option value="music">音乐</option><option value="stock">股票</option></select></div>
    <div class="row"><span>亮度 <strong id="level">100%</strong></span></div>
    <input id="brightness" type="range" min="0" max="100" value="100"><button onclick="save()">应用亮度</button>
    <div id="notice">网页关闭后，后台服务仍持续更新时钟。</div>

    <h2>Codex 九状态宠物</h2>
    <p class="muted">选择包含 <code>pet.json</code> 与 spritesheet 的标准 Codex v1/v2 宠物目录。图片只在本机转换，然后经 USB 写入设备。</p>
    <input id="petFolder" type="file" webkitdirectory multiple>
    <button id="petUpload" onclick="uploadPet()">转换并上传</button>
    <button id="petReset" class="secondary" onclick="resetPet()">恢复默认宠物</button>
    <progress id="petProgress" max="100" value="0"></progress>
    <div id="petNotice">尚未选择宠物目录。</div>
    </main>
    <script>
    const $=id=>document.getElementById(id), fmt=n=>n==null?'—':n+'%', fmtMin=n=>n==null?'—':n<60?n+' 分钟':Math.floor(n/60)+' 小时';
    const states=[[6,1100],[8,1060],[8,1060],[4,700],[5,840],[8,1220],[6,1010],[6,820],[6,1030]], frameW=192,frameH=208,target=144,headerBytes=128,totalBytes=1182080;
    let lastUploadActive=false;
    async function load(){try{let x=await fetch('/api/status').then(r=>r.json()),c=x.codex,u=x.usb,p=u.pet_upload;$('usb').textContent=u.connected?'已连接 '+u.port:'未连接';$('fw').textContent=u.fw?(u.fw+' · 协议 '+u.protocol):'—';$('petKind').textContent=u.custom_pet?'自定义九状态':'默认';$('status').textContent=c.status+' · '+c.pet_state+' · '+c.active_tasks+' agent';$('deviceState').textContent=u.device_pet_state||'—';$('weekly').textContent=fmt(c.weekly_pct);$('reset').textContent=fmtMin(c.weekly_reset_min);if(u.brightness!=null){$('brightness').value=u.brightness;$('level').textContent=u.brightness+'%'}if(u.display)$('mode').value=u.display;if(p){let pct=p.total?Math.round(p.sent*100/p.total):0;$('petProgress').value=pct;$('petReset').disabled=p.active;if(p.active){$('petUpload').disabled=true;$('petNotice').textContent='USB 上传中 '+pct+'%（'+p.sent+' / '+p.total+' 字节）'}else if(lastUploadActive){$('petUpload').disabled=false;$('petNotice').textContent=p.error?'上传失败：'+p.error:'✅ 九状态宠物已安装';}lastUploadActive=p.active}}catch{$('usb').textContent='服务不可用'}}
    async function call(path,body){let r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}),x=await r.json();$('notice').textContent=r.ok?'设备已确认':x.error;return r.ok}
    async function save(){await call('/api/brightness',{level:+$('brightness').value})}
    async function setMode(){await call('/api/display',{mode:$('mode').value})}
    $('brightness').oninput=()=>$('level').textContent=$('brightness').value+'%';

    function crc32(bytes){let crc=0xffffffff;for(let b of bytes){crc^=b;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0)}return (crc^0xffffffff)>>>0}
    function normalized(path){let out=[];for(let part of path.replaceAll('\\\\','/').split('/')){if(!part||part=='.')continue;if(part=='..'){if(!out.length)throw Error('spritesheetPath 越出宠物目录');out.pop()}else out.push(part)}return out.join('/')}
    async function decodeImage(file){if('createImageBitmap'in window)return await createImageBitmap(file);return await new Promise((resolve,reject)=>{let img=new Image(),url=URL.createObjectURL(file);img.onload=()=>{URL.revokeObjectURL(url);resolve(img)};img.onerror=()=>reject(Error('无法解码 spritesheet'));img.src=url})}
    async function buildPet(){let files=[...$('petFolder').files],manifests=files.filter(f=>f.name=='pet.json');if(manifests.length!=1)throw Error('所选目录必须只包含一个 pet.json');let mf=manifests[0],manifest=JSON.parse(await mf.text());if(!manifest.id||!manifest.spritesheetPath)throw Error('pet.json 缺少 id 或 spritesheetPath');let base=mf.webkitRelativePath.split('/').slice(0,-1).join('/'),wanted=normalized((base?base+'/':'')+manifest.spritesheetPath),sheet=files.find(f=>normalized(f.webkitRelativePath)==wanted);if(!sheet)throw Error('目录中找不到 '+manifest.spritesheetPath);let image=await decodeImage(sheet),validHeight=image.height==1872||(manifest.spriteVersionNumber==2&&image.height==2288);if(image.width!=1536||!validHeight)throw Error('spritesheet 必须是 1536×1872，或 v2 的 1536×2288');let canvas=document.createElement('canvas');canvas.width=target;canvas.height=target;let ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.imageSmoothingEnabled=false;let payload=new Uint8Array(totalBytes-headerBytes),at=0,scale=Math.min(target/frameW,target/frameH),dw=frameW*scale,dh=frameH*scale;for(let row=0;row<states.length;row++){for(let col=0;col<states[row][0];col++){ctx.fillStyle='#000';ctx.fillRect(0,0,target,target);ctx.drawImage(image,col*frameW,row*frameH,frameW,frameH,(target-dw)/2,(target-dh)/2,dw,dh);let px=ctx.getImageData(0,0,target,target).data;for(let i=0;i<target*target;i++)payload[at++]=(px[i*4]&0xe0)|((px[i*4+1]&0xe0)>>3)|(px[i*4+2]>>6)}}let out=new Uint8Array(totalBytes),view=new DataView(out.buffer);out.set(new TextEncoder().encode('AIPET1'));view.setUint16(6,target,true);view.setUint16(8,target,true);out[10]=states.length;view.setUint32(12,totalBytes,true);view.setUint32(16,crc32(payload),true);let entry=20,offset=headerBytes;for(let [frames,duration] of states){out[entry]=frames;view.setUint16(entry+2,Math.max(50,Math.floor(duration/frames)),true);view.setUint32(entry+4,offset,true);view.setUint32(entry+8,frames*target*target,true);entry+=12;offset+=frames*target*target}out.set(payload,headerBytes);return out}
    async function uploadPet(){try{$('petUpload').disabled=true;$('petNotice').textContent='正在本机转换 57 帧…';$('petProgress').value=0;let pet=await buildPet();$('petNotice').textContent='正在提交给 USB bridge…';let r=await fetch('/api/pet/codex',{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:pet}),x=await r.json();if(!r.ok)throw Error(x.error||'bridge 拒绝上传');lastUploadActive=true;$('petNotice').textContent='USB 上传已开始，请保持连接';await load()}catch(e){$('petUpload').disabled=false;$('petNotice').textContent='上传失败：'+e.message}}
    async function resetPet(){if(!confirm('恢复固件内置 Codex 宠物？'))return;let r=await fetch('/api/pet/reset',{method:'POST'}),x=await r.json();$('petNotice').textContent=r.ok?'✅ 已恢复默认宠物':'恢复失败：'+x.error;if(r.ok){$('petProgress').value=0;await load()}}
    load();setInterval(load,1000);
    </script>
    """
}

private func printUsage() {
    print("Usage: aiclock-usb <serve|status|brightness|pet-preflight|pet-install|doctor|open|install|uninstall>")
}

private func installLaunchAgent() throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let binDir = home.appendingPathComponent("Library/Application Support/AIClockUSB")
    let bin = binDir.appendingPathComponent("aiclock-usb")
    try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    if fm.fileExists(atPath: bin.path) { try fm.removeItem(at: bin) }
    try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: bin)
    let plist = home.appendingPathComponent("Library/LaunchAgents/local.aiclock-usb.plist")
    let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>Label</key><string>local.aiclock-usb</string><key>ProgramArguments</key><array><string>\(bin.path)</string><string>serve</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>"
    try text.data(using: .utf8)!.write(to: plist)
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw NSError(domain: "aiclock-usb", code: 1, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed"]) }
    print("Installed. The USB bridge now starts automatically after login.")
}

private func uninstallLaunchAgent() {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.aiclock-usb.plist")
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = ["bootout", "gui/\(getuid())/local.aiclock-usb"]
    try? task.run(); task.waitUntilExit(); try? FileManager.default.removeItem(at: path)
    print("Uninstalled.")
}

let command = CommandLine.arguments.dropFirst().first ?? "serve"
let service = StatusService()
let usage = UsageFetcher(); service.usage = usage

switch command {
case "serve":
    service.refresh()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in service.refresh() }
    usage.startAutoRefresh()
    let clock = USBClock(service: service); clock.start()
    do { let server = try LocalServer(port: defaultPort, service: service, clock: clock); server.start(); print("AI Clock USB is running at http://127.0.0.1:\(defaultPort)"); RunLoop.main.run() }
    catch { fputs("Could not start server: \(error.localizedDescription)\n", stderr); exit(1) }
case "status":
    service.refreshNow()
    let s = service.snapshot().codex
    let data = try! JSONSerialization.data(withJSONObject: [
        "status": s.status, "pet_state": s.petState, "needs_input": s.needsInput,
        "active_tasks": s.activeTasks,
        "weekly_pct": s.weeklyPct.map { $0 as Any } ?? NSNull(),
        "weekly_reset_min": s.weeklyResetMin.map { $0 as Any } ?? NSNull(),
    ])
    print(String(decoding: data, as: UTF8.self))
case "brightness":
    guard let raw = CommandLine.arguments.dropFirst(2).first, let level = Int(raw), (0...100).contains(level) else { printUsage(); exit(2) }
    let clock = USBClock(service: service); clock.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let ack = clock.setBrightness(level), (ack["ok"] as? Bool) == true else { fputs("Clock did not confirm the brightness command.\n", stderr); exit(1) }
    print("Brightness confirmed: \(ack["brightness"] ?? level)%")
case "pet-preflight":
    guard let raw = CommandLine.arguments.dropFirst(2).first else { printUsage(); exit(2) }
    do {
        let source = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let package = try CodexPetPackageService.load(from: source)
        let pet = try HighResPetPackageBuilder.buildDeviceFile(from: package)
        let payloadCRC = UInt32(pet[16]) | (UInt32(pet[17]) << 8) |
                         (UInt32(pet[18]) << 16) | (UInt32(pet[19]) << 24)
        let report: [String: Any] = [
            "ok": true,
            "id": package.id,
            "display_name": package.displayName,
            "source": source.standardizedFileURL.path,
            "sprite_version": package.spritesheet.height == 2288 ? 2 : 1,
            "spritesheet": ["width": package.spritesheet.width, "height": package.spritesheet.height],
            "frames": CodexPetPackageService.states.reduce(0) { $0 + $1.frames },
            "device_bytes": pet.count,
            "payload_crc32": String(format: "%08x", payloadCRC),
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    } catch {
        fputs("Pet preflight failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "pet-install":
    guard let raw = CommandLine.arguments.dropFirst(2).first else { printUsage(); exit(2) }
    do {
        let package = try CodexPetPackageService.load(from: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        let pet = try HighResPetPackageBuilder.buildDeviceFile(from: package)
        let clock = USBClock(service: service); clock.start()
        let connectDeadline = Date().addingTimeInterval(10)
        while Date() < connectDeadline, (clock.state["connected"] as? Bool) != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard clock.uploadCodexPet(pet) else {
            fputs("Could not start pet upload. Check USB connection and firmware protocol 3.\n", stderr)
            exit(1)
        }
        var lastPct = -1
        while true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let upload = clock.state["pet_upload"] as? [String: Any] else { continue }
            let sent = upload["sent"] as? Int ?? 0
            let total = upload["total"] as? Int ?? pet.count
            let pct = total > 0 ? sent * 100 / total : 0
            if pct != lastPct { print("Uploading \(package.displayName): \(pct)%"); lastPct = pct }
            if upload["active"] as? Bool == true { continue }
            if let error = upload["error"] as? String {
                fputs("Pet upload failed: \(error)\n", stderr); exit(1)
            }
            guard upload["done"] as? Bool == true else {
                fputs("Pet upload ended without confirmation.\n", stderr); exit(1)
            }
            print("Installed \(package.displayName) over USB.")
            break
        }
    } catch {
        fputs("Pet install failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "doctor":
    let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") }
    print("USB ports: \(ports.isEmpty ? "none" : ports.map { "/dev/" + $0 }.joined(separator: ", "))")
    let auth = ("~/.codex/auth.json" as NSString).expandingTildeInPath
    print("Codex credentials: \(FileManager.default.fileExists(atPath: auth) ? "found" : "not found")")
case "open":
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/open"); task.arguments = ["http://127.0.0.1:\(defaultPort)"]; try? task.run()
case "install":
    do { try installLaunchAgent() } catch { fputs("Install failed: \(error.localizedDescription)\n", stderr); exit(1) }
case "uninstall": uninstallLaunchAgent()
default: printUsage(); exit(2)
}
