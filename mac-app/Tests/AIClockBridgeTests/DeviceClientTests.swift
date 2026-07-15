import XCTest
@testable import AIClockBridge

final class DeviceClientTests: XCTestCase {
    override func tearDown() {
        DeviceClient.wiredInfoProvider = nil
        super.tearDown()
    }

    func testFetchInfoPrefersWiredDevice() {
        var wired = DeviceInfo()
        wired.ip = "/dev/cu.usbserial-test"
        wired.ssid = "USB"
        wired.bridge = "USB serial"
        DeviceClient.wiredInfoProvider = { wired }

        let completed = expectation(description: "wired device info returned")
        DeviceClient.fetchInfo { result in
            guard case let .success(info) = result else {
                XCTFail("Expected wired device info")
                completed.fulfill()
                return
            }
            XCTAssertEqual(info.ip, "/dev/cu.usbserial-test")
            XCTAssertEqual(info.ssid, "USB")
            XCTAssertEqual(info.bridge, "USB serial")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }
}
