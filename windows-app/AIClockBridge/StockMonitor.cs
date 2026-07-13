using System.Drawing;
using System.Text;
using System.Text.Json;

namespace AIClockBridge;

// Watchlist quotes from Tencent's free endpoint (no key, realtime for A-shares,
// supports sh/sz/hk/us prefixes in one batch request, GBK-encoded response):
//   http://qt.gtimg.cn/q=sh600519,hk00700,usAAPL
// Polled every 5s; the device and the mirror both render the pre-formatted
// strings so the firmware stays dumb (and ASCII-only: it shows the code, the
// CJK company name is only used by the mirror window).
sealed class StockMonitor
{
    public record Row(string Code, string Name, string Price, string Pct, int Up);

    const string SymbolsKey = "stock_symbols";

    /// Comma-separated Tencent symbols ("sh600519,hk00700,usAAPL").
    public static string[] Symbols
    {
        get
        {
            var raw = Settings.Get(SymbolsKey);
            if (raw.Length == 0) raw = "sh000001";
            return raw.Replace('，', ',') // CN comma happens
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(Normalize).ToArray();
        }
        set => Settings.Set(SymbolsKey, string.Join(",", value));
    }

    /// Market prefix must be lowercase but the US ticker must stay UPPERCASE
    /// ("usaapl" gets v_pv_none_match back), so normalize both halves.
    static string Normalize(string s)
    {
        var t = s.Trim();
        if (t.Length <= 2) return t.ToLowerInvariant();
        return t[..2].ToLowerInvariant() + t[2..].ToUpperInvariant();
    }

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(5) };
    static readonly Encoding Gbk;

    static StockMonitor()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        Encoding enc;
        try { enc = Encoding.GetEncoding("GB18030"); }
        catch { enc = Encoding.Latin1; } // names garble, numbers still parse
        Gbk = enc;
    }

    readonly object _lock = new();
    Row[] _rows = Array.Empty<Row>();
    System.Threading.Timer _timer;

    // The device's font is ASCII-only, so CJK company names go down as
    // rendered RGB565 strips (same trick as the music title strip): one
    // NameW x NameH strip per row, wire format [1 byte count][strips...].
    // names_rev in /stock tells the device when to re-fetch.
    public const int NameW = 156, NameH = 16;
    int _namesRev;
    byte[] _namesData = { 0 };
    string _lastNamesKey = "";

    public void Start()
    {
        _ = Fetch();
        _timer = new System.Threading.Timer(_ => _ = Fetch(), null,
            TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    }

    public Row[] Snapshot
    {
        get { lock (_lock) return _rows; }
    }

    public byte[] ToJson()
    {
        var stocks = Snapshot.Select(r => new Dictionary<string, object>
        {
            ["code"] = r.Code, ["name"] = r.Name, ["price"] = r.Price,
            ["pct"] = r.Pct, ["up"] = r.Up,
        }).ToArray();
        int rev;
        lock (_lock) rev = _namesRev;
        return JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["stocks"] = stocks, ["names_rev"] = rev,
        });
    }

    /// [1 byte count][NameW x NameH RGB565 big-endian per row...]
    public byte[] NamesRgb565
    {
        get { lock (_lock) return _namesData; }
    }

    void RenderNamesIfNeeded(Row[] parsed)
    {
        var top = parsed.Take(4).ToArray();
        var key = string.Join("\n", top.Select(r => r.Name));
        lock (_lock) if (key == _lastNamesKey) return;
        using var ms = new MemoryStream();
        ms.WriteByte((byte)top.Length);
        foreach (var row in top)
        {
            using var bmp = new Bitmap(NameW, NameH);
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Black);
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using var font = new Font("Microsoft YaHei UI", 9f);
                using var brush = new SolidBrush(Color.FromArgb(184, 184, 184));
                using var right = new StringFormat
                {
                    Alignment = StringAlignment.Far,
                    Trimming = StringTrimming.EllipsisCharacter,
                    FormatFlags = StringFormatFlags.NoWrap,
                };
                g.DrawString(row.Name, font, brush, new RectangleF(0, 0, NameW, NameH), right);
            }
            ms.Write(Rgb565.Encode(bmp));
        }
        lock (_lock)
        {
            _lastNamesKey = key;
            _namesData = ms.ToArray();
            _namesRev++;
        }
    }

    async Task Fetch()
    {
        var symbols = Symbols;
        if (symbols.Length == 0)
        {
            lock (_lock) _rows = Array.Empty<Row>();
            return;
        }
        try
        {
            var bytes = await Http.GetByteArrayAsync("http://qt.gtimg.cn/q=" + string.Join(",", symbols));
            var rows = Parse(Gbk.GetString(bytes), symbols);
            lock (_lock) _rows = rows;
            RenderNamesIfNeeded(rows);
        }
        catch
        {
            // transient network error: keep the previous rows
        }
    }

    /// Response is lines of `v_sh600519="1~贵州茅台~600519~1212.00~...";`
    /// fields split by "~": [1]=name [3]=price [31]=change [32]=change%.
    static Row[] Parse(string text, string[] order)
    {
        var bySymbol = new Dictionary<string, Row>();
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = line.IndexOf('=');
            if (eq < 0 || !line.StartsWith("v_")) continue;
            var symbol = line[2..eq].ToLowerInvariant();
            var f = line[(eq + 1)..].Trim('"', ';', '\r').Split('~');
            if (f.Length <= 32 ||
                !double.TryParse(f[3], out var price) ||
                !double.TryParse(f[31], out var chg) ||
                !double.TryParse(f[32], out var pct)) continue;
            // lowercase key so the case-normalized query symbol still matches
            bySymbol[symbol] = new Row(
                DisplayCode(symbol), f[1], FormatPrice(price),
                $"{pct:+0.00;-0.00}%", chg > 0 ? 1 : (chg < 0 ? -1 : 0));
        }
        return order.Select(s => s.ToLowerInvariant())
            .Where(bySymbol.ContainsKey).Select(s => bySymbol[s]).ToArray();
    }

    /// "sh600519" -> "600519", "usAAPL" -> "AAPL", "hk00700" -> "00700"
    static string DisplayCode(string symbol)
    {
        foreach (var p in new[] { "sh", "sz", "bj", "hk", "us" })
        {
            if (symbol.StartsWith(p) && symbol.Length > 2) return symbol[2..].ToUpperInvariant();
        }
        return symbol.ToUpperInvariant();
    }

    static string FormatPrice(double p)
    {
        if (p >= 10000) return $"{p:F0}";
        if (p >= 1000) return $"{p:F1}";
        return $"{p:F2}";
    }
}
