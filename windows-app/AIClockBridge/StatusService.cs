using System.Text;
using System.Text.Json;

namespace AIClockBridge;

// Port of the Mac StatusReader. No account APIs / keys are touched -
// everything comes from the JSONL session logs Claude Code and Codex CLI
// already write to disk (same paths on Windows, under %USERPROFILE%):
//   ~/.claude/projects/**/*.jsonl   (Claude Code transcripts)
//   ~/.codex/sessions/**/*.jsonl    (Codex CLI rollouts, incl. rate_limits)

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
    public string PetState = "idle";
    public int ActiveTasks;
    internal HashSet<string> ActiveExecutionIds = new();
    internal Dictionary<string, double> ActiveExecutionAt = new();
    internal Dictionary<string, string> ExecutionSessionIds = new();
    internal Dictionary<string, double> CompletedSessionAt = new();
    internal Dictionary<string, double> WaitingExecutionAt = new();
    internal Dictionary<string, double> InputResolvedSessionAt = new();

    public CodexStatus Clone()
    {
        var clone = (CodexStatus)this.MemberwiseCloneOf();
        clone.ActiveExecutionIds = new(ActiveExecutionIds);
        clone.ActiveExecutionAt = new(ActiveExecutionAt);
        clone.ExecutionSessionIds = new(ExecutionSessionIds);
        clone.CompletedSessionAt = new(CompletedSessionAt);
        clone.WaitingExecutionAt = new(WaitingExecutionAt);
        clone.InputResolvedSessionAt = new(InputResolvedSessionAt);
        return clone;
    }
}

class StatusSnapshot
{
    public ClaudeStatus Claude = new();
    public CodexStatus Codex = new();
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
            w.WriteString("pet_state", Codex.PetState);
            w.WriteNumber("active_tasks", Codex.ActiveTasks);
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

    public StatusSnapshot(ClaudeStatus claude, CodexStatus codex, long ts)
    {
        Claude = claude;
        Codex = codex;
        Ts = ts;
    }

    public StatusSnapshot Clone()
    {
        return new StatusSnapshot
        {
            Claude = (ClaudeStatus)Claude.MemberwiseCloneOf(),
            Codex = Codex.Clone(),
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

    /// Real OAuth quota (5h/weekly windows) merged into snapshots when set;
    /// log-derived values remain the fallback for offline use.
    public UsageFetcher Usage;

    /// Whether audio is playing right now (drives the device's AUTO -> music
    /// auto-switch). Set from NowPlayingMonitor in Program.
    public Func<bool> MusicPlayingProvider;

    // Hook-pushed live state (POST /event from Claude Code / Codex hooks).
    // Events beat the mtime heuristic while fresh: "working" for up to 10min
    // (a long tool run emits nothing between PreToolUse and PostToolUse),
    // "idle" for 60s (long enough to kill the mtime tail after Stop, short
    // enough that a session without hooks isn't stuck idle).
    record AgentEvent(string State, double At);

    AgentEvent _claudeEvent;
    readonly Dictionary<string, AgentEvent> _codexEvents = new();
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    double? _claudeNeedsInputAt;
    readonly Dictionary<string, double> _codexNeedsInputAt = new();
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
    static readonly HashSet<string> AttentionEvents = new() { "Elicitation", "PermissionRequest", "InputRequest" };

    static bool IsPermissionNotification(string message)
    {
        var m = message?.ToLowerInvariant() ?? "";
        return m.Contains("permission") || m.Contains("approve") || m.Contains("approval");
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    public void RecordEvent(string agent, string ev, string message = null, string sessionId = null)
    {
        lock (_lock)
        {
            var now = Now();
            var sessionKey = string.IsNullOrEmpty(sessionId) ? "__legacy__" : sessionId;
            // Claude Notification: flash only for permission prompts, not for
            // "task done / waiting for your input" notifications.
            if (ev == "Notification")
            {
                if (IsPermissionNotification(message))
                {
                    if (agent == "claude") _claudeNeedsInputAt = now;
                    else if (agent == "codex") _codexNeedsInputAt[sessionKey] = now;
                }
                return;
            }
            if (AttentionEvents.Contains(ev))
            {
                if (agent == "claude") _claudeNeedsInputAt = now;
                // PermissionRequest is emitted after PreToolUse even when the
                // command was already approved and is about to execute. With
                // no matching "approved" hook it cannot represent waiting.
                else if (agent == "codex" && ev != "PermissionRequest")
                    _codexNeedsInputAt[sessionKey] = now;
                return;
            }
            string state;
            if (WorkingEvents.Contains(ev)) state = "working";
            else if (IdleEvents.Contains(ev)) state = "idle";
            else return;
            var e = new AgentEvent(state, now);
            // any concrete lifecycle event means the prompt (if any) was answered
            if (agent == "claude") { _claudeEvent = e; _claudeNeedsInputAt = null; }
            else if (agent == "codex")
            {
                _codexEvents[sessionKey] = e;
                _codexNeedsInputAt.Remove(sessionKey);
            }
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

    void MergeCodexEvents(CodexStatus status, double now)
    {
        foreach (var key in _codexEvents.Where(x => now - x.Value.At >= WorkingEventTTL)
                     .Select(x => x.Key).ToArray())
            _codexEvents.Remove(key);
        foreach (var key in _codexNeedsInputAt.Where(x => now - x.Value >= NeedsInputTTL)
                     .Select(x => x.Key).ToArray())
            _codexNeedsInputAt.Remove(key);
        foreach (var (session, resolvedAt) in status.InputResolvedSessionAt)
            if (_codexNeedsInputAt.TryGetValue(session, out var requestedAt) && resolvedAt >= requestedAt)
                _codexNeedsInputAt.Remove(session);

        var knownSessions = status.ExecutionSessionIds.Values.ToHashSet();
        var active = new HashSet<string>(status.ActiveExecutionIds);
        var latestWorkingAt = active.Select(id => status.ActiveExecutionAt.GetValueOrDefault(id)).DefaultIfEmpty().Max();
        var legacyWorking = false;
        var hasFreshIdle = false;
        foreach (var (session, ev) in _codexEvents)
        {
            var ttl = ev.State == "working" ? WorkingEventTTL : IdleEventTTL;
            if (now - ev.At >= ttl) continue;
            if (ev.State == "working")
            {
                // Never let a delayed tool/subagent hook resurrect a session
                // whose latest rollout lifecycle is already complete. A real
                // next turn clears the marker through its task_started event.
                if (status.CompletedSessionAt.ContainsKey(session)) continue;
                if (session == "__legacy__" && knownSessions.Count == 0) legacyWorking = true;
                else if (knownSessions.Contains(session)
                         && !active.Any(id => status.ExecutionSessionIds.GetValueOrDefault(id) == session))
                {
                    var id = $"hook:{session}";
                    active.Add(id);
                    status.ExecutionSessionIds[id] = session;
                }
                latestWorkingAt = Math.Max(latestWorkingAt, ev.At);
            }
            else
            {
                hasFreshIdle = true;
                active.RemoveWhere(id => status.ExecutionSessionIds.GetValueOrDefault(id) == session);
            }
        }
        foreach (var session in _codexNeedsInputAt.Keys)
            active.RemoveWhere(id => status.ExecutionSessionIds.GetValueOrDefault(id) == session);

        status.ActiveExecutionIds = active;
        status.ActiveTasks = active.Count + (legacyWorking ? 1 : 0);
        var latestWaitingAt = Math.Max(_codexNeedsInputAt.Values.DefaultIfEmpty().Max(),
                                       status.WaitingExecutionAt.Values.DefaultIfEmpty().Max());
        var hasWaiting = latestWaitingAt > latestWorkingAt;
        if (status.ActiveTasks > 0) status.Status = "working";
        else if (hasFreshIdle && status.Status == "working") status.Status = "idle";
        status.NeedsInput = hasWaiting;
        if (status.NeedsInput)
        {
            status.Status = "waiting";
            status.PetState = "waiting";
        }
        else status.PetState = status.Status == "working" ? "running" : "idle";
    }

    const double WorkingThreshold = 20;        // log touched within this -> "working"
    const double IdleThreshold = 30 * 60;      // within this -> "idle", else "offline"
    const double CacheTTL = 1;

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
                snap = new StatusSnapshot(ReadClaude(), ReadCodex(), (long)now);
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
            snap.Claude.NeedsInput = NeedsInput(_claudeNeedsInputAt, now);
            MergeCodexEvents(snap.Codex, now);
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

    static string[] ReadTailLines(string path, int maxBytes = 131_072)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite | FileShare.Delete);
            fs.Seek(Math.Max(0, fs.Length - maxBytes), SeekOrigin.Begin);
            using var reader = new StreamReader(fs, Encoding.UTF8);
            return reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
        }
        catch { return null; }
    }

    record RolloutInfo(string ExecutionId, string SessionId, bool IsGuardian);

    static RolloutInfo ReadRolloutInfo(string path, string fallbackId, int maxBytes = 262_144)
    {
        var fallback = new RolloutInfo(fallbackId, fallbackId, false);
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite | FileShare.Delete);
            var bytes = new byte[Math.Min(maxBytes, (int)Math.Min(fs.Length, int.MaxValue))];
            var count = fs.Read(bytes, 0, bytes.Length);
            foreach (var line in Encoding.UTF8.GetString(bytes, 0, count)
                         .Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                if (!line.Contains("\"session_meta\"")) continue;
                using var doc = JsonDocument.Parse(line);
                var root = doc.RootElement;
                if (StringVal(root, "type") != "session_meta" || !TryProp(root, "payload", out var payload))
                    continue;
                var executionId = StringVal(payload, "id") ?? fallbackId;
                var sessionId = StringVal(payload, "session_id") ?? executionId;
                var guardian = TryProp(payload, "source", out var source)
                    && TryProp(source, "subagent", out var subagent)
                    && StringVal(subagent, "other") == "guardian";
                return new RolloutInfo(executionId, sessionId, guardian);
            }
        }
        catch { }
        return fallback;
    }

    static bool MessageRequestsUserInput(string message)
    {
        if (string.IsNullOrWhiteSpace(message)) return false;
        var tail = message.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Trim()).Where(x => x.Length > 0 && !x.StartsWith("```"))
            .TakeLast(6)
            .Select(x => string.Join(' ', x.Split(' ').Where(word => !word.Contains("://"))));
        var text = string.Join('\n', tail);
        if (text.Contains('?') || text.Contains('？')) return true;
        var lower = text.ToLowerInvariant();
        string[] cues = { "请告诉我", "请提供", "请选择", "请确认", "请回答", "需要你提供", "回复我",
            "let me know", "please provide", "please choose", "please confirm", "which option",
            "what would you", "could you" };
        return cues.Any(lower.Contains);
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

        var recentFiles = new List<(string Path, double Mtime)>();
        if (Directory.Exists(_codexDir))
        {
            try
            {
                foreach (var file in Directory.EnumerateFiles(_codexDir, "*.jsonl", SearchOption.AllDirectories))
                {
                    var mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero)
                        .ToUnixTimeMilliseconds() / 1000.0;
                    if (mtime > lastMtime) lastMtime = mtime;
                    if (now - mtime < 7 * 24 * 60 * 60) recentFiles.Add((file, mtime));
                }
            }
            catch
            {
                // partial scan is fine
            }
        }

        var activeExecutions = new HashSet<string>();
        var activeExecutionAt = new Dictionary<string, double>();
        var executionSessionIds = new Dictionary<string, string>();
        var completedSessionAt = new Dictionary<string, double>();
        var waitingExecutionAt = new Dictionary<string, double>();
        var inputResolvedSessionAt = new Dictionary<string, double>();
        var latestLifecycleTs = 0.0;
        var sawLifecycle = false;
        var latestLifecycle = new Dictionary<string,
            (string SessionId, bool Active, bool AsksInput, bool ResolvesInput, double At, double Mtime)>();
        var legacyActiveExecutions = new HashSet<string>();

        foreach (var (file, fileMtime) in recentFiles)
        {
            var lines = ReadTailLines(file);
            if (lines == null) continue;
            var fileBase = Path.GetFileNameWithoutExtension(file);
            var fallbackId = fileBase.Length >= 36 ? fileBase[^36..] : fileBase;
            var rollout = ReadRolloutInfo(file, fallbackId);
            if (rollout.IsGuardian) continue;
            var executionId = rollout.ExecutionId;
            var sessionId = rollout.SessionId;
            executionSessionIds[executionId] = sessionId;
            var fileSawLifecycle = false;
            var pendingInputCalls = new HashSet<string>();
            foreach (var line in lines)
            {
                if (!line.Contains("\"task_started\"") && !line.Contains("\"task_complete\"")
                    && !line.Contains("\"turn_aborted\"") && !line.Contains("\"function_call\"")
                    && !line.Contains("\"function_call_output\"")
                    && !line.Contains("\"custom_tool_call_output\"")) continue;
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); } catch { continue; }
                using (doc)
                {
                    var root = doc.RootElement;
                    if (!TryProp(root, "payload", out var payload)) continue;
                    var type = StringVal(payload, "type");
                    var eventTs = ParseIso(StringVal(root, "timestamp")) ?? fileMtime;
                    var previousAt = latestLifecycle.TryGetValue(executionId, out var previous)
                        ? previous.At : 0;
                    if (type == "function_call")
                    {
                        var name = StringVal(payload, "name")?.ToLowerInvariant() ?? "";
                        if (!name.Contains("request_user_input") && !name.Contains("ask_user")) continue;
                        var callId = StringVal(payload, "call_id");
                        if (callId != null) pendingInputCalls.Add(callId);
                        if (eventTs >= previousAt)
                            latestLifecycle[executionId] = (sessionId, true, true, false, eventTs, fileMtime);
                        continue;
                    }
                    if (type == "function_call_output" || type == "custom_tool_call_output")
                    {
                        var callId = StringVal(payload, "call_id");
                        if (callId != null && pendingInputCalls.Remove(callId) && eventTs >= previousAt)
                            latestLifecycle[executionId] = (sessionId, true, false, true, eventTs, fileMtime);
                        continue;
                    }
                    if (type != "task_started" && type != "task_complete" && type != "turn_aborted")
                        continue;
                    var asksInput = type == "task_complete"
                        && MessageRequestsUserInput(StringVal(payload, "last_agent_message"));
                    var resolvesInput = latestLifecycle.TryGetValue(executionId, out previous)
                        && previous.AsksInput && !asksInput;
                    pendingInputCalls.Clear();
                    fileSawLifecycle = true;
                    sawLifecycle = true;
                    latestLifecycleTs = Math.Max(latestLifecycleTs, eventTs);
                    if (eventTs >= previousAt)
                        latestLifecycle[executionId] = (sessionId, type == "task_started", asksInput,
                                                        resolvesInput, eventTs, fileMtime);
                }
            }
            if (!fileSawLifecycle && now - fileMtime < WorkingThreshold)
            {
                legacyActiveExecutions.Add(executionId);
                activeExecutionAt[executionId] = fileMtime;
            }
        }

        var sessionsWithRunnableWork = new HashSet<string>();
        foreach (var (executionId, lifecycle) in latestLifecycle)
        {
            executionSessionIds[executionId] = lifecycle.SessionId;
            if (lifecycle.ResolvesInput)
                inputResolvedSessionAt[lifecycle.SessionId] = Math.Max(
                    inputResolvedSessionAt.GetValueOrDefault(lifecycle.SessionId), lifecycle.At);
            if (lifecycle.AsksInput) waitingExecutionAt[executionId] = lifecycle.At;
            else if (lifecycle.Active
                     && (now - lifecycle.At < WorkingEventTTL || now - lifecycle.Mtime < 2 * 60))
            {
                activeExecutions.Add(executionId);
                activeExecutionAt[executionId] = Math.Max(lifecycle.At, lifecycle.Mtime);
                sessionsWithRunnableWork.Add(lifecycle.SessionId);
            }
            else if (!lifecycle.Active)
                completedSessionAt[lifecycle.SessionId] = Math.Max(
                    completedSessionAt.GetValueOrDefault(lifecycle.SessionId), lifecycle.At);
        }
        activeExecutions.UnionWith(legacyActiveExecutions);
        foreach (var executionId in legacyActiveExecutions)
            if (executionSessionIds.TryGetValue(executionId, out var sessionId))
                sessionsWithRunnableWork.Add(sessionId);
        foreach (var sessionId in sessionsWithRunnableWork) completedSessionAt.Remove(sessionId);

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
                var lines = ReadTailLines(file);
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

        var s = new CodexStatus
        {
            TokensToday = tokensToday,
            ActiveExecutionIds = activeExecutions,
            ActiveExecutionAt = activeExecutionAt,
            ExecutionSessionIds = executionSessionIds,
            CompletedSessionAt = completedSessionAt,
            WaitingExecutionAt = waitingExecutionAt,
            InputResolvedSessionAt = inputResolvedSessionAt,
            ActiveTasks = activeExecutions.Count,
        };
        if (sawLifecycle)
        {
            if (activeExecutions.Count > 0) s.Status = "working";
            else if (now - latestLifecycleTs < IdleThreshold) s.Status = "idle";
            else s.Status = "offline";
        }
        else s.Status = StatusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9);
        if (latestRateLimits.HasValue)
        {
            // Same window-length classification as UsageFetcher.FetchCodex:
            // since Codex dropped the 5h limit (2026-07) its session logs put
            // the weekly window in the "primary" slot, so sort by length.
            var rl = latestRateLimits.Value;
            foreach (var (slot, fallbackMin) in new[] { ("primary", 300), ("secondary", 7 * 1440) })
            {
                if (!TryProp(rl, slot, out var w)) continue;
                var pct = DoubleVal(w, "used_percent");
                var winMin = (int?)DoubleVal(w, "window_minutes");
                int? resetMin = null;
                var reset = DoubleVal(w, "resets_at");
                if (reset.HasValue) resetMin = Math.Max(0, (int)((reset.Value - now) / 60));
                if ((winMin ?? fallbackMin) >= 2 * 1440)
                {
                    if (!s.WeeklyPct.HasValue)
                    {
                        s.WeeklyPct = pct;
                        s.WeeklyWindowMin = winMin;
                        s.WeeklyResetMin = resetMin;
                    }
                }
                else if (!s.PrimaryPct.HasValue)
                {
                    s.PrimaryPct = pct;
                    s.PrimaryWindowMin = winMin;
                    s.PrimaryResetMin = resetMin;
                }
            }
        }
        latestRateLimitsDoc?.Dispose();
        return s;
    }
}
