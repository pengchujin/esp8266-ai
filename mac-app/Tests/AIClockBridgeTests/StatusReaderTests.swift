import Foundation
import XCTest
@testable import AIClockBridge

final class StatusReaderTests: XCTestCase {
    func testSnapshotReturnsWithoutWaitingForScanAndCoalescesRequests() {
        let scanStarted = DispatchSemaphore(value: 0)
        let releaseScan = DispatchSemaphore(value: 0)
        let scanCount = LockedInt()

        let service = StatusService(
            claudeDirectory: URL(fileURLWithPath: "/tmp/aiclock-no-claude"),
            codexDirectory: URL(fileURLWithPath: "/tmp/aiclock-no-codex"),
            scanObserver: {
                let count = scanCount.increment()
                scanStarted.signal()
                if count == 1 {
                    _ = releaseScan.wait(timeout: .now() + 2)
                }
            }
        )

        let started = DispatchTime.now()
        let snapshot = service.snapshot()
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        ) / 1_000_000_000

        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(snapshot.claude.status, "offline")
        XCTAssertEqual(scanStarted.wait(timeout: .now() + 1), .success)

        _ = service.snapshot()
        XCTAssertEqual(scanCount.value, 1)

        releaseScan.signal()
        let refreshed = expectation(description: "background scan completes")
        service.snapshot { _ in refreshed.fulfill() }
        wait(for: [refreshed], timeout: 2)
    }

    func testStatusReaderParsesOnlyNewBytesAndSkipsPastClaudeDateDirectories() throws {
        let root = try makeTemporaryDirectory()
        let claudeRoot = root.appendingPathComponent("claude")
        let codexRoot = root.appendingPathComponent("codex")
        let claudeProject = claudeRoot.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: claudeProject, withIntermediateDirectories: true
        )

        let oldClaudeFile = claudeRoot
            .appendingPathComponent("2020")
            .appendingPathComponent("01")
            .appendingPathComponent("01")
            .appendingPathComponent("old.jsonl")
        try FileManager.default.createDirectory(
            at: oldClaudeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let now = Date()
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = timestamp.string(from: now)
        let claudeFile = claudeProject.appendingPathComponent("session.jsonl")
        let codexDay = codexRoot
            .appendingPathComponent(timestampComponent(iso, index: 0))
            .appendingPathComponent(timestampComponent(iso, index: 1))
            .appendingPathComponent(timestampComponent(iso, index: 2))
        let codexFile = codexDay.appendingPathComponent("session.jsonl")

        let claudeFirst = claudeLine(timestamp: iso, input: 2, output: 3)
        let codexFirst = codexLine(timestamp: iso, total: 100)
        try write(claudeFirst, to: claudeFile)
        try write(codexFirst, to: codexFile)
        try write(claudeLine(timestamp: iso, input: 999, output: 0), to: oldClaudeFile)

        let reads = LockedReads()
        let service = StatusService(
            claudeDirectory: claudeRoot,
            codexDirectory: codexRoot,
            cacheTTL: 0,
            readObserver: { url, offset, length in
                reads.append(url: url, offset: offset, length: length)
            }
        )

        let firstResult = expectation(description: "first snapshot")
        var firstSnapshot: Snapshot?
        service.snapshot { snapshot in
            firstSnapshot = snapshot
            firstResult.fulfill()
        }
        wait(for: [firstResult], timeout: 2)
        XCTAssertEqual(firstSnapshot?.claude.tokensToday, 5)
        XCTAssertEqual(firstSnapshot?.codex.tokensToday, 100)

        let claudeOffset = UInt64(Data(claudeFirst.utf8).count)
        let codexOffset = UInt64(Data(codexFirst.utf8).count)
        try append(claudeLine(timestamp: iso, input: 4, output: 6), to: claudeFile)
        try append(codexLine(timestamp: iso, total: 150), to: codexFile)
        Thread.sleep(forTimeInterval: 0.01)

        let secondResult = expectation(description: "incremental snapshot")
        var secondSnapshot: Snapshot?
        service.snapshot { snapshot in
            secondSnapshot = snapshot
            secondResult.fulfill()
        }
        wait(for: [secondResult], timeout: 2)

        XCTAssertEqual(secondSnapshot?.claude.tokensToday, 15)
        XCTAssertEqual(secondSnapshot?.codex.tokensToday, 150)
        XCTAssertEqual(
            reads.offsets(for: claudeFile.resolvingSymlinksInPath().path),
            [0, claudeOffset]
        )
        XCTAssertEqual(
            reads.offsets(for: codexFile.resolvingSymlinksInPath().path),
            [0, codexOffset]
        )
        XCTAssertFalse(
            reads.contains(path: oldClaudeFile.resolvingSymlinksInPath().path)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIClockStatusReader")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func append(_ value: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data(value.utf8))
        handle.closeFile()
    }

    private func timestampComponent(_ iso: String, index: Int) -> String {
        let parts = iso.prefix(10).split(separator: "-").map(String.init)
        return parts[index]
    }

    private func claudeLine(timestamp: String, input: Int, output: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"message\":{\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}\n"
    }

    private func codexLine(timestamp: String, total: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)}}}}\n"
    }
}

private final class LockedInt {
    private let lock = NSLock()
    private var storedValue = 0

    func increment() -> Int {
        lock.lock()
        storedValue += 1
        let result = storedValue
        lock.unlock()
        return result
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private final class LockedReads {
    private struct Read {
        let path: String
        let offset: UInt64
        let length: UInt64
    }

    private let lock = NSLock()
    private var storedReads: [Read] = []

    func append(url: URL, offset: UInt64, length: UInt64) {
        lock.lock()
        storedReads.append(Read(
            path: url.resolvingSymlinksInPath().path,
            offset: offset,
            length: length
        ))
        lock.unlock()
    }

    func offsets(for path: String) -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedReads.filter { $0.path == path }.map(\.offset)
    }

    func contains(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReads.contains { $0.path == path }
    }
}
