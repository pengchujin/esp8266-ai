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

/// Reads the logs on a background queue and derives a cached status snapshot.
/// Synchronous callers never perform disk work.
final class StatusService {
    private let claudeDir: URL
    private let codexDir: URL
    private let scanQueue: DispatchQueue

    /// Real OAuth quota (5h/weekly windows) merged into snapshots when set;
    /// log-derived values remain the fallback for offline use.
    private var usageValue: UsageFetcher?
    var usage: UsageFetcher? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return usageValue
        }
        set {
            lock.lock()
            usageValue = newValue
            lock.unlock()
        }
    }

    /// Whether audio is playing right now (drives the device's AUTO -> music
    /// auto-switch). Set from NowPlayingMonitor in main.
    private var musicPlayingProviderValue: (() -> Bool)?
    var musicPlayingProvider: (() -> Bool)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return musicPlayingProviderValue
        }
        set {
            lock.lock()
            musicPlayingProviderValue = newValue
            lock.unlock()
        }
    }

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
    private let cacheTTL: TimeInterval
    private let scanObserver: (() -> Void)?
    private let readObserver: ((URL, UInt64, UInt64) -> Void)?

    private let lock = NSLock()
    private var cached: Snapshot?
    private var cachedAt: TimeInterval = 0
    private var scanInFlight = false
    private var pendingSnapshotCompletion: ((Snapshot) -> Void)?

    private struct OverlayState {
        let usage: UsageFetcher?
        let musicPlayingProvider: (() -> Bool)?
        let claudeEvent: AgentEvent?
        let codexEvent: AgentEvent?
        let claudeNeedsInputAt: TimeInterval?
        let codexNeedsInputAt: TimeInterval?
    }

    private struct FileMetadata {
        let size: UInt64
        let modified: TimeInterval
        let identity: String?
    }

    private struct FileCursor {
        var offset: UInt64 = 0
        var pendingLine = Data()
        var lastModified: TimeInterval = 0
        var identity: String?

        mutating func reset() {
            offset = 0
            pendingLine.removeAll(keepingCapacity: false)
            lastModified = 0
            identity = nil
        }
    }

    private struct ClaudeFileState {
        var cursor = FileCursor()
        var dayStart: TimeInterval = -1
        var tokensToday = 0
        var firstActiveInWindow: Double?

        mutating func reset(for dayStart: TimeInterval) {
            self.dayStart = dayStart
            tokensToday = 0
            firstActiveInWindow = nil
        }
    }

    private struct ClaudeDirectoryCache {
        let modified: TimeInterval
        let discoveredAt: TimeInterval
        let files: [URL]
    }

    private struct CodexFileState {
        var cursor = FileCursor()
        var dayStart: TimeInterval = -1
        var sessionMaxTokens = 0
        var latestRateLimits: [String: Any]?
        var latestRateLimitsTs: Double = 0

        mutating func reset(for dayStart: TimeInterval) {
            cursor.reset()
            self.dayStart = dayStart
            sessionMaxTokens = 0
            latestRateLimits = nil
            latestRateLimitsTs = 0
        }
    }

    private var claudeFiles: [String: ClaudeFileState] = [:]
    private var claudeDirectoryCache: [String: ClaudeDirectoryCache] = [:]
    private var codexFiles: [String: CodexFileState] = [:]
    private let claudeDiscoveryTTL: TimeInterval = 60

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

    private static let fileResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
        .contentModificationDateKey, .fileResourceIdentifierKey,
    ]
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)

    init(claudeDirectory: URL? = nil, codexDirectory: URL? = nil,
         scanQueue: DispatchQueue? = nil, cacheTTL: TimeInterval = 5,
         scanObserver: (() -> Void)? = nil,
         readObserver: ((URL, UInt64, UInt64) -> Void)? = nil) {
        self.claudeDir = claudeDirectory
            ?? URL(fileURLWithPath: ("~/.claude/projects" as NSString).expandingTildeInPath)
        self.codexDir = codexDirectory
            ?? URL(fileURLWithPath: ("~/.codex/sessions" as NSString).expandingTildeInPath)
        self.scanQueue = scanQueue
            ?? DispatchQueue(label: "aiclock.status-scan", qos: .utility)
        self.cacheTTL = cacheTTL
        self.scanObserver = scanObserver
        self.readObserver = readObserver
    }

    /// Returns the last cached value immediately and schedules a refresh when
    /// stale. This keeps HTTP and serial responses independent from disk I/O.
    func snapshot() -> Snapshot {
        let now = Date().timeIntervalSince1970
        let request = beginSnapshotRequest(now: now)
        if request.startScan { scheduleScan() }
        return decorate(request.base, now: now, state: request.overlayState)
    }

    /// Delivers a fresh snapshot without doing disk work on the caller's
    /// thread. A single waiter is enough because callers poll again after the
    /// cache is updated.
    func snapshot(completion: @escaping (Snapshot) -> Void) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let isFresh = cached != nil && now - cachedAt < cacheTTL
        if isFresh {
            let base = cached!
            let state = captureOverlayStateLocked()
            lock.unlock()
            completion(decorate(base, now: now, state: state))
            return
        }

        if pendingSnapshotCompletion == nil {
            pendingSnapshotCompletion = completion
        }
        let startScan = !scanInFlight
        scanInFlight = true
        lock.unlock()
        if startScan { scheduleScan() }
    }

    private func beginSnapshotRequest(now: TimeInterval)
        -> (base: Snapshot, overlayState: OverlayState, startScan: Bool) {
        lock.lock()
        let base = cached ?? Snapshot(
            claude: ClaudeStatus(), codex: CodexStatus(), ts: Int(now)
        )
        let state = captureOverlayStateLocked()
        let stale = cached == nil || now - cachedAt >= cacheTTL
        let startScan = stale && !scanInFlight
        if startScan { scanInFlight = true }
        lock.unlock()
        return (base, state, startScan)
    }

    private func captureOverlayStateLocked() -> OverlayState {
        OverlayState(
            usage: usageValue,
            musicPlayingProvider: musicPlayingProviderValue,
            claudeEvent: claudeEvent,
            codexEvent: codexEvent,
            claudeNeedsInputAt: claudeNeedsInputAt,
            codexNeedsInputAt: codexNeedsInputAt
        )
    }

    private func scheduleScan() {
        scanQueue.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        scanObserver?()
        let startedAt = Date()
        let now = startedAt.timeIntervalSince1970
        let dayStart = Calendar.current.startOfDay(for: startedAt).timeIntervalSince1970
        let raw = Snapshot(
            claude: readClaude(now: now, todayStart: dayStart),
            codex: readCodex(now: now, todayStart: dayStart),
            ts: Int(now)
        )
        let finishedAt = Date().timeIntervalSince1970

        lock.lock()
        cached = raw
        cachedAt = finishedAt
        scanInFlight = false
        let completion = pendingSnapshotCompletion
        pendingSnapshotCompletion = nil
        let state = captureOverlayStateLocked()
        lock.unlock()

        completion?(decorate(raw, now: finishedAt, state: state))
    }

    private func decorate(_ raw: Snapshot, now: TimeInterval,
                          state: OverlayState) -> Snapshot {
        var snap = raw
        snap.ts = Int(now)

        if let u = state.usage {
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
        snap.claude.status = overrideStatus(
            snap.claude.status, with: state.claudeEvent, now: now
        )
        snap.codex.status = overrideStatus(
            snap.codex.status, with: state.codexEvent, now: now
        )
        snap.claude.needsInput = needsInput(state.claudeNeedsInputAt, now: now)
        snap.codex.needsInput = needsInput(state.codexNeedsInputAt, now: now)
        snap.musicPlaying = state.musicPlayingProvider?() ?? false
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

    private func intVal(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    private func fileMetadata(_ url: URL, values: URLResourceValues? = nil)
        -> FileMetadata? {
        let resourceValues = values
            ?? (try? url.resourceValues(forKeys: Self.fileResourceKeys))
        guard let resourceValues,
              resourceValues.isRegularFile == true,
              let size = resourceValues.fileSize,
              size >= 0,
              let modified = resourceValues.contentModificationDate?
                .timeIntervalSince1970 else {
            return nil
        }
        let identity = resourceValues.fileResourceIdentifier.map(String.init(describing:))
        return FileMetadata(size: UInt64(size), modified: modified, identity: identity)
    }

    /// Reads only bytes appended since the previous scan. A partial final line
    /// stays in the cursor until the writer emits its newline.
    private func readNewLines(_ url: URL, metadata: FileMetadata,
                              cursor: inout FileCursor) -> (lines: [Data], didReset: Bool) {
        let identityChanged = cursor.identity != nil
            && metadata.identity != nil
            && cursor.identity != metadata.identity
        let replaced = metadata.size < cursor.offset
            || identityChanged
            || (cursor.offset > 0
                && metadata.size == cursor.offset
                && metadata.modified > cursor.lastModified)
        if replaced { cursor.reset() }
        cursor.lastModified = metadata.modified
        cursor.identity = metadata.identity

        guard metadata.size > cursor.offset,
              metadata.size - cursor.offset <= UInt64(Int.max),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], replaced)
        }

        readObserver?(url, cursor.offset, metadata.size - cursor.offset)
        handle.seek(toFileOffset: cursor.offset)
        let data = handle.readData(ofLength: Int(metadata.size - cursor.offset))
        handle.closeFile()
        cursor.offset += UInt64(data.count)
        cursor.pendingLine.append(data)

        var lines: [Data] = []
        while let newline = cursor.pendingLine.firstIndex(of: 0x0A) {
            var line = Data(cursor.pendingLine.prefix(upTo: newline))
            if line.last == 0x0D { line.removeLast() }
            lines.append(line)
            cursor.pendingLine.removeSubrange(...newline)
        }
        return (lines, replaced)
    }

    private func advanceCursorToEnd(_ metadata: FileMetadata, cursor: inout FileCursor) {
        cursor.offset = metadata.size
        cursor.pendingLine.removeAll(keepingCapacity: false)
        cursor.lastModified = metadata.modified
        cursor.identity = metadata.identity
    }

    // MARK: - Claude

    private func discoverClaudeFiles(todayStart: Date, now: TimeInterval)
        -> [(url: URL, metadata: FileMetadata)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: Array(Self.fileResourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            claudeDirectoryCache.removeAll()
            return []
        }

        var directFiles: [URL] = []
        var directories: [(url: URL, modified: TimeInterval)] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: Self.fileResourceKeys)
            if values?.isDirectory == true {
                guard !isPastDateDirectory(url, root: claudeDir, before: todayStart),
                      let modified = values?.contentModificationDate?
                        .timeIntervalSince1970 else {
                    continue
                }
                directories.append((url, modified))
            } else if url.pathExtension.lowercased() == "jsonl" {
                directFiles.append(url)
            }
        }

        let directoryPaths = Set(directories.map { $0.url.path })
        claudeDirectoryCache = claudeDirectoryCache.filter {
            directoryPaths.contains($0.key)
        }

        var urls = directFiles
        for directory in directories {
            let path = directory.url.path
            let cached = claudeDirectoryCache[path]
            let needsDiscovery = cached == nil
                || cached!.modified != directory.modified
                || now - cached!.discoveredAt >= claudeDiscoveryTTL
            let files = needsDiscovery
                ? enumerateClaudeFiles(in: directory.url, todayStart: todayStart)
                : cached!.files
            claudeDirectoryCache[path] = ClaudeDirectoryCache(
                modified: directory.modified,
                discoveredAt: needsDiscovery ? now : cached!.discoveredAt,
                files: files
            )
            urls.append(contentsOf: files)
        }

        return urls.compactMap { url in
            let freshURL = URL(fileURLWithPath: url.path)
            guard let metadata = fileMetadata(freshURL) else { return nil }
            return (freshURL, metadata)
        }
    }

    private func enumerateClaudeFiles(in directory: URL, todayStart: Date) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(Self.fileResourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Self.fileResourceKeys)
            if values?.isDirectory == true {
                if isPastDateDirectory(url, root: claudeDir, before: todayStart) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "jsonl",
                  values?.isRegularFile == true else {
                continue
            }
            files.append(url)
        }
        return files
    }

    /// Some installations partition Claude logs below date-named directories.
    /// Prune those directories before visiting their descendants.
    private func isPastDateDirectory(_ url: URL, root: URL, before date: Date) -> Bool {
        let rootCount = root.standardized.pathComponents.count
        let components = Array(url.standardized.pathComponents.dropFirst(rootCount))
        let calendar = Calendar.current
        for component in components {
            if let dateComponents = dateComponents(from: component),
               let candidate = calendar.date(from: dateComponents),
               candidate < date {
                return true
            }
        }
        guard components.count >= 3 else { return false }
        for index in 0..<(components.count - 2) {
            guard let year = Int(components[index]),
                  let month = Int(components[index + 1]),
                  let day = Int(components[index + 2]),
                  (2000...2100).contains(year),
                  (1...12).contains(month),
                  (1...31).contains(day) else {
                continue
            }
            var dateComponents = DateComponents()
            dateComponents.calendar = calendar
            dateComponents.year = year
            dateComponents.month = month
            dateComponents.day = day
            if let candidate = calendar.date(from: dateComponents), candidate < date {
                return true
            }
        }
        return false
    }

    private func dateComponents(from component: String) -> DateComponents? {
        let pieces = component.split(separator: "-")
        let values: (Int, Int, Int)
        if pieces.count == 3,
           let year = Int(String(pieces[0])),
           let month = Int(String(pieces[1])),
           let day = Int(String(pieces[2])) {
            values = (year, month, day)
        } else if component.count == 8 {
            let start = component.index(component.startIndex, offsetBy: 4)
            let middle = component.index(start, offsetBy: 2)
            guard let year = Int(String(component[..<start])),
                  let month = Int(String(component[start..<middle])),
                  let day = Int(String(component[middle...])) else {
                return nil
            }
            values = (year, month, day)
        } else {
            return nil
        }
        let (year, month, day) = values
        guard (2000...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private func readClaude(now: TimeInterval, todayStart: TimeInterval) -> ClaudeStatus {
        let discovered = discoverClaudeFiles(
            todayStart: Date(timeIntervalSince1970: todayStart), now: now
        )
        let activePaths = Set(discovered.map { $0.url.path })
        claudeFiles = claudeFiles.filter { activePaths.contains($0.key) }

        var lastMtime: TimeInterval = 0
        for item in discovered {
            lastMtime = max(lastMtime, item.metadata.modified)
            let path = item.url.path
            var state = claudeFiles[path] ?? ClaudeFileState()
            if state.dayStart != todayStart {
                state.reset(for: todayStart)
            }
            guard item.metadata.modified >= todayStart else {
                advanceCursorToEnd(item.metadata, cursor: &state.cursor)
                claudeFiles[path] = state
                continue
            }
            let read = readNewLines(
                item.url, metadata: item.metadata, cursor: &state.cursor
            )
            if read.didReset {
                state.tokensToday = 0
                state.firstActiveInWindow = nil
            }
            for line in read.lines {
                parseClaudeLine(
                    line, now: now, todayStart: todayStart, state: &state
                )
            }
            claudeFiles[path] = state
        }

        var status = ClaudeStatus()
        status.tokensToday = claudeFiles.values.reduce(0) { $0 + $1.tokensToday }
        if let first = claudeFiles.values.compactMap(\.firstActiveInWindow).min() {
            status.sessionMin = Int((now - first) / 60)
        }
        status.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        return status
    }

    private func parseClaudeLine(_ line: Data, now: TimeInterval,
                                todayStart: TimeInterval,
                                state: inout ClaudeFileState) {
        guard line.range(of: Self.usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return
        }
        let entryEpoch = parseISO(obj["timestamp"] as? String)
        if let e = entryEpoch, e < todayStart { return }
        state.tokensToday += intVal(usage["input_tokens"])
            + intVal(usage["output_tokens"])
            + intVal(usage["cache_creation_input_tokens"])
            + intVal(usage["cache_read_input_tokens"])
        if let e = entryEpoch, now - e < 5 * 3600 {
            if state.firstActiveInWindow == nil || e < state.firstActiveInWindow! {
                state.firstActiveInWindow = e
            }
        }
    }

    // MARK: - Codex

    private func jsonlFiles(in directory: URL)
        -> [(url: URL, metadata: FileMetadata)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(Self.fileResourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "jsonl",
                  let metadata = fileMetadata(url) else { return nil }
            return (url, metadata)
        }
    }

    private func dayDirectory(for date: Date) -> URL {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return codexDir
            .appendingPathComponent(String(format: "%04d", components.year ?? 0))
            .appendingPathComponent(String(format: "%02d", components.month ?? 0))
            .appendingPathComponent(String(format: "%02d", components.day ?? 0))
    }

    private func readCodex(now: TimeInterval, todayStart: TimeInterval) -> CodexStatus {
        let calendar = Calendar.current
        let today = Date(timeIntervalSince1970: todayStart)
        let previous = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let todayFiles = jsonlFiles(in: dayDirectory(for: today))
        let activityFiles = todayFiles + jsonlFiles(in: dayDirectory(for: previous))

        var lastMtime: TimeInterval = 0
        for item in activityFiles {
            lastMtime = max(lastMtime, item.metadata.modified)
        }

        let activePaths = Set(todayFiles.map { $0.url.path })
        codexFiles = codexFiles.filter { activePaths.contains($0.key) }
        for item in todayFiles {
            let path = item.url.path
            var state = codexFiles[path] ?? CodexFileState()
            if state.dayStart != todayStart {
                state.reset(for: todayStart)
            }
            let read = readNewLines(
                item.url, metadata: item.metadata, cursor: &state.cursor
            )
            if read.didReset {
                state.sessionMaxTokens = 0
                state.latestRateLimits = nil
                state.latestRateLimitsTs = 0
            }
            for line in read.lines {
                parseCodexLine(line, state: &state)
            }
            codexFiles[path] = state
        }

        var status = CodexStatus()
        status.tokensToday = codexFiles.values.reduce(0) { $0 + $1.sessionMaxTokens }
        let latestRateLimits = codexFiles.values
            .filter { $0.latestRateLimits != nil }
            .max { $0.latestRateLimitsTs < $1.latestRateLimitsTs }?
            .latestRateLimits
        status.status = statusFromDelta(lastMtime > 0 ? now - lastMtime : 1e9)
        if let rl = latestRateLimits {
            applyRateLimits(rl, to: &status, now: now)
        }
        return status
    }

    private func parseCodexLine(_ line: Data, state: inout CodexFileState) {
        guard line.range(of: Self.tokenCountMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count" else {
            return
        }
        let info = payload["info"] as? [String: Any]
        let totalUsage = info?["total_token_usage"] as? [String: Any]
        let total = intVal(totalUsage?["total_tokens"])
        state.sessionMaxTokens = max(state.sessionMaxTokens, total)
        if let rl = payload["rate_limits"] as? [String: Any] {
            let timestamp = parseISO(obj["timestamp"] as? String) ?? 0
            if timestamp >= state.latestRateLimitsTs {
                state.latestRateLimitsTs = timestamp
                state.latestRateLimits = rl
            }
        }
    }

    private func applyRateLimits(_ rl: [String: Any], to status: inout CodexStatus,
                                 now: TimeInterval) {
        // Codex may put its weekly window in "primary" after the 5h limit
        // was removed, so classify by window length rather than key name.
        for (key, fallbackMin) in [("primary", 300), ("secondary", 7 * 1440)] {
            guard let w = rl[key] as? [String: Any] else { continue }
            let pct = (w["used_percent"] as? NSNumber)?.doubleValue
            let winMin = (w["window_minutes"] as? NSNumber)?.intValue
            var resetMin: Int?
            if let reset = (w["resets_at"] as? NSNumber)?.doubleValue {
                resetMin = max(0, Int((reset - now) / 60))
            }
            if (winMin ?? fallbackMin) >= 2 * 1440 {
                if status.weeklyPct == nil {
                    status.weeklyPct = pct
                    status.weeklyWindowMin = winMin
                    status.weeklyResetMin = resetMin
                }
            } else if status.primaryPct == nil {
                status.primaryPct = pct
                status.primaryWindowMin = winMin
                status.primaryResetMin = resetMin
            }
        }
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
