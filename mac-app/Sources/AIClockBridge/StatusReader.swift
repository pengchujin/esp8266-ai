import Foundation

// Port of the old bridge.py log-reading logic. No account APIs / keys are
// touched - everything comes from the JSONL session logs Claude Code and Codex
// CLI already write to disk:
//   ~/.claude/projects/**/*.jsonl   (Claude Code transcripts)
//   ~/.codex/sessions/**/*.jsonl    (Codex CLI rollouts, incl. rate_limits)

struct ClaudeStatus {
    var status: String = "offline"
    var tokensToday: Int = 0
    var sessionMin: Int = 0
    var sessionWindowMin: Int = 300
    var fiveHourPct: Double? = nil
    var fiveHourResetMin: Int? = nil
    var sevenDayPct: Double? = nil
    var sevenDayResetMin: Int? = nil
    var needsInput: Bool = false // waiting on a permission/approval prompt
}

struct CodexStatus {
    var status: String = "offline"
    var tokensToday: Int = 0
    var primaryPct: Double? = nil
    var primaryWindowMin: Int? = nil
    var primaryResetMin: Int? = nil
    var weeklyPct: Double? = nil
    var weeklyWindowMin: Int? = nil
    var weeklyResetMin: Int? = nil
    var needsInput: Bool = false
}

struct Snapshot {
    var claude: ClaudeStatus
    var codex: CodexStatus
    var ts: Int
    var musicPlaying: Bool = false
}

/// Reads the logs and derives status, with a small time cache so back-to-back
/// HTTP polls and the menu-bar timer don't each re-scan the whole tree.
final class StatusService {
    private let claudeDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let codexDir = ("~/.codex/sessions" as NSString).expandingTildeInPath

    // Fast-path byte needles: only lines containing these get JSON-parsed.
    private static let claudeUsageNeedle = Data("\"usage\":{".utf8)
    private static let codexTokenNeedle = Data("\"token_count\"".utf8)

    // Per-file parse cache (keyed by path): unchanged append-only logs are not
    // re-read every scan. Mutated only under `lock` via readClaude/snapshot.
    private var claudeCache: [String: (mtime: TimeInterval, tokens: Int, epochs: [Double])] = [:]

    /// Real OAuth quota (5h/weekly windows) merged into snapshots when set;
    /// log-derived values remain the fallback for offline use.
    var usage: UsageFetcher?

    /// Whether audio is playing right now (drives the device's AUTO -> music
    /// auto-switch). Set from NowPlayingMonitor in main.
    var musicPlayingProvider: (() -> Bool)?

    // Hook-pushed live state (POST /event from Claude Code / Codex hooks).
    // Events beat the mtime heuristic while fresh: "working" for up to 10min
    // (a long tool run emits nothing between PreToolUse and PostToolUse),
    // "idle" for 60s (long enough to kill the mtime tail after Stop, short
    // enough that a session without hooks isn't stuck idle).
    private struct AgentEvent {
        let state: String // "working" | "idle"
        let at: TimeInterval
    }

    private var claudeEvent: AgentEvent?
    private var codexEvent: AgentEvent?
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    private var claudeNeedsInputAt: TimeInterval?
    private var codexNeedsInputAt: TimeInterval?
    private let workingEventTTL: TimeInterval = 10 * 60
    private let idleEventTTL: TimeInterval = 60
    private let needsInputTTL: TimeInterval = 5 * 60

    private static let workingEvents: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "WorktreeCreate",
    ]
    private static let idleEvents: Set<String> = [
        "Stop", "SessionEnd", "SessionStart",
    ]
    // Codex PermissionRequest and MCP Elicitation are always a real "act now"
    // prompt. Claude's Notification is broader — it also fires on task
    // completion / 60s-idle — so it only counts as needs-input when its
    // message is actually a permission request (see isPermissionNotification).
    private static let attentionEvents: Set<String> = [
        "Elicitation", "PermissionRequest",
    ]

    private func isPermissionNotification(_ message: String?) -> Bool {
        guard let m = message?.lowercased() else { return false }
        return m.contains("permission") || m.contains("approve") || m.contains("approval")
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    func recordEvent(agent: String, event: String, message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        // Claude Notification: flash only for permission prompts, not for
        // "task done / waiting for your input" notifications.
        if event == "Notification" {
            if isPermissionNotification(message) {
                if agent == "claude" { claudeNeedsInputAt = now }
                else if agent == "codex" { codexNeedsInputAt = now }
            }
            return
        }
        if Self.attentionEvents.contains(event) {
            if agent == "claude" { claudeNeedsInputAt = now }
            else if agent == "codex" { codexNeedsInputAt = now }
            return
        }
        let state: String
        if Self.workingEvents.contains(event) { state = "working" }
        else if Self.idleEvents.contains(event) { state = "idle" }
        else { return }
        let ev = AgentEvent(state: state, at: now)
        // any concrete lifecycle event means the prompt (if any) was answered
        if agent == "claude" { claudeEvent = ev; claudeNeedsInputAt = nil }
        else if agent == "codex" { codexEvent = ev; codexNeedsInputAt = nil }
    }

    private func needsInput(_ at: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = at else { return false }
        return now - at < needsInputTTL
    }

    /// Event override, applied on top of the log-derived status. "offline"
    /// from logs is only upgraded by a fresh working event (a live hook means
    /// the CLI is definitely running).
    private func overrideStatus(_ logStatus: String, with event: AgentEvent?, now: TimeInterval) -> String {
        guard let ev = event else { return logStatus }
        let age = now - ev.at
        if ev.state == "working", age < workingEventTTL { return "working" }
        if ev.state == "idle", age < idleEventTTL, logStatus == "working" { return "idle" }
        return logStatus
    }

    private let workingThreshold: TimeInterval = 20        // log touched within this -> "working"
    private let idleThreshold: TimeInterval = 30 * 60      // within this -> "idle", else "offline"
    private let cacheTTL: TimeInterval = 5

    private let lock = NSLock()
    private var cached: Snapshot?
    private var cachedAt: TimeInterval = 0

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var snap: Snapshot
        if let c = cached, now - cachedAt < cacheTTL {
            snap = c
        } else {
            snap = Snapshot(claude: readClaude(), codex: readCodex(), ts: Int(now))
            cached = snap
            cachedAt = now
        }
        snap.ts = Int(now)

        // overlays are cheap and applied on every call, so hook events and
        // fresh quota show through instantly even while the log scan is cached
        if let u = usage {
            let claudeUsage = u.claude
            snap.claude.fiveHourPct = claudeUsage.primaryPct
            snap.claude.fiveHourResetMin = claudeUsage.primaryResetMin
            snap.claude.sevenDayPct = claudeUsage.weeklyPct
            snap.claude.sevenDayResetMin = claudeUsage.weeklyResetMin
            let codexUsage = u.codex
            if let pct = codexUsage.primaryPct {
                snap.codex.primaryPct = pct
                snap.codex.primaryResetMin = codexUsage.primaryResetMin
            }
            if let pct = codexUsage.weeklyPct {
                snap.codex.weeklyPct = pct
                snap.codex.weeklyResetMin = codexUsage.weeklyResetMin
            }
        }
        snap.claude.status = overrideStatus(snap.claude.status, with: claudeEvent, now: now)
        snap.codex.status = overrideStatus(snap.codex.status, with: codexEvent, now: now)
        snap.claude.needsInput = needsInput(claudeNeedsInputAt, now: now)
        snap.codex.needsInput = needsInput(codexNeedsInputAt, now: now)
        snap.musicPlaying = musicPlayingProvider?() ?? false
        return snap
    }

    // MARK: - helpers

    private func statusFromDelta(_ delta: TimeInterval) -> String {
        if delta < workingThreshold { return "working" }
        if delta < idleThreshold { return "idle" }
        return "offline"
    }

    private func parseISO(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        if let d = isoFrac.date(from: s) { return d.timeIntervalSince1970 }
        if let d = isoPlain.date(from: s) { return d.timeIntervalSince1970 }
        return nil
    }

    private func todayStartEpoch() -> Double {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    /// Lossy UTF-8 read (matches Python's errors="ignore") split into lines.
    // Byte-level line split: session logs get large, and decoding the whole
    // file to a Swift String just to run the Unicode-correct String.contains on
    // every line was pathologically slow (multi-second scans, pegged a core).
    // Splitting the raw bytes and filtering with Data.range(of:) stays on UTF-8
    // and is orders of magnitude faster.
    private func readLineData(_ url: URL) -> [Data]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let newline: UInt8 = 0x0A
        return data.split(separator: newline, omittingEmptySubsequences: true).map { Data($0) }
    }

    private func intVal(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Claude

    private func readClaude() -> ClaudeStatus {
        let todayStart = todayStartEpoch()
        let now = Date().timeIntervalSince1970
        var tokensToday = 0
        var lastMtime: TimeInterval = 0
        var firstActiveInWindow: Double? = nil
        var livePaths = Set<String>()

        let fm = FileManager.default
        let root = URL(fileURLWithPath: claudeDir)
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 else { continue }
                if mtime > lastMtime { lastMtime = mtime }
                if mtime < todayStart { continue } // no activity today, skip parsing
                let path = url.path
                livePaths.insert(path)
                // Only re-read+parse a file when its mtime changed; otherwise the
                // logs are append-only static history and we reuse cached totals.
                let parsed: (tokens: Int, epochs: [Double])
                if let c = claudeCache[path], c.mtime == mtime {
                    parsed = (c.tokens, c.epochs)
                } else {
                    parsed = parseClaudeFile(url, todayStart: todayStart)
                    claudeCache[path] = (mtime, parsed.tokens, parsed.epochs)
                }
                tokensToday += parsed.tokens
                for e in parsed.epochs where now - e < 5 * 3600 {
                    if firstActiveInWindow == nil || e < firstActiveInWindow! { firstActiveInWindow = e }
                }
            }
        }
        // Drop entries for files that rolled out of "today" so the cache doesn't grow forever.
        if claudeCache.count != livePaths.count { claudeCache = claudeCache.filter { livePaths.contains($0.key) } }

        var s = ClaudeStatus()
        s.tokensToday = tokensToday
        if let first = firstActiveInWindow { s.sessionMin = Int((now - first) / 60) }
        s.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        return s
    }

    /// Parse one Claude jsonl: today's token total + every today entry's epoch
    /// (epochs feed the rolling 5h session window). Only called on new/changed files.
    private func parseClaudeFile(_ url: URL, todayStart: Double) -> (tokens: Int, epochs: [Double]) {
        guard let lines = readLineData(url) else { return (0, []) }
        var tokens = 0
        var epochs: [Double] = []
        for line in lines {
            if line.range(of: Self.claudeUsageNeedle) == nil { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let entryEpoch = parseISO(obj["timestamp"] as? String)
            if let e = entryEpoch, e < todayStart { continue }
            tokens += intVal(usage["input_tokens"]) + intVal(usage["output_tokens"])
                + intVal(usage["cache_creation_input_tokens"]) + intVal(usage["cache_read_input_tokens"])
            if let e = entryEpoch { epochs.append(e) }
        }
        return (tokens, epochs)
    }

    // MARK: - Codex

    private func readCodex() -> CodexStatus {
        let now = Date().timeIntervalSince1970
        var lastMtime: TimeInterval = 0
        let fm = FileManager.default
        let root = URL(fileURLWithPath: codexDir)

        // Whole-tree scan just for the freshest mtime (drives working/idle).
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970, mtime > lastMtime {
                    lastMtime = mtime
                }
            }
        }

        // Tokens + rate limits only from today's day directory.
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", comps.year ?? 0))
            .appendingPathComponent(String(format: "%02d", comps.month ?? 0))
            .appendingPathComponent(String(format: "%02d", comps.day ?? 0))

        var tokensToday = 0
        var latestRateLimits: [String: Any]? = nil
        var latestRateLimitsTs: Double = 0

        if let names = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) {
            for url in names where url.pathExtension == "jsonl" {
                guard let lines = readLineData(url) else { continue }
                var sessionMaxTokens = 0
                for line in lines {
                    if line.range(of: Self.codexTokenNeedle) == nil { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count" else { continue }
                    let info = payload["info"] as? [String: Any]
                    let totalUsage = info?["total_token_usage"] as? [String: Any]
                    let total = intVal(totalUsage?["total_tokens"])
                    if total > sessionMaxTokens { sessionMaxTokens = total }
                    if let rl = payload["rate_limits"] as? [String: Any] {
                        let e = parseISO(obj["timestamp"] as? String) ?? 0
                        if e >= latestRateLimitsTs { latestRateLimitsTs = e; latestRateLimits = rl }
                    }
                }
                tokensToday += sessionMaxTokens
            }
        }

        var s = CodexStatus()
        s.tokensToday = tokensToday
        s.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        if let rl = latestRateLimits {
            // Same window-length classification as UsageFetcher.fetchCodex:
            // since Codex dropped the 5h limit (2026-07) its session logs put
            // the weekly window in the "primary" slot, so sort by length.
            for (key, fallbackMin) in [("primary", 300), ("secondary", 7 * 1440)] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let pct = (w["used_percent"] as? NSNumber)?.doubleValue
                let winMin = (w["window_minutes"] as? NSNumber)?.intValue
                var resetMin: Int?
                if let reset = (w["resets_at"] as? NSNumber)?.doubleValue {
                    resetMin = max(0, Int((reset - now) / 60))
                }
                if (winMin ?? fallbackMin) >= 2 * 1440 {
                    if s.weeklyPct == nil {
                        s.weeklyPct = pct
                        s.weeklyWindowMin = winMin
                        s.weeklyResetMin = resetMin
                    }
                } else if s.primaryPct == nil {
                    s.primaryPct = pct
                    s.primaryWindowMin = winMin
                    s.primaryResetMin = resetMin
                }
            }
        }
        return s
    }
}

extension Snapshot {
    /// Serializes to the exact JSON shape the firmware's parseStatusJson expects.
    func jsonData() -> Data {
        func num(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
        func num(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let dict: [String: Any] = [
            "ts": ts,
            "music_playing": musicPlaying,
            "claude": [
                "status": claude.status,
                "tokens_today": claude.tokensToday,
                "session_min": claude.sessionMin,
                "session_window_min": claude.sessionWindowMin,
                "five_hour_pct": num(claude.fiveHourPct),
                "five_hour_reset_min": num(claude.fiveHourResetMin),
                "seven_day_pct": num(claude.sevenDayPct),
                "seven_day_reset_min": num(claude.sevenDayResetMin),
                "needs_input": claude.needsInput,
            ],
            "codex": [
                "status": codex.status,
                "tokens_today": codex.tokensToday,
                "primary_pct": num(codex.primaryPct),
                "primary_window_min": num(codex.primaryWindowMin),
                "primary_reset_min": num(codex.primaryResetMin),
                "weekly_pct": num(codex.weeklyPct),
                "weekly_window_min": num(codex.weeklyWindowMin),
                "weekly_reset_min": num(codex.weeklyResetMin),
                "needs_input": codex.needsInput,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }
}
