using System.Net;
using System.Net.Sockets;
using System.Text;

namespace AIClockBridge;

// Port of the Swift Network.framework server: a tiny HTTP/1.1 listener. It
// listens on the selected LAN adapter plus loopback, preserving local hook
// calls without exposing the bridge through every adapter on the machine.
// Raw TcpListener avoids the admin urlacl required by HttpListener.
sealed class MiniHttpServer
{
    readonly int _port;
    readonly Dictionary<string, Func<byte[]>> _routes;
    readonly Dictionary<string, Func<byte[]>> _binaryRoutes;
    readonly Dictionary<string, Func<byte[], byte[]>> _postRoutes;
    readonly object _listenerLock = new();
    readonly List<TcpListener> _listeners = new();

    /// Called with (path, remoteIP) for every request. The ESP8266 polls
    /// /status constantly, so this is how the app learns the device's LAN
    /// address without any scanning.
    public Action<string, string> OnRequest;

    public MiniHttpServer(int port,
                          Dictionary<string, Func<byte[]>> routes,
                          Dictionary<string, Func<byte[]>> binaryRoutes = null,
                          Dictionary<string, Func<byte[], byte[]>> postRoutes = null)
    {
        _port = port;
        _routes = routes;
        _binaryRoutes = binaryRoutes ?? new();
        _postRoutes = postRoutes ?? new();
    }

    public void Rebind(IPAddress lanAddress)
    {
        lock (_listenerLock)
        {
            foreach (var listener in _listeners) listener.Stop();
            _listeners.Clear();

            Exception loopbackError = null;
            try { StartListener(IPAddress.Loopback); }
            catch (Exception e) { loopbackError = e; }

            Exception lanError = null;
            if (lanAddress != null && !IPAddress.IsLoopback(lanAddress))
            {
                try { StartListener(lanAddress); }
                catch (Exception e) { lanError = e; }
            }

            if (_listeners.Count == 0)
                throw new InvalidOperationException(
                    $"无法监听端口 {_port}: {(lanError ?? loopbackError)?.Message}");
            if (lanError != null)
                throw new InvalidOperationException(
                    $"无法绑定网卡 {lanAddress}:{_port}: {lanError.Message}");
        }
    }

    void StartListener(IPAddress address)
    {
        var listener = new TcpListener(address, _port);
        listener.Start();
        _listeners.Add(listener);
        Task.Run(() => AcceptLoop(listener));
    }

    async Task AcceptLoop(TcpListener listener)
    {
        while (true)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync();
            }
            catch
            {
                return; // listener stopped
            }
            _ = Task.Run(() => Handle(client));
        }
    }

    async Task Handle(TcpClient client)
    {
        using (client)
        {
            client.ReceiveTimeout = 10_000;
            client.SendTimeout = 10_000;
            NetworkStream stream;
            try
            {
                stream = client.GetStream();
            }
            catch
            {
                return;
            }

            var buf = new List<byte>(4096);
            var chunk = new byte[65536];
            int headerEnd = -1;
            try
            {
                // read until end of headers
                while (headerEnd < 0)
                {
                    int n = await stream.ReadAsync(chunk);
                    if (n <= 0) return;
                    buf.AddRange(chunk.AsSpan(0, n).ToArray());
                    headerEnd = FindHeaderEnd(buf);
                    if (buf.Count > 2_000_000) return;
                }

                var header = Encoding.UTF8.GetString(buf.ToArray(), 0, headerEnd);
                var headerLines = header.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                var parts = (headerLines.Length > 0 ? headerLines[0] : "").Split(' ');
                var method = parts.Length >= 1 ? parts[0].ToUpperInvariant() : "GET";
                var path = parts.Length >= 2 ? parts[1] : "/";

                int contentLength = 0;
                foreach (var line in headerLines)
                {
                    if (line.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
                        int.TryParse(line["content-length:".Length..].Trim(), out contentLength);
                }

                int bodyStart = headerEnd + 4;
                if (method == "POST" && contentLength <= 1_000_000)
                {
                    while (buf.Count - bodyStart < contentLength)
                    {
                        int n = await stream.ReadAsync(chunk);
                        if (n <= 0) break;
                        buf.AddRange(chunk.AsSpan(0, n).ToArray());
                    }
                }
                int bodyEnd = Math.Min(buf.Count, bodyStart + contentLength);
                var requestBody = buf.GetRange(bodyStart, Math.Max(0, bodyEnd - bodyStart)).ToArray();

                var response = BuildResponse(client, method, path, requestBody);
                await stream.WriteAsync(response);
            }
            catch
            {
                // broken pipe / malformed request: just drop the connection
            }
        }
    }

    static int FindHeaderEnd(List<byte> buf)
    {
        for (int i = 0; i + 3 < buf.Count; i++)
        {
            if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n')
                return i;
        }
        return -1;
    }

    byte[] BuildResponse(TcpClient client, string method, string path, byte[] requestBody)
    {
        var clean = path.Split('?')[0];
        var ip = (client.Client.RemoteEndPoint as IPEndPoint)?.Address?.ToString() ?? "";
        if (ip.StartsWith("::ffff:")) ip = ip["::ffff:".Length..]; // v4-mapped
        if (ip.Length > 0) OnRequest?.Invoke(clean, ip);

        byte[] body;
        string statusLine, contentType;
        if (method == "POST" && _postRoutes.TryGetValue(clean, out var postHandler))
        {
            body = postHandler(requestBody);
            statusLine = "200 OK";
            contentType = "application/json";
        }
        else if (method == "GET" && _routes.TryGetValue(clean, out var provider))
        {
            body = provider();
            statusLine = "200 OK";
            contentType = "application/json";
        }
        else if (method == "GET" && _binaryRoutes.TryGetValue(clean, out var binProvider))
        {
            body = binProvider();
            statusLine = body.Length == 0 ? "404 Not Found" : "200 OK";
            contentType = "application/octet-stream";
        }
        else
        {
            body = Encoding.UTF8.GetBytes("not found");
            statusLine = "404 Not Found";
            contentType = "text/plain";
        }

        var header = $"HTTP/1.1 {statusLine}\r\n"
            + $"Content-Type: {contentType}\r\n"
            + $"Content-Length: {body.Length}\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n\r\n";
        var headerBytes = Encoding.UTF8.GetBytes(header);
        var response = new byte[headerBytes.Length + body.Length];
        headerBytes.CopyTo(response, 0);
        body.CopyTo(response, headerBytes.Length);
        return response;
    }
}
