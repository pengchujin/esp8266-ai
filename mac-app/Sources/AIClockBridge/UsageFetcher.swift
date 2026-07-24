import Foundation

// Real quota ("额度") for both CLIs, fetched the same way CodexBar does it —
// by reusing the OAuth tokens the CLIs already store locally, no extra login:
//   Claude: token from macOS Keychain item "Claude Code-credentials" (or
//           ~/.claude/.credentials.json), then GET
//           https://api.anthropic.com/api/oauth/usage  (5h + 7d windows)
//   Codex:  token from ~/.codex/auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (weekly window; older
//           accounts also had a 5h one - see the classification in fetchCodex)
// Tokens never leave this machine except toward their own vendor's API.

struct ProviderUsage {
    var primaryPct: Double?     // 5h window used %
    var primaryResetMin: Int?   // minutes until it resets
    var weeklyPct: Double?      // 7d / weekly window used %
    var weeklyResetMin: Int?
    var error: String?
    var fetchedAt: Date?
    var rateLimited = false
}

final class UsageFetcher {
    private let lock = NSLock()
    private var _claude = ProviderUsage()
    private var _codex = ProviderUsage()
    private var timer: Timer?
    private var fetching = false
    private var nextAllowedFetch = Date.distantPast // throttle + 429 backoff

    private let minFetchInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 300

    // Persisted last-good quota, so a cold start that lands inside the Claude
    // endpoint's 429 window shows the previous percentages instead of a blank
    // until the first successful fetch (which merge() then keeps rolling).
    private static let claudeCacheKey = "usage_cache_claude"
    private static let codexCacheKey = "usage_cache_codex"
    private static let cacheMaxAge: TimeInterval = 24 * 3600

    var claude: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _claude }
    var codex: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _codex }

    /// Called on the main thread after either provider updates.
    var onUpdate: (() -> Void)?

    init() {
        if let c = Self.loadCache(key: Self.claudeCacheKey) { _claude = c }
        if let c = Self.loadCache(key: Self.codexCacheKey) { _codex = c }
    }

    func startAutoRefresh(interval: TimeInterval = 120) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        lock.lock()
        let blocked = fetching || Date() < nextAllowedFetch
        if !blocked { fetching = true }
        lock.unlock()
        if blocked { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let claude = self.fetchClaude()
            let codex = self.fetchCodex()
            self.lock.lock()
            // Keep the last good numbers when a refresh only produced an
            // error (network hiccup / 429) - stale quota beats no quota.
            self._claude = Self.merge(old: self._claude, new: claude)
            self._codex = Self.merge(old: self._codex, new: codex)
            let mergedClaude = self._claude
            let mergedCodex = self._codex
            self.fetching = false
            let backoff: TimeInterval = claude.rateLimited ? self.rateLimitBackoff : self.minFetchInterval
            self.nextAllowedFetch = Date().addingTimeInterval(backoff)
            self.lock.unlock()
            Self.saveCache(mergedClaude, key: Self.claudeCacheKey)
            Self.saveCache(mergedCodex, key: Self.codexCacheKey)
            if let e = claude.error { FileHandle.standardError.write(Data("[usage] claude: \(e)\n".utf8)) }
            if let e = codex.error { FileHandle.standardError.write(Data("[usage] codex: \(e)\n".utf8)) }
            DispatchQueue.main.async { self.onUpdate?() }
        }
    }

    // MARK: - last-good cache (UserDefaults, local.AIClockBridge domain)

    /// Persist absolute reset instants (not minute countdowns), so a value
    /// reloaded later still resolves to a correct remaining time.
    private static func saveCache(_ u: ProviderUsage, key: String) {
        guard u.primaryPct != nil || u.weeklyPct != nil else { return }
        let now = Date().timeIntervalSince1970
        var dict: [String: Any] = ["at": now]
        if let p = u.primaryPct { dict["pPct"] = p }
        if let r = u.primaryResetMin { dict["pResetAt"] = now + Double(r) * 60 }
        if let w = u.weeklyPct { dict["wPct"] = w }
        if let r = u.weeklyResetMin { dict["wResetAt"] = now + Double(r) * 60 }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadCache(key: String) -> ProviderUsage? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let now = Date().timeIntervalSince1970
        let at = (dict["at"] as? NSNumber)?.doubleValue ?? 0
        guard now - at < cacheMaxAge else { return nil }   // drop stale cache
        var u = ProviderUsage()
        u.primaryPct = (dict["pPct"] as? NSNumber)?.doubleValue
        u.weeklyPct = (dict["wPct"] as? NSNumber)?.doubleValue
        guard u.primaryPct != nil || u.weeklyPct != nil else { return nil }
        if let r = (dict["pResetAt"] as? NSNumber)?.doubleValue { u.primaryResetMin = max(0, Int((r - now) / 60)) }
        if let r = (dict["wResetAt"] as? NSNumber)?.doubleValue { u.weeklyResetMin = max(0, Int((r - now) / 60)) }
        u.fetchedAt = Date(timeIntervalSince1970: at)
        return u
    }

    private static func merge(old: ProviderUsage, new: ProviderUsage) -> ProviderUsage {
        if new.primaryPct == nil && new.weeklyPct == nil && old.primaryPct != nil {
            var kept = old
            kept.error = new.error
            return kept
        }
        return new
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    private func fetchClaude() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let token = Self.claudeAccessToken() else {
            usage.error = "未找到 Claude Code 登录凭据"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let resp = Self.syncRequest(req)
        guard let data = resp.data else {
            usage.error = "Claude 用量请求失败：\(resp.error ?? "无响应")"
            return usage
        }
        let code = resp.code
        guard code == 200 else {
            usage.rateLimited = code == 429
            usage.error = code == 401 ? "Claude 凭据过期，运行 claude 重新登录"
                : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                : "Claude 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            usage.error = "Claude 用量响应解析失败"
            return usage
        }
        let now = Date().timeIntervalSince1970
        if let w = obj["five_hour"] as? [String: Any] {
            usage.primaryPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.primaryResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: now)
        }
        if let w = obj["seven_day"] as? [String: Any] {
            usage.weeklyPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.weeklyResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: now)
        }
        usage.fetchedAt = Date()
        return usage
    }

    /// Claude Code stores OAuth credentials in the login Keychain on macOS
    /// (file fallback for older setups). JSON: {"claudeAiOauth":{"accessToken":…}}
    static func claudeAccessToken() -> String? {
        var raw: Data?
        let credFile = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: credFile) {
            raw = data
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            raw = Data(String(decoding: out, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        guard let data = raw,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    private func fetchCodex() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let creds = Self.codexCredentials() else {
            usage.error = "未找到 Codex 登录凭据 (~/.codex/auth.json)"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIClockBridge", forHTTPHeaderField: "User-Agent")
        if let account = creds.accountId {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let resp = Self.syncRequest(req)
        guard let data = resp.data else {
            usage.error = "Codex 用量请求失败：\(resp.error ?? "无响应")"
            return usage
        }
        let code = resp.code
        guard (200...299).contains(code) else {
            usage.error = code == 401 || code == 403 ? "Codex 凭据过期，运行 codex 重新登录" : "Codex 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any] else {
            usage.error = "Codex 用量响应解析失败"
            return usage
        }
        // Codex dropped the 5h window (2026-07): primary_window now carries
        // the weekly (604800s) limit and secondary_window is null. Classify
        // each window by its advertised length instead of trusting the slot,
        // so both the old (5h+weekly) and new (weekly-only) shapes map right.
        let now = Date().timeIntervalSince1970
        for (key, fallbackSec) in [("primary_window", 5.0 * 3600), ("secondary_window", 7.0 * 86400)] {
            guard let w = rateLimit[key] as? [String: Any] else { continue }
            let pct = (w["used_percent"] as? NSNumber)?.doubleValue
            var resetMin: Int?
            if let reset = (w["reset_at"] as? NSNumber)?.doubleValue {
                resetMin = max(0, Int((reset - now) / 60))
            }
            let windowSec = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? fallbackSec
            if windowSec >= 2 * 86400 {
                if usage.weeklyPct == nil {
                    usage.weeklyPct = pct
                    usage.weeklyResetMin = resetMin
                }
            } else if usage.primaryPct == nil {
                usage.primaryPct = pct
                usage.primaryResetMin = resetMin
            }
        }
        usage.fetchedAt = Date()
        return usage
    }

    private static func codexCredentials() -> (accessToken: String, accountId: String?)? {
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        var accountId = tokens["account_id"] as? String
        if accountId == nil, let idToken = tokens["id_token"] as? String {
            accountId = Self.accountIdFromJWT(idToken)
        }
        return (access, accountId)
    }

    /// auth.json without a top-level account_id keeps it inside the id_token
    /// JWT claims (https://api.openai.com/auth -> chatgpt_account_id).
    private static func accountIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_account_id"] as? String
        }
        return nil
    }

    // MARK: - helpers

    private static func minutesUntil(iso: String?, now: Double) -> Int? {
        guard let iso = iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        }
        guard let d = date else { return nil }
        return max(0, Int((d.timeIntervalSince1970 - now) / 60))
    }

    private static func syncRequest(_ req: URLRequest) -> (data: Data?, code: Int, error: String?) {
        let sem = DispatchSemaphore(value: 0)
        var result: (data: Data?, code: Int, error: String?) = (nil, 0, "无响应")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let data = data, let http = resp as? HTTPURLResponse {
                result = (data, http.statusCode, nil)
            } else {
                result = (nil, 0, err?.localizedDescription ?? "无响应")
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}
