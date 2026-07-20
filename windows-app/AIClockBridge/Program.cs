using System.Text;
using System.Text.Json;

namespace AIClockBridge;

// Entry point. Runs tray-only (no main window) and starts the /status HTTP
// server that the ESP8266 clock polls — the same endpoints and JSON shapes as
// the Mac app, so the firmware can't tell which OS the bridge runs on.
// Headless smoke test for the petdex -> GIF -> device pipeline (same code the
// pet picker window uses): AIClockBridge --test-pet <slug> <claude|codex> <host>
static class Program
{
    const int Port = 8765;

    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length >= 3 && args[0] == "--test-pet")
        {
            Environment.Exit(TestPet(args).GetAwaiter().GetResult());
            return;
        }

        ApplicationConfiguration.Initialize();

        var service = new StatusService();
        var usage = new UsageFetcher();
        service.Usage = usage;
        var netMonitor = new NetSpeedMonitor();
        netMonitor.Start();
        var nowPlaying = new NowPlayingMonitor();
        nowPlaying.Start();
        service.MusicPlayingProvider = () => nowPlaying.Snapshot.Playing;
        var stockMonitor = new StockMonitor();
        stockMonitor.Start();

        var server = new MiniHttpServer(Port,
            routes: new()
            {
                ["/"] = () => service.Snapshot().ToJson(),
                ["/status"] = () => service.Snapshot().ToJson(),
                ["/net"] = () => netMonitor.ToJson(SystemStatsMonitor.Snapshot()),
                ["/music"] = () => nowPlaying.ToJson(),
                ["/stock"] = () => stockMonitor.ToJson(),
            },
            binaryRoutes: new()
            {
                ["/music/cover.raw"] = () => nowPlaying.CoverRgb565,
                ["/music/text.raw"] = () => nowPlaying.TextRgb565,
                ["/stock/names.raw"] = () => stockMonitor.NamesRgb565,
            },
            postRoutes: new()
            {
                // Claude Code / Codex hooks push lifecycle events here (README §7):
                // curl -d '{"agent":"claude","event":"PreToolUse"}' http://127.0.0.1:8765/event
                ["/event"] = body =>
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(body);
                        var root = doc.RootElement;
                        if (root.TryGetProperty("agent", out var agent)
                            && root.TryGetProperty("event", out var ev)
                            && agent.ValueKind == JsonValueKind.String
                            && ev.ValueKind == JsonValueKind.String)
                        {
                            string message = null;
                            if (root.TryGetProperty("message", out var msg)
                                && msg.ValueKind == JsonValueKind.String)
                                message = msg.GetString();
                            service.RecordEvent(agent.GetString(), ev.GetString(), message);
                            return Encoding.UTF8.GetBytes("{\"ok\":true}");
                        }
                    }
                    catch
                    {
                        // malformed body
                    }
                    return Encoding.UTF8.GetBytes("{\"ok\":false}");
                },
            });
        // Passive discovery: the clock polls us, so its source IP identifies it.
        // Remember it (for auto-pairing / DHCP-change self-healing) and adopt it
        // outright when no device is configured yet.
        server.OnRequest = (path, ip) =>
        {
            if (path != "/status" && path != "/net" && path != "/music") return;
            if (ip == "127.0.0.1" || ip == "::1" || ip.Length == 0) return;
            DeviceClient.DevicePollAt = DateTime.UtcNow;
            DeviceClient.LastSeenIp = ip;
            if (DeviceClient.Host.Length == 0) DeviceClient.Host = ip;
        };
        // Active fallback for when the passive route can't fire at all (fresh /
        // erased device knows no bridge host, so it never polls anyone): if the
        // device stays silent, find it ourselves and hand it our address.
        using var pairingWatchdog = new System.Threading.Timer(
            _ => _ = DeviceClient.HealPairingIfNeeded(Port), null,
            TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));

        void ApplyNetworkBinding()
        {
            netMonitor.ResetForNetworkChange();
            var address = NetworkBinding.LocalIPv4Address();
            try
            {
                server.Rebind(address);
                var lan = address == null ? "LAN unavailable" : $"{address}:{Port}";
                Console.Error.WriteLine($"[bridge] serving loopback and {lan}");
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[bridge] failed to apply network binding: {e.Message}");
            }
        }
        NetworkBinding.Changed += ApplyNetworkBinding;
        ApplyNetworkBinding();

        var context = new TrayAppContext(service, usage, netMonitor, nowPlaying, stockMonitor, Port);
        usage.StartAutoRefresh();
        Application.Run(context);
    }

    static async Task<int> TestPet(string[] args)
    {
        var slug = args[1];
        var slot = args[2];
        if (args.Length >= 4) DeviceClient.Host = args[3];
        var (w, h) = slot == "claude" ? (111, 120) : (120, 120);
        var state = PetdexService.States.First(s => s.Id == "running");
        try
        {
            var pets = await PetdexService.LoadManifest();
            var pet = pets.FirstOrDefault(p => p.Slug == slug);
            if (pet == null)
            {
                Console.WriteLine("manifest load failed or slug not found");
                return 1;
            }
            Console.WriteLine($"pet: {pet.DisplayName} {pet.SpritesheetUrl}");
            using var sheet = await PetdexService.DownloadSpritesheet(pet);
            Console.WriteLine($"sheet: {sheet.Width}x{sheet.Height}");
            var gif = PetdexService.BuildGif(sheet, state, w, h);
            if (gif == null)
            {
                Console.WriteLine("gif build failed");
                return 1;
            }
            Console.WriteLine($"gif: {gif.Length} bytes, uploading to {DeviceClient.Host} slot {slot}...");
            await DeviceClient.UploadGif(gif, slot);
            Console.WriteLine("upload ok");
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine($"failed: {e.Message}");
            return 1;
        }
    }
}
