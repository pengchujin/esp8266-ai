import Foundation

// Real quota ("额度") for both CLIs, fetched the same way CodexBar does it —
// by reusing the OAuth tokens the CLIs already store locally, no extra login:
//   Claude: token from macOS Keychain item "Claude Code-credentials" (or
//           ~/.claude/.credentials.json), then GET
//           https://api.anthropic.com/api/oauth/usage  (5h + 7d windows)
//   Codex:  token from ~/.codex/auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (5h + weekly windows)
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
    private var _kimi = ProviderUsage()
    private var timer: Timer?
    private var fetching = false
    private var nextAllowedFetch = Date.distantPast // throttle + 429 backoff

    private let minFetchInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 300

    var claude: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _claude }
    var codex: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _codex }
    var kimi: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _kimi }

    /// Called on the main thread after either provider updates.
    var onUpdate: (() -> Void)?

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
            // Kimi has no public quota API yet; leave _kimi empty so the menu
            // shows "额度未知" instead of a fake number.
            self.lock.lock()
            // Keep the last good numbers when a refresh only produced an
            // error (network hiccup / 429) - stale quota beats no quota.
            self._claude = Self.merge(old: self._claude, new: claude)
            self._codex = Self.merge(old: self._codex, new: codex)
            self.fetching = false
            let backoff: TimeInterval = claude.rateLimited ? self.rateLimitBackoff : self.minFetchInterval
            self.nextAllowedFetch = Date().addingTimeInterval(backoff)
            self.lock.unlock()
            if let e = claude.error { FileHandle.standardError.write(Data("[usage] claude: \(e)\n".utf8)) }
            if let e = codex.error { FileHandle.standardError.write(Data("[usage] codex: \(e)\n".utf8)) }
            DispatchQueue.main.async { self.onUpdate?() }
        }
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

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Claude 用量请求失败"
            return usage
        }
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

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Codex 用量请求失败"
            return usage
        }
        guard (200...299).contains(code) else {
            usage.error = code == 401 || code == 403 ? "Codex 凭据过期，运行 codex 重新登录" : "Codex 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any] else {
            usage.error = "Codex 用量响应解析失败"
            return usage
        }
        let now = Date().timeIntervalSince1970
        if let w = rateLimit["primary_window"] as? [String: Any] {
            usage.primaryPct = (w["used_percent"] as? NSNumber)?.doubleValue
            if let reset = (w["reset_at"] as? NSNumber)?.doubleValue {
                usage.primaryResetMin = max(0, Int((reset - now) / 60))
            }
        }
        if let w = rateLimit["secondary_window"] as? [String: Any] {
            usage.weeklyPct = (w["used_percent"] as? NSNumber)?.doubleValue
            if let reset = (w["reset_at"] as? NSNumber)?.doubleValue {
                usage.weeklyResetMin = max(0, Int((reset - now) / 60))
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

    private static func syncRequest(_ req: URLRequest) -> (Data, Int)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, let http = resp as? HTTPURLResponse {
                result = (data, http.statusCode)
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}
