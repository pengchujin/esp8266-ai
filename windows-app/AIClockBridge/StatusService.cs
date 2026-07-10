using System.Text;
using System.Text.Json;

namespace AIClockBridge;

// Port of the Mac StatusReader. No account APIs / keys are touched -
// everything comes from the JSONL session logs Claude Code, Codex CLI and
// kimi-code already write to disk (same paths on Windows, under %USERPROFILE%):
//   ~/.claude/projects/**/*.jsonl      (Claude Code transcripts)
//   ~/.codex/sessions/**/*.jsonl       (Codex CLI rollouts, incl. rate_limits)
//   ~/.kimi-code/sessions/**/wire.jsonl (kimi-code usage records)

class ClaudeStatus
{
    public string Status = "offline";
    public int TokensToday;
    public int SessionMin;
    public int SessionWindowMin = 300;
    public double? FiveHourPct;
    public int? FiveHourResetMin;
    public double? SevenDayPct;
    public int? SevenDayResetMin;
    public bool NeedsInput; // waiting on a permission/approval prompt
}

class CodexStatus
{
    public string Status = "offline";
    public int TokensToday;
    public double? PrimaryPct;
    public int? PrimaryWindowMin;
    public int? PrimaryResetMin;
    public double? WeeklyPct;
    public int? WeeklyWindowMin;
    public int? WeeklyResetMin;
    public bool NeedsInput;
}

class KimiStatus
{
    public string Status = "offline";
    public int TokensToday;
    public double? FiveHourPct = null;
    public int? FiveHourResetMin = null;
    public double? SevenDayPct = null;
    public int? SevenDayResetMin = null;
    public bool NeedsInput;
}

class StatusSnapshot
{
    public ClaudeStatus Claude = new();
    public CodexStatus Codex = new();
    public KimiStatus Kimi = new();
    public long Ts;
    public bool MusicPlaying;

    /// Serializes to the exact JSON shape the firmware's parseStatusJson expects.
    public byte[] ToJson()
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteNumber("ts", Ts);
            w.WriteBoolean("music_playing", MusicPlaying);
            w.WriteStartObject("claude");
            w.WriteString("status", Claude.Status);
            w.WriteNumber("tokens_today", Claude.TokensToday);
            w.WriteNumber("session_min", Claude.SessionMin);
            w.WriteNumber("session_window_min", Claude.SessionWindowMin);
            WriteNullable(w, "five_hour_pct", Claude.FiveHourPct);
            WriteNullable(w, "five_hour_reset_min", Claude.FiveHourResetMin);
            WriteNullable(w, "seven_day_pct", Claude.SevenDayPct);
            WriteNullable(w, "seven_day_reset_min", Claude.SevenDayResetMin);
            w.WriteBoolean("needs_input", Claude.NeedsInput);
            w.WriteEndObject();
            w.WriteStartObject("codex");
            w.WriteString("status", Codex.Status);
            w.WriteNumber("tokens_today", Codex.TokensToday);
            WriteNullable(w, "primary_pct", Codex.PrimaryPct);
            WriteNullable(w, "primary_window_min", Codex.PrimaryWindowMin);
            WriteNullable(w, "primary_reset_min", Codex.PrimaryResetMin);
            WriteNullable(w, "weekly_pct", Codex.WeeklyPct);
            WriteNullable(w, "weekly_window_min", Codex.WeeklyWindowMin);
            WriteNullable(w, "weekly_reset_min", Codex.WeeklyResetMin);
            w.WriteBoolean("needs_input", Codex.NeedsInput);
            w.WriteEndObject();
            w.WriteStartObject("kimi");
            w.WriteString("status", Kimi.Status);
            w.WriteNumber("tokens_today", Kimi.TokensToday);
            w.WriteNumber("session_min", 0);
            w.WriteNumber("session_window_min", 300);
            WriteNullable(w, "five_hour_pct", Kimi.FiveHourPct);
            WriteNullable(w, "five_hour_reset_min", Kimi.FiveHourResetMin);
            WriteNullable(w, "seven_day_pct", Kimi.SevenDayPct);
            WriteNullable(w, "seven_day_reset_min", Kimi.SevenDayResetMin);
            w.WriteBoolean("needs_input", Kimi.NeedsInput);
            w.WriteEndObject();
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    static void WriteNullable(Utf8JsonWriter w, string name, double? v)
    {
        if (v.HasValue) w.WriteNumber(name, v.Value); else w.WriteNull(name);
    }

    static void WriteNullable(Utf8JsonWriter w, string name, int? v)
    {
        if (v.HasValue) w.WriteNumber(name, v.Value); else w.WriteNull(name);
    }

    StatusSnapshot() { }

    public StatusSnapshot(ClaudeStatus claude, CodexStatus codex, KimiStatus kimi, long ts)
    {
        Claude = claude;
        Codex = codex;
        Kimi = kimi;
        Ts = ts;
    }

    public StatusSnapshot Clone()
    {
        return new StatusSnapshot
        {
            Claude = (ClaudeStatus)Claude.MemberwiseCloneOf(),
            Codex = (CodexStatus)Codex.MemberwiseCloneOf(),
            Kimi = (KimiStatus)Kimi.MemberwiseCloneOf(),
            Ts = Ts,
            MusicPlaying = MusicPlaying,
        };
    }
}

static class CloneHelper
{
    public static object MemberwiseCloneOf(this object o)
    {
        var clone = Activator.CreateInstance(o.GetType());
        foreach (var f in o.GetType().GetFields())
            f.SetValue(clone, f.GetValue(o));
        return clone;
    }
}

/// Reads the logs and derives status, with a small time cache so back-to-back
/// HTTP polls and the mirror timer don't each re-scan the whole tree.
sealed class StatusService
{
    readonly string _claudeDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");
    readonly string _codexDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
    readonly string _kimiDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".kimi-code", "sessions");

    /// Real OAuth quota (5h/weekly windows) merged into snapshots when set;
    /// log-derived values remain the fallback for offline use.
    public UsageFetcher Usage;

    /// Whether audio is playing right now (drives the device's AUTO -> music
    /// auto-switch). Set from NowPlayingMonitor in Program.
    public Func<bool> MusicPlayingProvider;

    // Hook-pushed live state (POST /event from Claude Code / Codex / Kimi hooks).
    // Events beat the mtime heuristic while fresh: "working" for up to 10min
    // (a long tool run emits nothing between PreToolUse and PostToolUse),
    // "idle" for 60s (long enough to kill the mtime tail after Stop, short
    // enough that a session without hooks isn't stuck idle).
    record AgentEvent(string State, double At);

    AgentEvent _claudeEvent;
    AgentEvent _codexEvent;
    AgentEvent _kimiEvent;
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    double? _claudeNeedsInputAt;
    double? _codexNeedsInputAt;
    double? _kimiNeedsInputAt;
    const double WorkingEventTTL = 10 * 60;
    const double IdleEventTTL = 60;
    const double NeedsInputTTL = 5 * 60;

    static readonly HashSet<string> WorkingEvents = new()
    {
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "WorktreeCreate",
    };
    static readonly HashSet<string> IdleEvents = new() { "Stop", "SessionEnd", "SessionStart" };
    // Codex PermissionRequest and MCP Elicitation are always a real "act now"
    // prompt. Claude's Notification is broader — it also fires on task
    // completion / 60s-idle — so it only counts as needs-input when its
    // message is actually a permission request.
    static readonly HashSet<string> AttentionEvents = new() { "Elicitation", "PermissionRequest" };

    static bool IsPermissionNotification(string message)
    {
        var m = message?.ToLowerInvariant() ?? "";
        return m.Contains("permission") || m.Contains("approve") || m.Contains("approval");
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    public void RecordEvent(string agent, string ev, string message = null)
    {
        lock (_lock)
        {
            var now = Now();
            // Claude Notification: flash only for permission prompts, not for
            // "task done / waiting for your input" notifications.
            if (ev == "Notification")
            {
                if (IsPermissionNotification(message))
                {
                    if (agent == "claude") _claudeNeedsInputAt = now;
                    else if (agent == "codex") _codexNeedsInputAt = now;
                }
                return;
            }
            if (AttentionEvents.Contains(ev))
            {
                if (agent == "claude") _claudeNeedsInputAt = now;
                else if (agent == "codex") _codexNeedsInputAt = now;
                else if (agent == "kimi") _kimiNeedsInputAt = now;
                return;
            }
            string state;
            if (WorkingEvents.Contains(ev)) state = "working";
            else if (IdleEvents.Contains(ev)) state = "idle";
            else return;
            var e = new AgentEvent(state, now);
            // any concrete lifecycle event means the prompt (if any) was answered
            if (agent == "claude") { _claudeEvent = e; _claudeNeedsInputAt = null; }
            else if (agent == "codex") { _codexEvent = e; _codexNeedsInputAt = null; }
            else if (agent == "kimi") { _kimiEvent = e; _kimiNeedsInputAt = null; }
        }
    }

    static bool NeedsInput(double? at, double now) => at.HasValue && now - at.Value < NeedsInputTTL;

    /// Event override, applied on top of the log-derived status. "offline"
    /// from logs is only upgraded by a fresh working event (a live hook means
    /// the CLI is definitely running).
    static string OverrideStatus(string logStatus, AgentEvent ev, double now)
    {
        if (ev == null) return logStatus;
        var age = now - ev.At;
        if (ev.State == "working" && age < WorkingEventTTL) return "working";
        if (ev.State == "idle" && age < IdleEventTTL && logStatus == "working") return "idle";
        return logStatus;
    }

    const double WorkingThreshold = 20;        // log touched within this -> "working"
    const double IdleThreshold = 30 * 60;      // within this -> "idle", else "offline"
    const double CacheTTL = 5;

    readonly object _lock = new();
    StatusSnapshot _cached;
    double _cachedAt;

    static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public StatusSnapshot Snapshot()
    {
        lock (_lock)
        {
            var now = Now();
            StatusSnapshot snap;
            if (_cached != null && now - _cachedAt < CacheTTL)
            {
                snap = _cached.Clone();
            }
            else
            {
                snap = new StatusSnapshot(ReadClaude(), ReadCodex(), ReadKimi(), (long)now);
                _cached = snap.Clone();
                _cachedAt = now;
            }
            snap.Ts = (long)now;

            // overlays are cheap and applied on every call, so hook events and
            // fresh quota show through instantly even while the log scan is cached
            if (Usage != null)
            {
                var cu = Usage.Claude;
                snap.Claude.FiveHourPct = cu.PrimaryPct;
                snap.Claude.FiveHourResetMin = cu.PrimaryResetMin;
                snap.Claude.SevenDayPct = cu.WeeklyPct;
                snap.Claude.SevenDayResetMin = cu.WeeklyResetMin;
                var xu = Usage.Codex;
                if (xu.PrimaryPct.HasValue)
                {
                    snap.Codex.PrimaryPct = xu.PrimaryPct;
                    snap.Codex.PrimaryResetMin = xu.PrimaryResetMin;
                }
                if (xu.WeeklyPct.HasValue)
                {
                    snap.Codex.WeeklyPct = xu.WeeklyPct;
                    snap.Codex.WeeklyResetMin = xu.WeeklyResetMin;
                }
            }
            snap.Claude.Status = OverrideStatus(snap.Claude.Status, _claudeEvent, now);
            snap.Codex.Status = OverrideStatus(snap.Codex.Status, _codexEvent, now);
            snap.Kimi.Status = OverrideStatus(snap.Kimi.Status, _kimiEvent, now);
            snap.Claude.NeedsInput = NeedsInput(_claudeNeedsInputAt, now);
            snap.Codex.NeedsInput = NeedsInput(_codexNeedsInputAt, now);
            snap.Kimi.NeedsInput = NeedsInput(_kimiNeedsInputAt, now);
            snap.MusicPlaying = MusicPlayingProvider?.Invoke() ?? false;
            return snap;
        }
    }

    // MARK: - helpers

    static string StatusFromDelta(double delta)
    {
        if (delta < WorkingThreshold) return "working";
        if (delta < IdleThreshold) return "idle";
        return "offline";
    }

    static double? ParseIso(string s)
    {
        if (s == null) return null;
        if (DateTimeOffset.TryParse(s, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d))
            return d.ToUnixTimeMilliseconds() / 1000.0;
        return null;
    }

    static double TodayStartEpoch() =>
        new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds() / 1000.0;

    /// Lossy UTF-8 read split into lines (skips files locked by the CLIs).
    static string[] ReadLines(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(fs, Encoding.UTF8);
            return reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
        }
        catch
        {
            return null;
        }
    }

    static int IntVal(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.Number)
            return (int)v.GetDouble();
        return 0;
    }

    static double? DoubleVal(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.Number)
            return v.GetDouble();
        return null;
    }

    static string StringVal(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.String)
            return v.GetString();
        return null;
    }

    static bool TryProp(JsonElement obj, string key, out JsonElement value)
    {
        value = default;
        return obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out value);
    }

    // MARK: - Claude

    ClaudeStatus ReadClaude()
    {
        var todayStart = TodayStartEpoch();
        var now = Now();
        var tokensToday = 0;
        double lastMtime = 0;
        double? firstActiveInWindow = null;

        if (Directory.Exists(_claudeDir))
        {
            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(_claudeDir, "*.jsonl", SearchOption.AllDirectories);
            }
            catch
            {
                files = Array.Empty<string>();
            }
            foreach (var file in files)
            {
                double mtime;
                try
                {
                    mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero)
                        .ToUnixTimeMilliseconds() / 1000.0;
                }
                catch
                {
                    continue;
                }
                if (mtime > lastMtime) lastMtime = mtime;
                if (mtime < todayStart) continue; // no activity today, skip parsing
                var lines = ReadLines(file);
                if (lines == null) continue;
                foreach (var line in lines)
                {
                    if (!line.Contains("\"usage\":{")) continue;
                    JsonDocument doc;
                    try { doc = JsonDocument.Parse(line); } catch { continue; }
                    using (doc)
                    {
                        var root = doc.RootElement;
                        if (!TryProp(root, "message", out var message)
                            || !TryProp(message, "usage", out var usage)) continue;
                        var entryEpoch = ParseIso(StringVal(root, "timestamp"));
                        if (entryEpoch.HasValue && entryEpoch.Value < todayStart) continue;
                        tokensToday += IntVal(usage, "input_tokens") + IntVal(usage, "output_tokens")
                            + IntVal(usage, "cache_creation_input_tokens")
                            + IntVal(usage, "cache_read_input_tokens");
                        if (entryEpoch.HasValue && now - entryEpoch.Value < 5 * 3600)
                        {
                            if (!firstActiveInWindow.HasValue || entryEpoch.Value < firstActiveInWindow.Value)
                                firstActiveInWindow = entryEpoch.Value;
                        }
                    }
                }
            }
        }

        var s = new ClaudeStatus { TokensToday = tokensToday };
        if (firstActiveInWindow.HasValue) s.SessionMin = (int)((now - firstActiveInWindow.Value) / 60);
        s.Status = StatusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9);
        return s;
    }

    // MARK: - Codex

    CodexStatus ReadCodex()
    {
        var now = Now();
        double lastMtime = 0;

        // Whole-tree scan just for the freshest mtime (drives working/idle).
        if (Directory.Exists(_codexDir))
        {
            try
            {
                foreach (var file in Directory.EnumerateFiles(_codexDir, "*.jsonl", SearchOption.AllDirectories))
                {
                    var mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero)
                        .ToUnixTimeMilliseconds() / 1000.0;
                    if (mtime > lastMtime) lastMtime = mtime;
                }
            }
            catch
            {
                // partial scan is fine
            }
        }

        // Tokens + rate limits only from today's day directory.
        var today = DateTime.Today;
        var dayDir = Path.Combine(_codexDir, $"{today.Year:D4}", $"{today.Month:D2}", $"{today.Day:D2}");

        var tokensToday = 0;
        JsonElement? latestRateLimits = null;
        JsonDocument latestRateLimitsDoc = null;
        double latestRateLimitsTs = 0;

        if (Directory.Exists(dayDir))
        {
            foreach (var file in Directory.EnumerateFiles(dayDir, "*.jsonl"))
            {
                var lines = ReadLines(file);
                if (lines == null) continue;
                var sessionMaxTokens = 0;
                foreach (var line in lines)
                {
                    if (!line.Contains("\"token_count\"")) continue;
                    JsonDocument doc;
                    try { doc = JsonDocument.Parse(line); } catch { continue; }
                    var root = doc.RootElement;
                    if (!TryProp(root, "payload", out var payload)
                        || StringVal(payload, "type") != "token_count")
                    {
                        doc.Dispose();
                        continue;
                    }
                    if (TryProp(payload, "info", out var info)
                        && TryProp(info, "total_token_usage", out var totalUsage))
                    {
                        var total = IntVal(totalUsage, "total_tokens");
                        if (total > sessionMaxTokens) sessionMaxTokens = total;
                    }
                    if (TryProp(payload, "rate_limits", out var rl))
                    {
                        var e = ParseIso(StringVal(root, "timestamp")) ?? 0;
                        if (e >= latestRateLimitsTs)
                        {
                            latestRateLimitsTs = e;
                            latestRateLimitsDoc?.Dispose();
                            latestRateLimitsDoc = doc; // keep doc alive for rl
                            latestRateLimits = rl;
                            continue;
                        }
                    }
                    doc.Dispose();
                }
                tokensToday += sessionMaxTokens;
            }
        }

        var s = new CodexStatus { TokensToday = tokensToday };
        s.Status = StatusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9);
        if (latestRateLimits.HasValue)
        {
            var rl = latestRateLimits.Value;
            if (TryProp(rl, "primary", out var primary))
            {
                s.PrimaryPct = DoubleVal(primary, "used_percent");
                s.PrimaryWindowMin = (int?)DoubleVal(primary, "window_minutes");
                var reset = DoubleVal(primary, "resets_at");
                if (reset.HasValue) s.PrimaryResetMin = Math.Max(0, (int)((reset.Value - now) / 60));
            }
            if (TryProp(rl, "secondary", out var secondary))
            {
                s.WeeklyPct = DoubleVal(secondary, "used_percent");
                s.WeeklyWindowMin = (int?)DoubleVal(secondary, "window_minutes");
                var reset = DoubleVal(secondary, "resets_at");
                if (reset.HasValue) s.WeeklyResetMin = Math.Max(0, (int)((reset.Value - now) / 60));
            }
        }
        latestRateLimitsDoc?.Dispose();
        return s;
    }

    // MARK: - Kimi

    KimiStatus ReadKimi()
    {
        var todayStart = TodayStartEpoch();
        var now = Now();
        var tokensToday = 0;
        double lastMtime = 0;

        if (!Directory.Exists(_kimiDir)) return new KimiStatus { Status = StatusFromDelta(1e9) };
        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(_kimiDir, "wire.jsonl", SearchOption.AllDirectories);
        }
        catch
        {
            files = Array.Empty<string>();
        }
        foreach (var file in files)
        {
            double mtime;
            try
            {
                mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero)
                    .ToUnixTimeMilliseconds() / 1000.0;
            }
            catch
            {
                continue;
            }
            if (mtime > lastMtime) lastMtime = mtime;
            if (mtime < todayStart) continue;
            var lines = ReadLines(file);
            if (lines == null) continue;
            foreach (var line in lines)
            {
                if (!line.Contains("\"type\":\"usage.record\"")) continue;
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); } catch { continue; }
                using (doc)
                {
                    var root = doc.RootElement;
                    if (!TryProp(root, "usage", out var usage)) continue;
                    var entryEpoch = DoubleVal(root, "time");
                    if (entryEpoch.HasValue && entryEpoch.Value / 1000.0 < todayStart) continue;
                    tokensToday += IntVal(usage, "inputOther") + IntVal(usage, "output")
                        + IntVal(usage, "inputCacheRead") + IntVal(usage, "inputCacheCreation");
                }
            }
        }

        var s = new KimiStatus { TokensToday = tokensToday };
        s.Status = StatusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9);
        return s;
    }
}
