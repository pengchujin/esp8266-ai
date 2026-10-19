import Foundation
import CoreGraphics
import ImageIO

struct CodexPetPackage {
    let id: String
    let displayName: String
    let spritesheet: CGImage
}

enum CodexPetPackageService {
    static let cellWidth = 192
    static let cellHeight = 208
    static let sheetWidth = 1536
    static let sheetHeight = 1872
    static let extendedSheetHeight = 2288
    static let targetWidth = 120
    static let targetHeight = 120

    // The order and timing mirror Codex's 8x9 pet atlas contract.
    static let states: [(id: String, frames: Int, durationMs: Int)] = [
        ("idle", 6, 1100),
        ("running-right", 8, 1060),
        ("running-left", 8, 1060),
        ("waving", 4, 700),
        ("jumping", 5, 840),
        ("failed", 8, 1220),
        ("waiting", 6, 1010),
        ("running", 6, 820),
        ("review", 6, 1030),
    ]

    static func load(from selectedURL: URL) throws -> CodexPetPackage {
        let manifestURL = selectedURL.hasDirectoryPath
            ? selectedURL.appendingPathComponent("pet.json")
            : selectedURL
        let root = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = manifest["id"] as? String, !id.isEmpty,
              let relativePath = manifest["spritesheetPath"] as? String, !relativePath.isEmpty else {
            throw error("pet.json 缺少 id 或 spritesheetPath")
        }

        let sheetURL = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard sheetURL.path.hasPrefix(rootPrefix) else {
            throw error("spritesheetPath 不能指向宠物目录之外")
        }
        guard let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw error("无法读取 spritesheet（需要 PNG 或 WebP）")
        }
        let isV2 = (manifest["spriteVersionNumber"] as? NSNumber)?.intValue == 2
        let expectedHeight = isV2 ? extendedSheetHeight : sheetHeight
        guard image.width == sheetWidth, image.height == expectedHeight else {
            throw error(isV2
                        ? "v2 Codex spritesheet 必须是 1536×2288"
                        : "仅支持 1536×1872 的 Codex 8×9 spritesheet")
        }
        return CodexPetPackage(id: id,
                               displayName: manifest["displayName"] as? String ?? id,
                               spritesheet: image)
    }

    /// AIPET1 wire format. All integers are little-endian. The CRC covers only
    /// the RGB332 payload, making interrupted uploads cheap to reject on-device.
    static func buildDeviceFile(from package: CodexPetPackage) throws -> Data {
        let entrySize = 12
        let headerSize = 20 + states.count * entrySize
        var payload = Data(capacity: states.reduce(0) { $0 + $1.frames } * targetWidth * targetHeight)
        var entries: [(frames: Int, delay: Int, offset: Int, length: Int)] = []

        for (row, state) in states.enumerated() {
            let offset = headerSize + payload.count
            for column in 0..<state.frames {
                guard let frame = renderFrame(sheet: package.spritesheet, row: row, column: column) else {
                    throw error("无法转换 \(state.id) 第 \(column + 1) 帧")
                }
                payload.append(frame)
            }
            entries.append((state.frames, max(50, state.durationMs / state.frames),
                            offset, state.frames * targetWidth * targetHeight))
        }

        var out = Data("AIPET1".utf8)
        out.appendLE(UInt16(targetWidth))
        out.appendLE(UInt16(targetHeight))
        out.append(UInt8(states.count))
        out.append(0)
        out.appendLE(UInt32(headerSize + payload.count))
        out.appendLE(crc32(payload))
        for entry in entries {
            out.append(UInt8(entry.frames))
            out.append(0)
            out.appendLE(UInt16(entry.delay))
            out.appendLE(UInt32(entry.offset))
            out.appendLE(UInt32(entry.length))
        }
        out.append(payload)
        return out
    }

    private static func renderFrame(sheet: CGImage, row: Int, column: Int) -> Data? {
        let cropRect = CGRect(x: column * cellWidth, y: row * cellHeight,
                              width: cellWidth, height: cellHeight)
        guard let crop = sheet.cropping(to: cropRect) else { return nil }
        let bytesPerRow = targetWidth * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * targetHeight)
        guard let ctx = CGContext(data: &rgba, width: targetWidth, height: targetHeight,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.black)
        ctx.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        let scale = min(CGFloat(targetWidth) / CGFloat(cellWidth),
                        CGFloat(targetHeight) / CGFloat(cellHeight))
        let w = CGFloat(cellWidth) * scale
        let h = CGFloat(cellHeight) * scale
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: (CGFloat(targetWidth) - w) / 2,
                                  y: (CGFloat(targetHeight) - h) / 2, width: w, height: h))

        var rgb332 = Data(count: targetWidth * targetHeight)
        rgb332.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for i in 0..<(targetWidth * targetHeight) {
                let r = rgba[i * 4]
                let g = rgba[i * 4 + 1]
                let b = rgba[i * 4 + 2]
                dst[i] = (r & 0xE0) | ((g & 0xE0) >> 3) | (b >> 6)
            }
        }
        return rgb332
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CodexPetPackage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
