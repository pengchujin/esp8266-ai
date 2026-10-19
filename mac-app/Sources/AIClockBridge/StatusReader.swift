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
    var petState: String = "idle"
    var activeTasks: Int = 0
    // Internal aggregation detail. A visible task can own several rollout
    // executions (parent + subagents), so execution ids — not the shared task
    // session id — are the unit counted by activeTasks.
    var activeExecutionIDs: Set<String> = []
    var activeExecutionAt: [String: TimeInterval] = [:]
    var executionSessionIDs: [String: String] = [:]
    // Latest authoritative task_complete per session, used to suppress a
    // stale working hook when a desktop turn has already finished.
    var completedSessionAt: [String: TimeInterval] = [:]
    // Executions whose final response/tool call explicitly waits for input.
    // Kept separate so one waiting subagent cannot stop a running sibling.
    var waitingExecutionAt: [String: TimeInterval] = [:]
    // Latest lifecycle/tool-output evidence that a prior input request for
    // this session has been answered or cancelled.
    var inputResolvedSessionAt: [String: TimeInterval] = [:]
}

struct Snapshot {
    var claude: ClaudeStatus
    var codex: CodexStatus
    var ts: Int
    var musicPlaying: Bool = false
}

/// Reads logs in the background so device /status requests stay fast.
final class StatusService {
    private let claudeDir: String
    private let codexDir: String

    init(claudeDir: String? = nil, codexDir: String? = nil) {
        self.claudeDir = claudeDir ?? ("~/.claude/projects" as NSString).expandingTildeInPath
        self.codexDir = codexDir ?? ("~/.codex/sessions" as NSString).expandingTildeInPath
    }

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
    private var codexEvents: [String: AgentEvent] = [:]
    private struct PetVisualEvent { let state: String; let at: TimeInterval; let ttl: TimeInterval }
    private var codexPetEvents: [String: PetVisualEvent] = [:]
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    private var claudeNeedsInputAt: TimeInterval?
    private var codexNeedsInputAt: [String: TimeInterval] = [:]
    private let workingEventTTL: TimeInterval = 10 * 60
    private let idleEventTTL: TimeInterval = 60
    private let needsInputTTL: TimeInterval = 5 * 60
    private let lifecycleLookback: TimeInterval = 7 * 24 * 60 * 60

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
        "Elicitation", "PermissionRequest", "InputRequest",
    ]

    private func isPermissionNotification(_ message: String?) -> Bool {
        guard let m = message?.lowercased() else { return false }
        return m.contains("permission") || m.contains("approve") || m.contains("approval")
    }

    /// Conservative, local-only detection for a completed response that is
    /// explicitly waiting for a user answer. Inspect only the final few lines
    /// to avoid treating an explanatory question earlier in a long answer as
    /// an outstanding request.
    private func messageRequestsUserInput(_ message: String?) -> Bool {
        guard let message else { return false }
        let lines = message.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let tail = lines.suffix(6)
            .filter { !$0.hasPrefix("```") }
            .map { line in
                line.split(separator: " ").filter { !$0.contains("://") }.joined(separator: " ")
            }
            .joined(separator: "\n")
        if tail.contains("?") || tail.contains("？") { return true }
        let lower = tail.lowercased()
        let cues = [
            "请告诉我", "请提供", "请选择", "请确认", "请回答", "需要你提供", "回复我",
            "let me know", "please provide", "please choose", "please confirm",
            "which option", "what would you", "could you",
        ]
        return cues.contains { lower.contains($0) }
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    func recordEvent(agent: String, event: String, message: String? = nil, sessionID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let sessionKey = sessionID?.isEmpty == false ? sessionID! : "__legacy__"
        if agent == "codex" {
            let visual: (String, TimeInterval)?
            switch event {
            case "reviewing": visual = ("review", 10 * 60)
            case "failure": visual = ("failed", 10 * 60)
            case "success", "Stop": visual = ("jumping", 4)
            case "attention": visual = ("waiting", 5 * 60)
            case "thinking", "tool-running", "UserPromptSubmit", "PreToolUse": visual = ("running", 10 * 60)
            default: visual = nil
            }
            if let visual {
                codexPetEvents[sessionKey] = PetVisualEvent(state: visual.0, at: now, ttl: visual.1)
            }
        }
        // Claude Notification: flash only for permission prompts, not for
        // "task done / waiting for your input" notifications.
        if event == "Notification" {
            if isPermissionNotification(message) {
                if agent == "claude" { claudeNeedsInputAt = now }
                else if agent == "codex" { codexNeedsInputAt[sessionKey] = now }
            }
            return
        }
        if Self.attentionEvents.contains(event) {
            if agent == "claude" { claudeNeedsInputAt = now }
            // Codex emits PermissionRequest after PreToolUse and before the
            // approved command actually runs. There is no "permission granted"
            // hook, so treating it as waiting makes every approved long command
            // look blocked until PostToolUse. InputRequest/Elicitation are the
            // reliable Codex signals that genuinely wait for a user response.
            else if agent == "codex", event != "PermissionRequest" {
                codexNeedsInputAt[sessionKey] = now
            }
            return
        }
        let state: String
        if Self.workingEvents.contains(event) { state = "working" }
        else if Self.idleEvents.contains(event) { state = "idle" }
        else { return }
        let ev = AgentEvent(state: state, at: now)
        // any concrete lifecycle event means the prompt (if any) was answered
        if agent == "claude" { claudeEvent = ev; claudeNeedsInputAt = nil }
        else if agent == "codex" {
            codexEvents[sessionKey] = ev
            codexNeedsInputAt.removeValue(forKey: sessionKey)
        }
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

    /// Merge log lifecycle state with per-session hooks. A Stop only clears
    /// the session that emitted it, so other Codex tasks remain visible.
    private func mergeCodexEvents(into status: inout CodexStatus, now: TimeInterval) {
        codexEvents = codexEvents.filter { now - $0.value.at < workingEventTTL }
        codexPetEvents = codexPetEvents.filter { now - $0.value.at < $0.value.ttl }
        codexNeedsInputAt = codexNeedsInputAt.filter { now - $0.value < needsInputTTL }
        let knownSessions = Set(status.executionSessionIDs.values)
        for (session, resolvedAt) in status.inputResolvedSessionAt {
            if let requestedAt = codexNeedsInputAt[session], resolvedAt >= requestedAt {
                codexNeedsInputAt.removeValue(forKey: session)
            }
        }

        var active = status.activeExecutionIDs
        var latestWorkingAt = active.compactMap { status.activeExecutionAt[$0] }.max() ?? 0
        var legacyWorking = false
        var hasFreshIdle = false
        for (session, event) in codexEvents {
            let ttl = event.state == "working" ? workingEventTTL : idleEventTTL
            guard now - event.at < ttl else { continue }
            if event.state == "working" {
                // A completed session must not be resurrected by a delayed
                // PostToolUse/SubagentStop hook. A real next turn writes a
                // new task_started almost immediately; the lifecycle scan
                // then removes this completion marker and becomes active.
                if status.completedSessionAt[session] != nil {
                    continue
                }
                if session == "__legacy__", knownSessions.isEmpty { legacyWorking = true }
                else if knownSessions.contains(session),
                        !active.contains(where: { status.executionSessionIDs[$0] == session }) {
                    let hookExecution = "hook:\(session)"
                    active.insert(hookExecution)
                    status.executionSessionIDs[hookExecution] = session
                }
                latestWorkingAt = max(latestWorkingAt, event.at)
            } else {
                hasFreshIdle = true
                if session != "__legacy__" {
                    active = Set(active.filter { status.executionSessionIDs[$0] != session })
                }
            }
        }

        // A hook-level InputRequest identifies the task session but not the
        // individual rollout. Remove only executions in that task; unrelated
        // tasks/subagents are still allowed to keep the global state working.
        for waitingSession in codexNeedsInputAt.keys {
            active = Set(active.filter { status.executionSessionIDs[$0] != waitingSession })
        }

        status.activeExecutionIDs = active
        status.activeTasks = active.count + (legacyWorking ? 1 : 0)
        let latestWaitingAt = max(codexNeedsInputAt.values.max() ?? 0,
                                  status.waitingExecutionAt.values.max() ?? 0)
        let hasWaiting = latestWaitingAt > latestWorkingAt
        if status.activeTasks > 0 {
            status.status = "working"
        } else if hasFreshIdle, status.status == "working" {
            status.status = "idle"
        }
        // A genuine unanswered question is actionable even while another task
        // runs. PermissionRequest is deliberately excluded earlier, so normal
        // approved command execution cannot create this waiting state.
        status.needsInput = hasWaiting

        if status.needsInput {
            status.status = "waiting"
            status.petState = "waiting"
        } else if status.status == "working" {
            // A completed task must not interrupt a sibling's running pet.
            let visibleVisuals = codexPetEvents.compactMap { session, event -> PetVisualEvent? in
                guard event.state != "jumping",
                      session == "__legacy__" || knownSessions.contains(session) else { return nil }
                return event
            }
            status.petState = visibleVisuals.max { $0.at < $1.at }?.state ?? "running"
        } else {
            // Hooks from hidden approval/review sessions can reach the global
            // hook config without ever producing a user-visible rollout.
            // Such unknown sessions must not animate an otherwise idle pet.
            let knownVisuals = codexPetEvents.compactMap { session, event -> PetVisualEvent? in
                guard knownSessions.contains(session)
                    || (session == "__legacy__" && knownSessions.isEmpty) else { return nil }
                return event
            }
            status.petState = knownVisuals.max { $0.at < $1.at }?.state ?? "idle"
        }
    }

    private let workingThreshold: TimeInterval = 20        // log touched within this -> "working"
    private let idleThreshold: TimeInterval = 30 * 60      // within this -> "idle", else "offline"

    private let lock = NSLock()
    private let refreshLock = NSLock()
    private let refreshQueue = DispatchQueue(label: "aiclock.status.refresh")
    private var refreshQueued = false
    private var cached: Snapshot?
    private var codexTailCache: [String: (mtime: TimeInterval, lines: [String])] = [:]
    private var codexRolloutInfoCache: [String: CodexRolloutInfo] = [:]

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

    /// Queues one scan; timer ticks while it is running are intentionally skipped.
    func refresh() {
        refreshLock.lock()
        guard !refreshQueued else { refreshLock.unlock(); return }
        refreshQueued = true
        refreshLock.unlock()

        refreshQueue.async { [weak self] in
            guard let self else { return }
            self.scan()
            self.refreshLock.lock()
            self.refreshQueued = false
            self.refreshLock.unlock()
        }
    }

    /// For one-shot CLI commands and tests; never called on a device request path.
    func refreshNow() { refreshQueue.sync { scan() } }

    private func scan() {
        let now = Date().timeIntervalSince1970
        let fresh = Snapshot(claude: readClaude(), codex: readCodex(), ts: Int(now))
        lock.lock()
        cached = fresh
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var snap = cached ?? Snapshot(claude: ClaudeStatus(), codex: CodexStatus(), ts: Int(now))
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
        snap.claude.needsInput = needsInput(claudeNeedsInputAt, now: now)
        mergeCodexEvents(into: &snap.codex, now: now)
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
    private func readLines(_ url: URL) -> [Substring]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    /// Codex rollout lines can contain very large prompts and tool results.
    /// Status only needs the latest cumulative token count and lifecycle
    /// events, all emitted near the tail, so avoid rereading whole rollouts.
    private func readTailLines(_ url: URL, mtime: TimeInterval? = nil,
                               maxBytes: UInt64 = 131_072) -> [String]? {
        let stamp = mtime ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        if let cached = codexTailCache[url.path], cached.mtime == stamp { return cached.lines }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            codexTailCache[url.path] = (stamp, lines)
            return lines
        } catch {
            return nil
        }
    }

    private struct CodexRolloutInfo {
        let executionID: String
        let sessionID: String
        let isGuardian: Bool
    }

    /// The rollout id identifies one parent/subagent execution. The session id
    /// groups executions under the visible task and is also what hooks report.
    /// They must not be used interchangeably: subagents share session_id.
    private func readCodexRolloutInfo(_ url: URL, fallbackID: String,
                                     maxBytes: Int = 262_144) -> CodexRolloutInfo {
        if let cached = codexRolloutInfoCache[url.path] { return cached }
        let fallback = CodexRolloutInfo(executionID: fallbackID, sessionID: fallbackID, isGuardian: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return fallback }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return fallback }
        for line in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"session_meta\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "session_meta",
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let executionID = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
            let sessionID = (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? executionID
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let result = CodexRolloutInfo(executionID: executionID, sessionID: sessionID,
                                          isGuardian: subagent?["other"] as? String == "guardian")
            codexRolloutInfoCache[url.path] = result
            return result
        }
        codexRolloutInfoCache[url.path] = fallback
        return fallback
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

        let fm = FileManager.default
        let root = URL(fileURLWithPath: claudeDir)
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 else { continue }
                if mtime > lastMtime { lastMtime = mtime }
                if mtime < todayStart { continue } // no activity today, skip parsing
                guard let lines = readLines(url) else { continue }
                for line in lines {
                    if !line.contains("\"usage\":{") { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else { continue }
                    let entryEpoch = parseISO(obj["timestamp"] as? String)
                    if let e = entryEpoch, e < todayStart { continue }
                    tokensToday += intVal(usage["input_tokens"]) + intVal(usage["output_tokens"])
                        + intVal(usage["cache_creation_input_tokens"]) + intVal(usage["cache_read_input_tokens"])
                    if let e = entryEpoch, now - e < 5 * 3600 {
                        if firstActiveInWindow == nil || e < firstActiveInWindow! { firstActiveInWindow = e }
                    }
                }
            }
        }
        var s = ClaudeStatus()
        s.tokensToday = tokensToday
        if let first = firstActiveInWindow { s.sessionMin = Int((now - first) / 60) }
        s.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        return s
    }

    // MARK: - Codex

    private func readCodex() -> CodexStatus {
        let now = Date().timeIntervalSince1970
        var lastMtime: TimeInterval = 0
        let fm = FileManager.default
        let root = URL(fileURLWithPath: codexDir)

        // Lifecycle files are selected by recent mtime across the whole tree,
        // not by their directory date: a task opened yesterday keeps writing
        // to yesterday's rollout after midnight.
        var recentFiles: [(URL, TimeInterval)] = []
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 {
                    if mtime > lastMtime { lastMtime = mtime }
                    if now - mtime < lifecycleLookback { recentFiles.append((url, mtime)) }
                }
            }
        }
        let recentPaths = Set(recentFiles.map { $0.0.path })
        codexTailCache = codexTailCache.filter { recentPaths.contains($0.key) }
        codexRolloutInfoCache = codexRolloutInfoCache.filter { recentPaths.contains($0.key) }

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
        var activeExecutions: Set<String> = []
        var activeExecutionAt: [String: TimeInterval] = [:]
        var executionSessionIDs: [String: String] = [:]
        var completedSessionAt: [String: TimeInterval] = [:]
        var waitingExecutionAt: [String: TimeInterval] = [:]
        var inputResolvedSessionAt: [String: TimeInterval] = [:]
        var latestLifecycleTs: Double = 0
        var sawLifecycle = false

        // Track each rollout execution independently. Parent and subagent
        // rollouts share a session id but can run and finish concurrently.
        var latestLifecycle: [String: (sessionID: String, active: Bool, asksInput: Bool,
                                       resolvesInput: Bool, at: TimeInterval, mtime: TimeInterval)] = [:]
        var legacyActiveExecutions: Set<String> = []
        for (url, fileMtime) in recentFiles {
            guard let lines = readTailLines(url, mtime: fileMtime) else { continue }
            let fileBase = url.deletingPathExtension().lastPathComponent
            let rolloutID = fileBase.count >= 36 ? String(fileBase.suffix(36)) : fileBase
            let rollout = readCodexRolloutInfo(url, fallbackID: rolloutID)
            if rollout.isGuardian { continue }
            let executionID = rollout.executionID
            let sessionID = rollout.sessionID
            executionSessionIDs[executionID] = sessionID
            var fileSawLifecycle = false
            var pendingInputCalls: Set<String> = []
            for line in lines where line.contains("\"task_started\"")
                || line.contains("\"task_complete\"") || line.contains("\"turn_aborted\"")
                || line.contains("\"function_call\"") || line.contains("\"function_call_output\"")
                || line.contains("\"custom_tool_call_output\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { continue }
                let eventTs = parseISO(obj["timestamp"] as? String) ?? fileMtime
                if type == "function_call",
                   let name = payload["name"] as? String,
                   name.lowercased().contains("request_user_input") || name.lowercased().contains("ask_user") {
                    if let callID = payload["call_id"] as? String { pendingInputCalls.insert(callID) }
                    if eventTs >= (latestLifecycle[executionID]?.at ?? 0) {
                        latestLifecycle[executionID] = (sessionID, true, true, false, eventTs, fileMtime)
                    }
                    continue
                }
                if type == "function_call_output" || type == "custom_tool_call_output" {
                    if let callID = payload["call_id"] as? String, pendingInputCalls.remove(callID) != nil,
                       eventTs >= (latestLifecycle[executionID]?.at ?? 0) {
                        latestLifecycle[executionID] = (sessionID, true, false, true, eventTs, fileMtime)
                    }
                    continue
                }
                guard type == "task_started" || type == "task_complete" || type == "turn_aborted" else { continue }
                let asksInput = type == "task_complete"
                    && messageRequestsUserInput(payload["last_agent_message"] as? String)
                let resolvesInput = latestLifecycle[executionID]?.asksInput == true && !asksInput
                if type == "task_started" || type == "task_complete" || type == "turn_aborted" {
                    pendingInputCalls.removeAll()
                }
                fileSawLifecycle = true
                sawLifecycle = true
                latestLifecycleTs = max(latestLifecycleTs, eventTs)
                if eventTs >= (latestLifecycle[executionID]?.at ?? 0) {
                    latestLifecycle[executionID] = (sessionID, type == "task_started", asksInput,
                                                    resolvesInput, eventTs, fileMtime)
                }
            }
            if !fileSawLifecycle, now - fileMtime < workingThreshold {
                legacyActiveExecutions.insert(executionID)
                activeExecutionAt[executionID] = fileMtime
            }
        }
        var sessionsWithRunnableWork: Set<String> = []
        for (executionID, lifecycle) in latestLifecycle {
            executionSessionIDs[executionID] = lifecycle.sessionID
            if lifecycle.resolvesInput {
                inputResolvedSessionAt[lifecycle.sessionID] = max(
                    inputResolvedSessionAt[lifecycle.sessionID] ?? 0, lifecycle.at)
            }
            if lifecycle.asksInput {
                waitingExecutionAt[executionID] = lifecycle.at
            } else if lifecycle.active,
               now - lifecycle.at < workingEventTTL || now - lifecycle.mtime < 2 * 60 {
                activeExecutions.insert(executionID)
                activeExecutionAt[executionID] = max(lifecycle.at, lifecycle.mtime)
                sessionsWithRunnableWork.insert(lifecycle.sessionID)
            } else if !lifecycle.active {
                completedSessionAt[lifecycle.sessionID] = max(
                    completedSessionAt[lifecycle.sessionID] ?? 0, lifecycle.at)
            }
        }
        activeExecutions.formUnion(legacyActiveExecutions)
        for executionID in legacyActiveExecutions {
            if let sessionID = executionSessionIDs[executionID] {
                sessionsWithRunnableWork.insert(sessionID)
            }
        }
        // A child completion must not suppress a fresh parent/session hook while
        // any sibling execution in that task remains runnable.
        for sessionID in sessionsWithRunnableWork { completedSessionAt.removeValue(forKey: sessionID) }

        if let names = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) {
            for url in names where url.pathExtension == "jsonl" {
                guard let lines = readTailLines(url) else { continue }
                var sessionMaxTokens = 0
                for line in lines {
                    guard line.contains("\"token_count\"") else { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { continue }
                    guard let type = payload["type"] as? String else { continue }
                    guard type == "token_count" else { continue }
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
        s.activeExecutionIDs = activeExecutions
        s.activeExecutionAt = activeExecutionAt
        s.executionSessionIDs = executionSessionIDs
        s.completedSessionAt = completedSessionAt
        s.waitingExecutionAt = waitingExecutionAt
        s.inputResolvedSessionAt = inputResolvedSessionAt
        s.activeTasks = activeExecutions.count
        if sawLifecycle {
            if !activeExecutions.isEmpty { s.status = "working" }
            else if now - latestLifecycleTs < idleThreshold { s.status = "idle" }
            else { s.status = "offline" }
        } else {
            // Compatibility fallback for older Codex JSONL formats.
            s.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        }
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
                "pet_state": codex.petState,
                "active_tasks": codex.activeTasks,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }
}
