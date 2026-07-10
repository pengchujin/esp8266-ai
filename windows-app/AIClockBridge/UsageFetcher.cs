using System.Text.Json;

namespace AIClockBridge;

// Real quota ("额度") for both CLIs, fetched by reusing the OAuth tokens the
// CLIs already store locally, no extra login. On Windows both live in files
// (no Keychain):
//   Claude: %USERPROFILE%\.claude\.credentials.json, then GET
//           https://api.anthropic.com/api/oauth/usage  (5h + 7d windows)
//   Codex:  %USERPROFILE%\.codex\auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (5h + weekly windows)
// Tokens never leave this machine except toward their own vendor's API.

class ProviderUsage
{
    public double? PrimaryPct;     // 5h window used %
    public int? PrimaryResetMin;   // minutes until it resets
    public double? WeeklyPct;      // 7d / weekly window used %
    public int? WeeklyResetMin;
    public string Error;
    public DateTime? FetchedAt;
    public bool RateLimited;
}

sealed class UsageFetcher
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    readonly object _lock = new();
    ProviderUsage _claude = new();
    ProviderUsage _codex = new();
    ProviderUsage _kimi = new();
    System.Windows.Forms.Timer _timer;
    bool _fetching;
    DateTime _nextAllowedFetch = DateTime.MinValue; // throttle + 429 backoff

    static readonly TimeSpan MinFetchInterval = TimeSpan.FromSeconds(60);
    static readonly TimeSpan RateLimitBackoff = TimeSpan.FromSeconds(300);

    public ProviderUsage Claude { get { lock (_lock) return _claude; } }
    public ProviderUsage Codex { get { lock (_lock) return _codex; } }
    public ProviderUsage Kimi { get { lock (_lock) return _kimi; } }

    /// Raised on the UI thread after either provider updates.
    public Action OnUpdate;

    System.Threading.SynchronizationContext _ui;

    public void StartAutoRefresh(int intervalSeconds = 120)
    {
        _ui = System.Threading.SynchronizationContext.Current;
        Refresh();
        _timer = new System.Windows.Forms.Timer { Interval = intervalSeconds * 1000 };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
    }

    public void Refresh()
    {
        lock (_lock)
        {
            if (_fetching || DateTime.UtcNow < _nextAllowedFetch) return;
            _fetching = true;
        }

        Task.Run(async () =>
        {
            var claude = await FetchClaude();
            var codex = await FetchCodex();
            lock (_lock)
            {
                // Keep the last good numbers when a refresh only produced an
                // error (network hiccup / 429) - stale quota beats no quota.
                _claude = Merge(_claude, claude);
                _codex = Merge(_codex, codex);
                _fetching = false;
                var backoff = claude.RateLimited ? RateLimitBackoff : MinFetchInterval;
                _nextAllowedFetch = DateTime.UtcNow + backoff;
            }
            if (claude.Error != null) Console.Error.WriteLine($"[usage] claude: {claude.Error}");
            if (codex.Error != null) Console.Error.WriteLine($"[usage] codex: {codex.Error}");
            if (_ui != null) _ui.Post(_ => OnUpdate?.Invoke(), null);
            else OnUpdate?.Invoke();
        });
    }

    static ProviderUsage Merge(ProviderUsage old, ProviderUsage fresh)
    {
        if (fresh.PrimaryPct == null && fresh.WeeklyPct == null && old.PrimaryPct != null)
        {
            return new ProviderUsage
            {
                PrimaryPct = old.PrimaryPct,
                PrimaryResetMin = old.PrimaryResetMin,
                WeeklyPct = old.WeeklyPct,
                WeeklyResetMin = old.WeeklyResetMin,
                FetchedAt = old.FetchedAt,
                Error = fresh.Error,
            };
        }
        return fresh;
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    static async Task<ProviderUsage> FetchClaude()
    {
        var usage = new ProviderUsage();
        var token = ClaudeAccessToken();
        if (token == null)
        {
            usage.Error = "未找到 Claude Code 登录凭据（~/.claude/.credentials.json）";
            return usage;
        }
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://api.anthropic.com/api/oauth/usage");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        req.Headers.TryAddWithoutValidation("User-Agent", "claude-code/2.1.0");

        string body;
        int code;
        try
        {
            using var resp = await Http.SendAsync(req);
            code = (int)resp.StatusCode;
            body = await resp.Content.ReadAsStringAsync();
        }
        catch
        {
            usage.Error = "Claude 用量请求失败";
            return usage;
        }
        if (code != 200)
        {
            usage.RateLimited = code == 429;
            usage.Error = code == 401 ? "Claude 凭据过期，运行 claude 重新登录"
                : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                : $"Claude 用量接口 HTTP {code}";
            return usage;
        }
        try
        {
            using var doc = JsonDocument.Parse(body);
            var now = DateTimeOffset.UtcNow;
            if (doc.RootElement.TryGetProperty("five_hour", out var fiveHour))
            {
                usage.PrimaryPct = NumberOrNull(fiveHour, "utilization");
                usage.PrimaryResetMin = MinutesUntil(StringOrNull(fiveHour, "resets_at"), now);
            }
            if (doc.RootElement.TryGetProperty("seven_day", out var sevenDay))
            {
                usage.WeeklyPct = NumberOrNull(sevenDay, "utilization");
                usage.WeeklyResetMin = MinutesUntil(StringOrNull(sevenDay, "resets_at"), now);
            }
            usage.FetchedAt = DateTime.UtcNow;
        }
        catch
        {
            usage.Error = "Claude 用量响应解析失败";
        }
        return usage;
    }

    /// Claude Code on Windows stores OAuth credentials as a plain JSON file:
    /// {"claudeAiOauth":{"accessToken":…}}
    static string ClaudeAccessToken()
    {
        var credFile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", ".credentials.json");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(credFile));
            if (doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth)
                && oauth.TryGetProperty("accessToken", out var token)
                && token.ValueKind == JsonValueKind.String)
            {
                var t = token.GetString();
                return string.IsNullOrEmpty(t) ? null : t;
            }
        }
        catch
        {
            // missing / unreadable
        }
        return null;
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    static async Task<ProviderUsage> FetchCodex()
    {
        var usage = new ProviderUsage();
        var creds = CodexCredentials();
        if (creds == null)
        {
            usage.Error = "未找到 Codex 登录凭据 (~/.codex/auth.json)";
            return usage;
        }
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://chatgpt.com/backend-api/wham/usage");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {creds.Value.AccessToken}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge");
        if (creds.Value.AccountId != null)
            req.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", creds.Value.AccountId);

        string body;
        int code;
        try
        {
            using var resp = await Http.SendAsync(req);
            code = (int)resp.StatusCode;
            body = await resp.Content.ReadAsStringAsync();
        }
        catch
        {
            usage.Error = "Codex 用量请求失败";
            return usage;
        }
        if (code < 200 || code > 299)
        {
            usage.Error = code == 401 || code == 403
                ? "Codex 凭据过期，运行 codex 重新登录" : $"Codex 用量接口 HTTP {code}";
            return usage;
        }
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty("rate_limit", out var rateLimit))
            {
                usage.Error = "Codex 用量响应解析失败";
                return usage;
            }
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            if (rateLimit.TryGetProperty("primary_window", out var w1))
            {
                usage.PrimaryPct = NumberOrNull(w1, "used_percent");
                var reset = NumberOrNull(w1, "reset_at");
                if (reset.HasValue) usage.PrimaryResetMin = Math.Max(0, (int)((reset.Value - now) / 60));
            }
            if (rateLimit.TryGetProperty("secondary_window", out var w2))
            {
                usage.WeeklyPct = NumberOrNull(w2, "used_percent");
                var reset = NumberOrNull(w2, "reset_at");
                if (reset.HasValue) usage.WeeklyResetMin = Math.Max(0, (int)((reset.Value - now) / 60));
            }
            usage.FetchedAt = DateTime.UtcNow;
        }
        catch
        {
            usage.Error = "Codex 用量响应解析失败";
        }
        return usage;
    }

    static (string AccessToken, string AccountId)? CodexCredentials()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("tokens", out var tokens)
                || !tokens.TryGetProperty("access_token", out var accessEl)
                || accessEl.ValueKind != JsonValueKind.String) return null;
            var access = accessEl.GetString();
            if (string.IsNullOrEmpty(access)) return null;
            string accountId = null;
            if (tokens.TryGetProperty("account_id", out var acc) && acc.ValueKind == JsonValueKind.String)
                accountId = acc.GetString();
            if (accountId == null && tokens.TryGetProperty("id_token", out var idTok)
                && idTok.ValueKind == JsonValueKind.String)
                accountId = AccountIdFromJwt(idTok.GetString());
            return (access, accountId);
        }
        catch
        {
            return null;
        }
    }

    /// auth.json without a top-level account_id keeps it inside the id_token
    /// JWT claims (https://api.openai.com/auth -> chatgpt_account_id).
    static string AccountIdFromJwt(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length < 2) return null;
        var b64 = parts[1].Replace('-', '+').Replace('_', '/');
        while (b64.Length % 4 != 0) b64 += "=";
        try
        {
            using var doc = JsonDocument.Parse(Convert.FromBase64String(b64));
            if (doc.RootElement.TryGetProperty("https://api.openai.com/auth", out var auth)
                && auth.TryGetProperty("chatgpt_account_id", out var id)
                && id.ValueKind == JsonValueKind.String)
                return id.GetString();
        }
        catch
        {
            // malformed JWT
        }
        return null;
    }

    // MARK: - helpers

    static double? NumberOrNull(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.Number)
            return v.GetDouble();
        return null;
    }

    static string StringOrNull(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.String)
            return v.GetString();
        return null;
    }

    static int? MinutesUntil(string iso, DateTimeOffset now)
    {
        if (iso == null) return null;
        if (!DateTimeOffset.TryParse(iso, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d))
            return null;
        return Math.Max(0, (int)((d - now).TotalMinutes));
    }
}
