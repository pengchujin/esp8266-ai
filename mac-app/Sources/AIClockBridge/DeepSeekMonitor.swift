import Foundation

// DeepSeek API balance for the device's clock page: the official
// GET https://api.deepseek.com/user/balance endpoint (Bearer key), refreshed
// every 5 minutes. DeepSeek is pay-as-you-go, so "usage" means remaining
// balance, not a quota percentage. The key comes from the tray menu
// (设置 DeepSeek API Key…) and is stored in UserDefaults.
final class DeepSeekMonitor {
    static let shared = DeepSeekMonitor()

    struct Snapshot {
        let ok: Bool        // a fetch has succeeded at least once
        let available: Bool // account can pay for API calls right now
        let balance: Double // total_balance (granted + topped-up)
        let currency: String
    }

    static let keyDefaultsKey = "deepseek_api_key"

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: keyDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyDefaultsKey) }
    }

    private let lock = NSLock()
    private var snap = Snapshot(ok: false, available: false, balance: 0, currency: "CNY")
    private var timer: Timer?

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snap
    }

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    // MARK: - endpoints

    func jsonData() -> Data {
        let s = snapshot
        let dict: [String: Any] = [
            "ok": s.ok,
            "avail": s.available,
            "bal": s.balance,
            "cur": s.currency,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    // MARK: - key configuration

    /// Store a new API key and immediately validate it with a fetch. Calls
    /// back on the main queue with (success, detail): on failure, detail
    /// carries the server's error message (or a network description) so the
    /// menu alert can show WHY the key was rejected.
    static func setKey(_ key: String, completion: @escaping (Bool, String) -> Void) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.apiKey = trimmed
        guard !trimmed.isEmpty else {
            // cleared on purpose: drop the cached snapshot
            Self.shared.lock.lock()
            Self.shared.snap = Snapshot(ok: false, available: false, balance: 0, currency: "CNY")
            Self.shared.lock.unlock()
            DispatchQueue.main.async { completion(true, "") }
            return
        }
        Self.shared.fetch { ok, detail in
            DispatchQueue.main.async { completion(ok, detail) }
        }
    }

    // MARK: - fetch

    private func fetch(completion: ((Bool, String) -> Void)? = nil) {
        let key = Self.apiKey
        guard !key.isEmpty,
              let url = URL(string: "https://api.deepseek.com/user/balance") else {
            completion?(false, "未设置 API Key")
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            var result: (Bool, String) = (false, error?.localizedDescription ?? "网络错误")
            defer { completion?(result.0, result.1) }
            guard let data = data else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = obj["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
                // DeepSeek error body: {"error":{"message":"..."}}
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                    result = (false, "HTTP \(status)：\(msg)")
                } else {
                    result = (false, "HTTP \(status)")
                }
                return
            }
            // domestic accounts report CNY, overseas USD: prefer CNY, else first
            let info = infos.first(where: { ($0["currency"] as? String) == "CNY" }) ?? infos[0]
            guard let totalStr = info["total_balance"] as? String,
                  let total = Double(totalStr) else { return }
            let currency = (info["currency"] as? String) ?? "CNY"
            let available = (obj["is_available"] as? Bool) ?? (total > 0)
            self.lock.lock()
            self.snap = Snapshot(ok: true, available: available, balance: total, currency: currency)
            self.lock.unlock()
            result = (true, "\(currency) \(totalStr)")
        }.resume()
    }
}
