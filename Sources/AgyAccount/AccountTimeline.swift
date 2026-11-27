import Foundation

public struct AccountTimelineEntry: Equatable, Codable, Sendable {
    public var email: String
    public var sinceMs: Int64

    enum CodingKeys: String, CodingKey {
        case email
        case sinceMs = "since_ms"
    }

    public init(email: String, sinceMs: Int64) {
        self.email = email
        self.sinceMs = sinceMs
    }
}

/// Non-secret local account activation timeline (`~/.agy-cs/account-timeline.json`).
struct AccountTimelineStore {
    static let maxEntries = 512

    var fileURL: URL

    func load() -> [AccountTimelineEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([AccountTimelineEntry].self, from: data)
        else {
            return []
        }
        return normalize(raw)
    }

    @discardableResult
    func record(email rawEmail: String, nowMs: Int64, knownAccountCount: Int) -> [AccountTimelineEntry] {
        let normalized = Self.normalizeEmail(rawEmail)
        guard !normalized.isEmpty else {
            return load()
        }
        var entries = load()
        if entries.isEmpty {
            let since = knownAccountCount <= 1 ? Int64(0) : max(0, nowMs)
            entries = [AccountTimelineEntry(email: normalized, sinceMs: since)]
            save(entries)
            return entries
        }
        if let last = entries.last, last.email == normalized {
            return entries
        }
        let prevSince = entries.last?.sinceMs ?? 0
        let since = max(0, nowMs > prevSince ? nowMs : prevSince + 1)
        entries.append(AccountTimelineEntry(email: normalized, sinceMs: since))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
        return entries
    }

    func email(at timestampMs: Double?) -> String {
        guard let timestampMs, timestampMs.isFinite else {
            return ""
        }
        return email(atMs: Int64(timestampMs))
    }

    func email(atMs timestampMs: Int64) -> String {
        let entries = load()
        return Self.email(atMs: timestampMs, in: entries)
    }

    static func email(atMs timestampMs: Int64, in entries: [AccountTimelineEntry]) -> String {
        for entry in entries.reversed() where timestampMs >= entry.sinceMs {
            return entry.email
        }
        return ""
    }

    func knownEmails() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in load().reversed() where !entry.email.isEmpty {
            if seen.insert(entry.email).inserted {
                ordered.append(entry.email)
            }
        }
        return ordered
    }

    private func save(_ entries: [AccountTimelineEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            return
        }
        try? AtomicFile.write(fileURL, String(decoding: data, as: UTF8.self) + "\n")
    }

    private func normalize(_ raw: [AccountTimelineEntry]) -> [AccountTimelineEntry] {
        let sorted = raw
            .map { AccountTimelineEntry(email: Self.normalizeEmail($0.email), sinceMs: max(0, $0.sinceMs)) }
            .filter { !$0.email.isEmpty }
            .sorted { $0.sinceMs < $1.sinceMs }
        var collapsed: [AccountTimelineEntry] = []
        for entry in sorted {
            if let last = collapsed.last, last.email == entry.email {
                continue
            }
            collapsed.append(entry)
        }
        if collapsed.count > Self.maxEntries {
            return Array(collapsed.suffix(Self.maxEntries))
        }
        return collapsed
    }

    static func normalizeEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains("@") ? trimmed : ""
    }
}
