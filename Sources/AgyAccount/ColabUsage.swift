import Foundation

struct ColabUsageFetcher: UsageFetching {
    var http: any HTTPPosting = URLSessionPoster()
    var budget: TimeInterval = 10

    static let ccuInfoURL = URL(string: "https://colab.research.google.com/tun/m/ccu-info?authuser=0")!

    func fetch(
        _ logins: [(name: String, blob: String, project: String)],
        within seconds: TimeInterval
    ) -> [String: UsageSnapshot] {
        let parsed = logins.compactMap { login -> (name: String, payload: ColabTokenPayload)? in
            guard let payload = try? parseColabToken(login.blob) else {
                return nil
            }
            return (login.name, payload)
        }
        guard !parsed.isEmpty else {
            return [:]
        }
        let deadline = DispatchTime.now() + max(0, seconds)
        let results = SharedMap<String, UsageSnapshot>()
        DispatchQueue.concurrentPerform(iterations: parsed.count) { index in
            let item = parsed[index]
            let left = remainingSeconds(until: deadline)
            guard left > 0.5 else {
                return
            }
            let refreshed = refreshColabAccessToken(item.payload, http: http, timeout: min(6, left))
            guard let access = refreshed.accessToken else {
                return
            }
            let afterRefresh = remainingSeconds(until: deadline)
            guard afterRefresh > 0.3 else {
                return
            }
            let headers = [
                "Authorization": "Bearer \(access)",
                "Accept": "application/json",
                "X-Colab-Client-Agent": "colab-cli",
            ]
            guard let answer = http.post(HTTPRequest(
                url: Self.ccuInfoURL,
                headers: headers,
                body: Data(),
                timeout: min(6, afterRefresh),
                method: "GET"
            )), answer.status == 200,
                let ccu = parseColabCcuInfo(answer.body)
            else {
                return
            }
            let snapshot = UsageSnapshot(planID: "", planName: "", buckets: [], colab: ccu)
            results.set(item.name, snapshot)
        }
        return results.all
    }
}

func parseColabCcuInfo(_ data: Data) -> ColabUsageData? {
    guard var text = String(data: data, encoding: .utf8) else {
        return nil
    }
    if text.hasPrefix(")]}'") {
        text = String(text.dropFirst(4))
        while text.first == "\n" || text.first == "\r" {
            text = String(text.dropFirst())
        }
    }
    guard let cleanData = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: cleanData) as? [String: Any],
          let balance = (object["currentBalance"] as? NSNumber)?.doubleValue,
          let rate = (object["consumptionRateHourly"] as? NSNumber)?.doubleValue,
          let count = (object["assignmentsCount"] as? NSNumber)?.intValue
    else {
        return nil
    }
    return ColabUsageData(balance: balance, rateHourly: rate, activeAssignments: max(0, count))
}

private func remainingSeconds(until deadline: DispatchTime) -> TimeInterval {
    (Double(deadline.uptimeNanoseconds) - Double(DispatchTime.now().uptimeNanoseconds)) / 1_000_000_000
}

private final class SharedMap<Key: Hashable, Value>: @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    var all: [Key: Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ key: Key, _ value: Value) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }
}
