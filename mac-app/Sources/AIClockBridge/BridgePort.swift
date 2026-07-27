import Foundation

// The local HTTP port the clock polls. It was hard-coded to 8765 for a long
// time, but that port collides with other software on some machines (issue #18:
// Windows 百度输入法 listens on 8765 and can't be told not to), so it is now
// overridable. The firmware needs no change — its "Bridge host" field has
// always been host:port.
enum BridgePort {
    static let fallback: UInt16 = 8765
    private static let key = "bridge_port"

    /// `--port N`  >  `AICLOCK_PORT`  >  saved setting  >  8765.
    /// The flag is for one-off runs, the env var for LaunchAgent plists, the
    /// saved setting for the menu-bar item.
    static func resolve(_ args: [String] = CommandLine.arguments) -> UInt16 {
        if let i = args.firstIndex(of: "--port"), i + 1 < args.count,
           let p = parse(args[i + 1]) { return p }
        if let p = parse(ProcessInfo.processInfo.environment["AICLOCK_PORT"]) { return p }
        if let p = parse(saved) { return p }
        return fallback
    }

    /// nil = no override, use the default. Takes effect on the next launch.
    static var saved: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func parse(_ text: String?) -> UInt16? {
        guard let text = text?.trimmingCharacters(in: .whitespaces),
              let n = Int(text), n >= 1, n <= 65535 else { return nil }
        return UInt16(n)
    }
}
