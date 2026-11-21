import Foundation

struct UsageBucket: Equatable {
    var id: String
    var remaining: Double
    var resetTime: String
}

struct UsageSnapshot: Equatable {
    var planID: String
    var planName: String
    var buckets: [UsageBucket]
    // Gemini 4 Argon 对这个账号是不是锁着的。nil 表示没取到模型列表。
    var argonLocked: Bool? = nil
    // 这个账号在 Cloud Code 那边的 project。下次查询用它提前发额度请求。
    var project = ""
}

struct UsagePlan {
    var id: String
    var name: String
    var project: String
}

protocol UsageFetching {
    // 一次查询从开始到结束最多用多久。等别的进程查完也用这个时限。
    var budget: TimeInterval { get }
    func fetch(
        _ logins: [(name: String, blob: String, project: String)],
        within seconds: TimeInterval
    ) -> [String: UsageSnapshot]
}

// loadCodeAssist 的回答。付费套餐在 paidTier，没有时用 currentTier。
func parsePlan(_ data: Data) -> UsagePlan? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let tier = object["paidTier"] ?? object["currentTier"]
    let fields = tier as? [String: Any] ?? [:]
    let project = object["cloudaicompanionProject"]
    return UsagePlan(
        id: plain(tier as? String ?? fields["id"] as? String ?? ""),
        name: plain(fields["name"] as? String ?? ""),
        project: project as? String ?? (project as? [String: Any])?["id"] as? String ?? ""
    )
}

// retrieveUserQuotaSummary 的回答。每组里的每一项是一个额度窗口。
func parseBuckets(_ data: Data) -> [UsageBucket]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    var entries = object["buckets"] as? [[String: Any]] ?? []
    for group in object["groups"] as? [[String: Any]] ?? [] {
        entries += group["buckets"] as? [[String: Any]] ?? []
    }
    var buckets: [UsageBucket] = []
    for entry in entries {
        guard let id = entry["bucketId"] as? String,
              let remaining = (entry["remainingFraction"] as? NSNumber)?.doubleValue,
              entry["disabled"] as? Bool != true,
              !buckets.contains(where: { $0.id == plain(id) })
        else {
            continue
        }
        buckets.append(UsageBucket(
            id: plain(id),
            remaining: min(1, max(0, remaining)),
            resetTime: plain(entry["resetTime"] as? String ?? "")
        ))
    }
    return buckets
}

// fetchAvailableModels 的回答。套餐同样是 Pro，Google 只给付费订阅开放 Gemini 4 的几个模型；
// 没开放的账号，列表里对应的是带 disabled 的占位项（实测）。loadCodeAssist 分不出这两种账号。
func parseArgonLocked(_ data: Data) -> Bool? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = object["models"] as? [String: Any]
    else {
        return nil
    }
    let argon = models.filter { $0.key.lowercased().contains("argon") }.values.map { entry in
        (entry as? [String: Any])?["disabled"] as? Bool == true
    }
    return argon.isEmpty ? nil : !argon.contains(false)
}

// 记录带着邮箱。同一个名字后来存成了另一个登录时，旧记录不再显示。
func encodeUsage(_ snapshot: UsageSnapshot, email: String, fetchedAt: String) -> String {
    var object: [String: Any] = [
        "email": email,
        "fetched_at": fetchedAt,
        "plan_id": snapshot.planID,
        "plan_name": snapshot.planName,
        "project": snapshot.project,
        "buckets": snapshot.buckets.map { ["id": $0.id, "remaining": $0.remaining, "reset_time": $0.resetTime] },
    ]
    if let locked = snapshot.argonLocked {
        object["argon_locked"] = locked
    }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
}

func decodeUsage(_ data: Data, email: String) -> UsageSnapshot? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["email"] as? String == email
    else {
        return nil
    }
    let buckets = (object["buckets"] as? [[String: Any]] ?? []).compactMap { entry -> UsageBucket? in
        guard let id = entry["id"] as? String, let remaining = (entry["remaining"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return UsageBucket(id: plain(id), remaining: min(1, max(0, remaining)), resetTime: plain(entry["reset_time"] as? String ?? ""))
    }
    return UsageSnapshot(
        planID: plain(object["plan_id"] as? String ?? ""),
        planName: plain(object["plan_name"] as? String ?? ""),
        buckets: buckets,
        argonLocked: object["argon_locked"] as? Bool,
        project: plain(object["project"] as? String ?? "")
    )
}

// g1-pro-tier 显示成 Pro，free-tier 显示成 Free。认不出来时用上游给的名字。
func planLabel(id: String, name: String) -> String {
    let words = id.split(separator: "-").map(String.init)
    if words.count >= 2, words.last == "tier", id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
        let core = words.dropLast().drop { $0 == "g1" }
        if !core.isEmpty {
            return core.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
    let shown = String(plain(name).prefix(24))
    return shown.isEmpty ? "—" : shown
}

func parseTimestamp(_ text: String) -> Date? {
    let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: whole)
}

// 满额时不显示重置时间。过了重置时间，这一项已经恢复，按 100% 显示。
func bucketText(_ bucket: UsageBucket?, now: Date, timeZone: TimeZone) -> String {
    guard let bucket else {
        return "—"
    }
    let reset = parseTimestamp(bucket.resetTime)
    if let reset, now >= reset {
        return "100%"
    }
    var percent = Int((bucket.remaining * 100).rounded())
    if bucket.remaining < 1 {
        percent = min(percent, 99)
    }
    if bucket.remaining > 0 {
        percent = max(percent, 1)
    }
    guard percent < 100, let reset else {
        return "\(percent)%"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MM-dd HH:mm"
    return "\(percent)% \(formatter.string(from: reset))"
}

// unpaid 给套餐名加上“非付费”的标记：套餐不是免费档，但付费订阅才有的 Argon 锁着。
func usageCells(
    _ snapshot: UsageSnapshot,
    now: Date,
    timeZone: TimeZone,
    unpaid: (String) -> String = { $0 }
) -> [String] {
    let label = planLabel(id: snapshot.planID, name: snapshot.planName)
    func text(_ match: (String) -> Bool) -> String {
        bucketText(snapshot.buckets.first { match($0.id) }, now: now, timeZone: timeZone)
    }
    return [
        snapshot.argonLocked == true && snapshot.planID != "free-tier" ? unpaid(label) : label,
        "5h " + text { $0 == "gemini-5h" },
        "7d " + text { $0 == "gemini-weekly" },
        "Argon " + text { $0.contains("argon") },
    ]
}

// 没有任何一行带额度时，保持原来的两列写法，不补空格。
func alignedRows(_ rows: [[String]]) -> [String] {
    let columns = rows.map(\.count).max() ?? 0
    guard columns > 2 else {
        return rows.map { $0.joined(separator: "  ") }
    }
    let widths = (0 ..< columns).map { column in
        rows.compactMap { $0.count > column ? displayWidth($0[column]) : nil }.max() ?? 0
    }
    return rows.map { row in
        let padded = row.enumerated().map { column, cell in
            column == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[column] - displayWidth(cell))
        }
        return padded.joined(separator: "  ")
    }
}

// 中日韩文字和全角标点在终端里占两列。
func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { width, scalar in
        switch scalar.value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF, 0xFE30 ... 0xFE4F,
             0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6:
            return width + 2
        default:
            return width + 1
        }
    }
}

// 这些字符串来自网络，会被写进记录并显示在终端里，所以去掉控制字符并限制长度。
private func plain(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(64))
}
