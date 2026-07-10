using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace AIClockBridge;

// Live "mirror" of the ESP8266 screen, shown as a popup near the tray icon.
// Not a video stream: the PC re-renders the same scene from the same data —
// /api/info says which app the device is showing (and a sprite_rev that bumps
// when animations change), /sprite/<app>/raw provides the exact frames the
// device draws (custom upload or built-in), and the local StatusService
// supplies the quota numbers the device gets from /status. Result: what you
// see here is what the panel shows, including the walk cycle animating only
// while that app is "working".

// MARK: - the 240x240 replica control

sealed class MirrorControl : Control
{
    // scene state, all in the device's 240x240 logical coordinates
    public List<Bitmap> Frames = new();
    public int FrameIdx;
    public int SpriteW = 120, SpriteH = 120;
    public double RingPct;
    public bool NeedsInput; // shown app waiting on approval -> red border flash
    public bool FlashOn;
    public string Line1 = "5h -";
    public string Line2 = "Weekly -";
    public bool ShowingClaude = true;
    public bool ShowingKimi;
    public bool DeviceOK;
    // net-mode mirror: same scrolling area-chart model as the firmware —
    // one column per 250ms sample, 224-column (56s) window, shared "nice"
    // full-scale, dim-green download area + yellow upload line.
    public bool NetMode;
    public string NetHeaderDL = "0B";
    public string NetHeaderUL = "0B";
    const int NetCols = 224; // NET_CHART_W
    double[] _histRx = new double[NetCols];
    double[] _histTx = new double[NetCols];

    public bool MusicMode;
    public string MusicTitle = "";
    public string MusicArtist = "";
    public double MusicElapsed;
    public double MusicDuration;
    public bool MusicPlaying;
    public Bitmap MusicCover;

    static readonly Image ClaudeLogo = LoadAsset("claude-logo.png");
    static readonly Image CodexLogo = LoadAsset("codex-logo.png");
    static readonly Image KimiLogo = LoadAsset("kimi-logo.png");

    static readonly Color Green = Color.FromArgb(0, 217, 51);
    static readonly Color Yellow = Color.FromArgb(255, 204, 0);

    public MirrorControl()
    {
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
            | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }

    internal static Image LoadAsset(string name)
    {
        var asm = typeof(MirrorControl).Assembly;
        var resource = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(name, StringComparison.OrdinalIgnoreCase));
        if (resource == null) return new Bitmap(1, 1);
        using var stream = asm.GetManifestResourceStream(resource);
        return Image.FromStream(stream);
    }

    public void ResetNetSweep()
    {
        _histRx = new double[NetCols];
        _histTx = new double[NetCols];
    }

    public void PushNetSample(double rx, double tx)
    {
        Array.Copy(_histRx, 1, _histRx, 0, NetCols - 1);
        _histRx[NetCols - 1] = rx;
        Array.Copy(_histTx, 1, _histTx, 0, NetCols - 1);
        _histTx[NetCols - 1] = tx;
        Invalidate();
    }

    /// Firmware's niceNetScale: shared whole-chart scale snapped to 1/2/5 steps.
    static double NiceNetScale(double maxV)
    {
        double[] steps = { 10_240, 20_480, 51_200, 102_400, 204_800, 512_000,
                           1_048_576, 2_097_152, 5_242_880, 10_485_760, 20_971_520,
                           52_428_800, 104_857_600, 209_715_200, 524_288_000 };
        foreach (var s in steps) if (maxV <= s) return s;
        return steps[^1];
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        var scale = Width / 240f;
        g.ScaleTransform(scale, scale);

        // panel background
        using (var panel = RoundedRect(new RectangleF(0, 0, 240, 240), 10))
        {
            g.FillPath(Brushes.Black, panel);
            g.SetClip(panel);
        }

        if (NetMode)
        {
            DrawNetScene(g);
            return;
        }
        if (MusicMode)
        {
            DrawMusicScene(g);
            return;
        }

        // square quota ring: margin 4, thickness 10, clockwise from top-left
        const float m = 4, t = 10;
        const float side = 240 - 2 * m;
        using (var ring = new SolidBrush(DeviceOK ? Green : Color.FromArgb(90, 90, 90)))
        {
            var remaining = side * 4 * (float)(Math.Clamp(RingPct, 0, 100) / 100);
            const float x0 = m, y0 = m, x1 = 240 - m;
            var seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x0, y0, seg, t);                    // top
            remaining -= side;
            seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x1 - t, y0, t, seg);                // right
            remaining -= side;
            seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x1 - seg, 240 - m - t, seg, t);     // bottom
            remaining -= side;
            seg = Math.Min(remaining, side);
            if (seg > 0) g.FillRectangle(ring, x0, 240 - m - seg, t, seg);         // left
        }

        // sprite, centered, pixel-crisp
        if (Frames.Count > 0)
        {
            var img = Frames[Math.Min(FrameIdx, Frames.Count - 1)];
            var state = g.Save();
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(img, new Rectangle(120 - SpriteW / 2, 120 - SpriteH / 2, SpriteW, SpriteH));
            g.Restore(state);
        }

        // app logo, top-left inside the ring (firmware draws it at 14,18 @40px)
        Image logo;
        if (ShowingClaude) logo = ClaudeLogo;
        else if (ShowingKimi) logo = KimiLogo;
        else logo = CodexLogo;
        g.DrawImage(logo, new Rectangle(14, 18, 40, 40));

        // quota text
        using (var font = new Font("Consolas", 13, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var fmt = new StringFormat { Alignment = StringAlignment.Center })
        {
            g.DrawString(Line1, font, Brushes.White, new RectangleF(0, 188, 240, 18), fmt);
            g.DrawString(Line2, font, Brushes.White, new RectangleF(0, 206, 240, 18), fmt);
        }

        if (!DeviceOK)
        {
            using var font = new Font("Microsoft YaHei UI", 14, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center };
            using var red = new SolidBrush(Color.FromArgb(255, 69, 58));
            g.DrawString("设备离线", font, red, new RectangleF(0, 60, 240, 20), fmt);
        }

        // approval pending: blink the whole border red over everything else
        if (NeedsInput && FlashOn)
        {
            using var red = new SolidBrush(Color.FromArgb(255, 59, 48));
            g.FillRectangle(red, m, m, side, t);
            g.FillRectangle(red, m, 240 - m - t, side, t);
            g.FillRectangle(red, m, m, t, side);
            g.FillRectangle(red, 240 - m - t, m, t, side);
        }
    }

    void DrawMusicScene(Graphics g)
    {
        var coverRect = new Rectangle(56, 16, 128, 128);
        if (MusicCover != null)
        {
            var state = g.Save();
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(MusicCover, coverRect);
            g.Restore(state);
        }
        else
        {
            using var dark = new SolidBrush(Color.FromArgb(64, 64, 64));
            g.FillRectangle(dark, coverRect);
            using var font = new Font("Consolas", 13, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center };
            g.DrawString("No Art", font, Brushes.LightGray, new RectangleF(56, 72, 128, 20), fmt);
        }

        using var titleFmt = new StringFormat
        {
            Alignment = StringAlignment.Center,
            Trimming = StringTrimming.EllipsisCharacter,
            FormatFlags = StringFormatFlags.NoWrap,
        };
        var title = MusicTitle.Length == 0 ? "No Music" : MusicTitle;
        using (var font = new Font("Microsoft YaHei UI", 15, FontStyle.Bold, GraphicsUnit.Pixel))
        {
            g.DrawString(title, font, Brushes.White, new RectangleF(12, 154, 216, 24), titleFmt);
        }
        using (var font = new Font("Microsoft YaHei UI", 12, FontStyle.Regular, GraphicsUnit.Pixel))
        {
            g.DrawString(MusicArtist, font, Brushes.LightGray,
                         new RectangleF(12, 178, 216, 20), titleFmt);
        }

        var bar = new RectangleF(20, 210, 200, 8);
        using var barBg = new SolidBrush(Color.FromArgb(64, 64, 64));
        g.FillRectangle(barBg, bar);
        var frac = MusicDuration > 0 ? (float)Math.Clamp(MusicElapsed / MusicDuration, 0, 1) : 0;
        using var barFill = new SolidBrush(MusicPlaying ? Green : Color.Gray);
        g.FillRectangle(barFill, bar.X, bar.Y, bar.Width * frac, bar.Height);
    }

    /// Replica of the firmware's net-speed screen v2: header readouts, then
    /// a 224x128 area chart at (8,60) — dim-green DL fill with bright top
    /// edge, 2px yellow UL line, quarter gridlines, shared nice scale.
    void DrawNetScene(Graphics g)
    {
        var grey = Color.FromArgb(140, 140, 140);
        using var greyBrush = new SolidBrush(grey);
        using var labelFont = new Font("Consolas", 8, FontStyle.Regular, GraphicsUnit.Pixel);

        g.DrawString("DOWN", labelFont, greyBrush, 14, 8);
        g.DrawString("UP", labelFont, greyBrush, 134, 8);
        using (var valueFont = new Font("Consolas", 19, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var greenBrush = new SolidBrush(Green))
        using (var yellowBrush = new SolidBrush(Yellow))
        {
            g.DrawString(NetHeaderDL + "/s", valueFont, greenBrush, 12, 19);
            g.DrawString(NetHeaderUL + "/s", valueFont, yellowBrush, 132, 19);
        }

        const float cx = 8, cy = 60, cw = 224, ch = 128;
        var scale = NiceNetScale(Math.Max(_histRx.Max(), _histTx.Max()));

        // quarter gridlines
        using (var grid = new Pen(Color.FromArgb(41, 41, 41), 1))
        {
            for (int q = 1; q <= 3; q++)
            {
                var y = cy + ch * q / 4;
                g.DrawLine(grid, cx, y, cx + cw, y);
            }
        }

        // 3-tap smoothed points, one per column (matches the device)
        PointF[] Points(double[] vals)
        {
            var pts = new PointF[NetCols];
            for (int i = 0; i < NetCols; i++)
            {
                var lo = Math.Max(0, i - 1);
                var hi = Math.Min(NetCols - 1, i + 1);
                var v = (vals[lo] + vals[i] + vals[hi]) / 3;
                var hgt = (float)Math.Min(v / scale, 1) * (ch - 2);
                pts[i] = new PointF(cx + i, cy + ch - 1 - hgt);
            }
            return pts;
        }

        // download: filled area + bright top edge
        var dl = Points(_histRx);
        using (var path = new GraphicsPath())
        {
            path.AddLine(cx, cy + ch - 1, dl[0].X, dl[0].Y);
            path.AddLines(dl);
            path.AddLine(dl[^1].X, dl[^1].Y, cx + cw - 1, cy + ch - 1);
            path.CloseFigure();
            using var fill = new SolidBrush(Color.FromArgb(0, 84, 0));
            g.FillPath(fill, path);
        }
        using (var pen = new Pen(Green, 3) { LineJoin = LineJoin.Round })
        {
            g.DrawLines(pen, dl);
        }

        // upload: yellow line
        var ul = Points(_histTx);
        using (var pen = new Pen(Yellow, 3) { LineJoin = LineJoin.Round })
        {
            g.DrawLines(pen, ul);
        }

        // axis + footer labels
        using (var right = new StringFormat { Alignment = StringAlignment.Far })
        {
            g.DrawString(DeviceSpeedText(scale), labelFont, greyBrush,
                         new RectangleF(120, 46, 112, 12), right);
        }
        using (var center = new StringFormat { Alignment = StringAlignment.Center })
        {
            g.DrawString("PC NET  -  56s", labelFont, greyBrush,
                         new RectangleF(0, 206, 240, 12), center);
        }
    }

    /// Same compact unit strings the firmware prints ("2.3M", "480K").
    public static string DeviceSpeedText(double bps)
    {
        if (bps >= 1_000_000) return $"{bps / 1_000_000:F1}M";
        if (bps >= 1_000) return $"{bps / 1_000:F0}K";
        return $"{bps:F0}B";
    }

    static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

// MARK: - popup form (the popover)

sealed class MirrorForm : Form
{
    readonly StatusService _service;
    readonly NetSpeedMonitor _netMonitor;
    readonly NowPlayingMonitor _nowPlaying;
    readonly MirrorControl _mirror = new();
    readonly RadioButton[] _modeButtons;
    static readonly string[] Modes = { "auto", "claude", "codex", "kimi", "net", "music" };
    static readonly string[] ModeLabels = { "自动", "Claude", "Codex", "Kimi", "网速", "音乐" };
    readonly Label _statusLabel = new();

    readonly System.Windows.Forms.Timer _pollTimer = new() { Interval = 1000 };
    readonly System.Windows.Forms.Timer _animTimer = new() { Interval = 120 };
    readonly System.Windows.Forms.Timer _sweepTimer = new()
    {
        Interval = (int)(NetSpeedMonitor.SampleInterval * 1000),
    };

    readonly Dictionary<string, (int Rev, List<Bitmap> Frames, int W, int H)> _spriteCache = new();
    DeviceInfo _lastInfo;
    string _fetchingSlot;
    bool _applyingMode; // suppress CheckedChanged while reflecting device state

    public MirrorForm(StatusService service, NetSpeedMonitor netMonitor, NowPlayingMonitor nowPlaying)
    {
        _service = service;
        _netMonitor = netMonitor;
        _nowPlaying = nowPlaying;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = SystemColors.Control;
        Padding = new Padding(1);

        ClientSize = new Size(Px(316), Px(392));

        _mirror.SetBounds(Px(14), Px(14), Px(288), Px(288));
        Controls.Add(_mirror);

        _modeButtons = new RadioButton[Modes.Length];
        var segWidth = Px(288) / Modes.Length;
        for (int i = 0; i < Modes.Length; i++)
        {
            var btn = new RadioButton
            {
                Appearance = Appearance.Button,
                Text = ModeLabels[i],
                TextAlign = ContentAlignment.MiddleCenter,
                Tag = Modes[i],
                AutoSize = false,
            };
            btn.SetBounds(Px(14) + i * segWidth, Px(312), segWidth, Px(28));
            btn.CheckedChanged += ModeChanged;
            _modeButtons[i] = btn;
            Controls.Add(btn);
        }

        _statusLabel.SetBounds(Px(10), Px(348), Px(296), Px(36));
        _statusLabel.TextAlign = ContentAlignment.MiddleCenter;
        _statusLabel.ForeColor = SystemColors.GrayText;
        _statusLabel.Font = new Font("Microsoft YaHei UI", 8.5f);
        _statusLabel.Text = "连接设备中…";
        _statusLabel.AutoEllipsis = true;
        Controls.Add(_statusLabel);

        _pollTimer.Tick += async (_, _) => await Tick();
        _animTimer.Tick += (_, _) => AnimTick();
        _sweepTimer.Tick += (_, _) => SweepTick();
        Deactivate += (_, _) => HidePopup(); // transient, like NSPopover
    }

    float ScaleF() => DeviceDpi / 96f;
    int Px(int logical) => (int)Math.Round(logical * ScaleF());

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var pen = new Pen(Color.FromArgb(120, 120, 120));
        e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
    }

    public void Toggle()
    {
        if (Visible)
        {
            HidePopup();
            return;
        }
        // anchor to the tray corner of the primary screen, near the cursor
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        var x = Math.Min(Math.Max(Cursor.Position.X - Width / 2, area.Left + 8),
                         area.Right - Width - 8);
        var y = area.Bottom - Height - 8;
        Location = new Point(x, y);
        Show();
        Activate();
        _pollTimer.Start();
        _animTimer.Start();
        _sweepTimer.Start();
        _ = Tick();
    }

    void HidePopup()
    {
        Hide();
        _pollTimer.Stop();
        _animTimer.Stop();
        _sweepTimer.Stop();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            HidePopup();
        }
        base.OnFormClosing(e);
    }

    /// One sweep step: push the newest 4Hz sample, refresh the DL/UL readout.
    void SweepTick()
    {
        if (!_mirror.NetMode || !Visible) return;
        var cur = _netMonitor.Current;
        var smoothed = _netMonitor.CurrentSmoothed;
        _mirror.NetHeaderDL = MirrorControl.DeviceSpeedText(smoothed.Rx);
        _mirror.NetHeaderUL = MirrorControl.DeviceSpeedText(smoothed.Tx);
        _mirror.PushNetSample(cur.Rx, cur.Tx);
    }

    async Task Tick()
    {
        DeviceInfo info;
        try
        {
            info = await DeviceClient.FetchInfo();
        }
        catch (Exception)
        {
            if (!Visible) return;
            _mirror.DeviceOK = false;
            _mirror.Invalidate();
            _statusLabel.Text = DeviceClient.Host.Length == 0
                ? "未设置设备地址（右键托盘 → 设置设备地址）" : $"无法连接 {DeviceClient.Host}";
            return;
        }
        if (!Visible) return;
        _lastInfo = info;
        _mirror.DeviceOK = true;
        ApplyScene(info);
        EnsureSprite(info);
        var modeIdx = Math.Max(0, Array.IndexOf(Modes, info.Mode));
        _applyingMode = true;
        _modeButtons[modeIdx].Checked = true;
        _applyingMode = false;
        var modeText = info.Mode == "auto" ? "自动切换"
            : info.Mode == "net" ? "网速曲线"
            : info.Mode == "music" ? "音乐播放" : "固定显示";
        _statusLabel.Text = $"{info.Ip} · {modeText} · 数据 {info.Bridge}";
    }

    /// Quota lines & ring exactly as the firmware computes them from /status.
    void ApplyScene(DeviceInfo info)
    {
        // mirror what's actually on the device screen (effective), so an
        // AUTO device that auto-switched to music shows music here too
        var enteringNet = info.Effective == "net" && !_mirror.NetMode;
        _mirror.NetMode = info.Effective == "net";
        _mirror.MusicMode = info.Effective == "music";
        if (_mirror.NetMode)
        {
            if (enteringNet) _mirror.ResetNetSweep(); // fresh sweep, like the device
            _mirror.Invalidate();
            return;
        }
        if (_mirror.MusicMode)
        {
            var s = _nowPlaying.Snapshot;
            _mirror.MusicTitle = s.Title;
            _mirror.MusicArtist = s.Artist;
            _mirror.MusicElapsed = s.Elapsed;
            _mirror.MusicDuration = s.Duration;
            _mirror.MusicPlaying = s.Playing;
            _mirror.MusicCover?.Dispose();
            var cover = _nowPlaying.CoverRgb565;
            _mirror.MusicCover = cover.Length > 0 ? Rgb565.Decode(cover, 0, 128, 128) : null;
            _mirror.Invalidate();
            return;
        }
        var snap = _service.Snapshot();
        _mirror.ShowingClaude = info.Showing == "claude";
        _mirror.ShowingKimi = info.Showing == "kimi";
        if (_mirror.ShowingClaude)
        {
            var pct = snap.Claude.FiveHourPct
                ?? (snap.Claude.SessionWindowMin > 0
                    ? 100.0 * snap.Claude.SessionMin / snap.Claude.SessionWindowMin : 0);
            _mirror.RingPct = pct;
            _mirror.Line1 = "5h " + PctText(pct);
            _mirror.Line2 = "Weekly " + PctText(snap.Claude.SevenDayPct);
            _mirror.NeedsInput = snap.Claude.NeedsInput;
        }
        else if (_mirror.ShowingKimi)
        {
            _mirror.RingPct = Math.Max(snap.Kimi.FiveHourPct ?? -1, 0);
            _mirror.Line1 = "5h " + PctText(snap.Kimi.FiveHourPct);
            _mirror.Line2 = "Weekly " + PctText(snap.Kimi.SevenDayPct);
            _mirror.NeedsInput = snap.Kimi.NeedsInput;
        }
        else
        {
            _mirror.RingPct = snap.Codex.PrimaryPct ?? 0;
            _mirror.Line1 = "5h " + PctText(snap.Codex.PrimaryPct);
            _mirror.Line2 = "Weekly " + PctText(snap.Codex.WeeklyPct);
            _mirror.NeedsInput = snap.Codex.NeedsInput;
        }
        _mirror.Invalidate();
    }

    static string PctText(double? pct) =>
        pct.HasValue && pct.Value >= 0 ? $"{(int)pct.Value}%" : "-";

    void EnsureSprite(DeviceInfo info)
    {
        string slot;
        int w, h;
        switch (info.Showing)
        {
            case "claude": slot = "claude"; w = info.ClaudeW; h = info.ClaudeH; break;
            case "codex": slot = "codex"; w = info.CodexW; h = info.CodexH; break;
            case "kimi": slot = "kimi"; w = info.KimiW; h = info.KimiH; break;
            default: return; // net/music modes have no sprite
        }
        if (_spriteCache.TryGetValue(slot, out var cached) && cached.Rev == info.SpriteRev)
        {
            _mirror.Frames = cached.Frames;
            _mirror.SpriteW = cached.W;
            _mirror.SpriteH = cached.H;
            return;
        }
        if (_fetchingSlot == slot) return;
        _fetchingSlot = slot;
        _ = FetchSprite(slot, info.SpriteRev, w, h);
    }

    async Task FetchSprite(string slot, int rev, int w, int h)
    {
        try
        {
            var data = await DeviceClient.FetchSpriteRaw(slot);
            var frames = Rgb565.DecodeSpriteFrames(data, w, h);
            if (frames.Count == 0) return;
            if (_spriteCache.TryGetValue(slot, out var old))
                foreach (var f in old.Frames) f.Dispose();
            _spriteCache[slot] = (rev, frames, w, h);
            if (_lastInfo?.Showing == slot)
            {
                _mirror.Frames = frames;
                _mirror.SpriteW = w;
                _mirror.SpriteH = h;
                _mirror.Invalidate();
            }
        }
        catch (Exception)
        {
            // device unreachable / mid-upload: next tick retries
        }
        finally
        {
            _fetchingSlot = null;
        }
    }

    int _flashCounter;

    void AnimTick()
    {
        if (_lastInfo == null || _mirror.NetMode) return;

        // ~400ms red-border flash while an approval is pending (device cadence)
        if (_mirror.NeedsInput)
        {
            _flashCounter++;
            if (_flashCounter >= 3) // 3 * 0.12s ≈ 0.36s
            {
                _flashCounter = 0;
                _mirror.FlashOn = !_mirror.FlashOn;
                _mirror.Invalidate();
            }
        }
        else if (_mirror.FlashOn)
        {
            _mirror.FlashOn = false;
            _mirror.Invalidate();
        }

        if (_mirror.Frames.Count == 0) return;
        var snap = _service.Snapshot();
        var working = _lastInfo.Showing switch
        {
            "claude" => snap.Claude.Status == "working",
            "codex" => snap.Codex.Status == "working",
            "kimi" => snap.Kimi.Status == "working",
            _ => false,
        };
        if (working)
        {
            _mirror.FrameIdx = (_mirror.FrameIdx + 1) % _mirror.Frames.Count;
        }
        else if (_mirror.FrameIdx != 0)
        {
            _mirror.FrameIdx = 0;
        }
        _mirror.Invalidate();
    }

    async void ModeChanged(object sender, EventArgs e)
    {
        if (_applyingMode || sender is not RadioButton { Checked: true, Tag: string mode }) return;
        try
        {
            await DeviceClient.SetDisplayMode(mode);
        }
        catch (Exception)
        {
            // Tick() below re-syncs the buttons to the device's real state
        }
        await Tick();
    }
}
