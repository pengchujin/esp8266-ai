import AppKit
import XCTest
@testable import AIClockBridge

final class MenuBarIconTests: XCTestCase {
    func testLightAndDarkIconsUseDifferentPalettes() throws {
        let light = MenuBarController.retroMacIcon(dark: false)
        let dark = MenuBarController.retroMacIcon(dark: true)

        let lightRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(light.tiffRepresentation)))
        let darkRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(dark.tiffRepresentation)))
        let lightCenter = try XCTUnwrap(lightRep.colorAt(x: lightRep.pixelsWide / 2,
                                                        y: lightRep.pixelsHigh / 2))
        let darkCenter = try XCTUnwrap(darkRep.colorAt(x: darkRep.pixelsWide / 2,
                                                       y: darkRep.pixelsHigh / 2))

        XCTAssertGreaterThan(lightCenter.brightnessComponent, 0.9)
        XCTAssertLessThan(darkCenter.brightnessComponent, 0.15)
    }

    func testSystemAppearanceUsesGlobalThemeSetting() throws {
        let suite = "MenuBarIconTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(MenuBarController.systemUsesDarkAppearance(defaults: defaults))
        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        XCTAssertTrue(MenuBarController.systemUsesDarkAppearance(defaults: defaults))
    }
}
