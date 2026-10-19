import XCTest
@testable import AIClockBridge

final class NetSpeedMonitorTests: XCTestCase {
    func testCounterDecreaseIsDiscarded() {
        XCTAssertNil(NetSpeedMonitor.counterDelta(current: 10, previous: 5_000_000_000))
    }

    func testCounterIncreaseReturnsDifference() {
        XCTAssertEqual(NetSpeedMonitor.counterDelta(current: 250, previous: 100), 150)
    }

    func testCodexPetCRC32KnownVector() {
        XCTAssertEqual(CodexPetPackageService.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testCodexPetStateContractHasNineRowsAnd57Frames() {
        XCTAssertEqual(CodexPetPackageService.states.count, 9)
        XCTAssertEqual(CodexPetPackageService.states.reduce(0) { $0 + $1.frames }, 57)
        XCTAssertEqual(CodexPetPackageService.states.map(\.id), [
            "idle", "running-right", "running-left", "waving", "jumping",
            "failed", "waiting", "running", "review",
        ])
    }

    func testCodexPetDeviceFileHeaderAndPayload() throws {
        let w = CodexPetPackageService.sheetWidth
        let h = CodexPetPackageService.sheetHeight
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("CGContext creation failed")
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let package = CodexPetPackage(id: "test", displayName: "Test", spritesheet: context.makeImage()!)
        let file = try CodexPetPackageService.buildDeviceFile(from: package)

        XCTAssertEqual(String(decoding: file.prefix(6), as: UTF8.self), "AIPET1")
        XCTAssertEqual(file.count, 128 + 57 * 120 * 120)
        XCTAssertEqual(file[10], 9)
        let encodedCRC = UInt32(file[16]) | UInt32(file[17]) << 8
            | UInt32(file[18]) << 16 | UInt32(file[19]) << 24
        XCTAssertEqual(encodedCRC, CodexPetPackageService.crc32(file.dropFirst(128)))
    }
}
