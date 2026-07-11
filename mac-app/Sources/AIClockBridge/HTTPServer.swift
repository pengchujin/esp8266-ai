import Foundation
import Network

// Tiny HTTP/1.1 server on 0.0.0.0:<port> using Network.framework so we pull in
// no third-party web-server dependency. Serves the GET routes it was given
// (JSON bodies produced per request); everything else is 404. Requests are a
// single small GET, so we just read until the end of headers and reply.
final class HTTPServer {
    private let port: NWEndpoint.Port
    private let routes: [String: () -> Data]
    private let binaryRoutes: [String: () -> Data]
    private let postRoutes: [String: (Data) -> Data]
    private let staticRoots: [String: String] // prefix -> local directory
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aiclock.http")

    /// Called (on the server queue) with (path, remoteIP) for every request.
    /// The ESP8266 polls /status constantly, so this is how the app learns
    /// the device's LAN address without any scanning.
    var onRequest: ((String, String) -> Void)?

    init(port: UInt16, routes: [String: () -> Data] = [:], binaryRoutes: [String: () -> Data] = [:],
         postRoutes: [String: (Data) -> Data] = [:], staticRoots: [String: String] = [:]) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.routes = routes
        self.binaryRoutes = binaryRoutes
        self.postRoutes = postRoutes
        self.staticRoots = staticRoots
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Serves files from configured local directories. The first matching prefix
    /// wins; the remainder of the path is appended to the directory. Only
    /// regular files inside the directory are served (no traversal).
    private func staticFile(for path: String) -> (data: Data, type: String)? {
        for (prefix, root) in staticRoots {
            guard path.hasPrefix(prefix) else { continue }
            let sub = String(path.dropFirst(prefix.count))
            guard !sub.isEmpty, !sub.contains("..") else { continue }
            let file = URL(fileURLWithPath: root).appendingPathComponent(sub)
            let base = URL(fileURLWithPath: root).standardizedFileURL.path
            let resolved = file.standardizedFileURL.path
            guard resolved.hasPrefix(base) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
                  !isDir.boolValue,
                  let data = FileManager.default.contents(atPath: resolved) else { continue }
            let ext = URL(fileURLWithPath: resolved).pathExtension.lowercased()
            let type: String
            switch ext {
            case "xml": type = "application/xml"
            case "zip": type = "application/zip"
            default: type = "application/octet-stream"
            }
            return (data, type)
        }
        return nil
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                // NB: "\r\n" is a single grapheme cluster in Swift, so a
                // Character-equality split on "\r"/"\n" never fires — use
                // isNewline, which is true for the CRLF cluster.
                let headerLines = header.split(whereSeparator: { $0.isNewline })
                let firstLine = headerLines.first ?? ""
                let parts = firstLine.split(separator: " ")
                let method = parts.count >= 1 ? String(parts[0]).uppercased() : "GET"
                let path = parts.count >= 2 ? String(parts[1]) : "/"

                // POST bodies: wait until Content-Length bytes have arrived.
                var contentLength = 0
                for line in headerLines {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        contentLength = Int(line.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                let bodyAvailable = buf.count - range.upperBound
                if method == "POST", bodyAvailable < contentLength, contentLength <= 1_000_000 {
                    if isComplete || error != nil { conn.cancel() } else { self.receive(conn, buffer: buf) }
                    return
                }
                let bodyEnd = min(buf.count, range.upperBound + contentLength)
                let requestBody = buf.subdata(in: range.upperBound..<bodyEnd)
                self.respond(conn, method: method, path: path, requestBody: requestBody)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, method: String, path: String, requestBody: Data) {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        if case let .hostPort(host, _) = conn.endpoint {
            // "192.168.1.4%en0" -> "192.168.1.4"
            let ip = String(host.debugDescription.split(separator: "%").first ?? "")
            if !ip.isEmpty { onRequest?(clean, ip) }
        }
        let body: Data
        let statusLine: String
        let contentType: String
        if method == "POST", let handler = postRoutes[clean] {
            body = handler(requestBody)
            statusLine = "200 OK"
            contentType = "application/json"
        } else if method == "GET", let provider = routes[clean] {
            body = provider()
            statusLine = "200 OK"
            contentType = "application/json"
        } else if method == "GET", let provider = binaryRoutes[clean] {
            body = provider()
            statusLine = body.isEmpty ? "404 Not Found" : "200 OK"
            contentType = "application/octet-stream"
        } else if method == "GET", let (fileData, fileType) = staticFile(for: clean) {
            body = fileData
            statusLine = "200 OK"
            contentType = fileType
        } else {
            body = Data("not found".utf8)
            statusLine = "404 Not Found"
            contentType = "text/plain"
        }
        let header = "HTTP/1.1 \(statusLine)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}
