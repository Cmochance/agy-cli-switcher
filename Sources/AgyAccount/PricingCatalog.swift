import Foundation

public enum PricingMode: String, Codable, Equatable, Sendable {
    case standard
    case promo
}

public struct ModelRate: Equatable, Codable, Sendable {
    public var model: String
    public var input: Double
    public var cache: Double
    public var output: Double
    public var until: String?
    public var nextInput: Double?
    public var nextCache: Double?
    public var nextOutput: Double?

    public init(
        model: String,
        input: Double,
        cache: Double,
        output: Double,
        until: String? = nil,
        nextInput: Double? = nil,
        nextCache: Double? = nil,
        nextOutput: Double? = nil
    ) {
        self.model = model
        self.input = input
        self.cache = cache
        self.output = output
        self.until = until
        self.nextInput = nextInput
        self.nextCache = nextCache
        self.nextOutput = nextOutput
    }
}

/// Offline API reference pricing catalog (USD per 1M tokens) with optional local override.
public enum PricingCatalog {
    public static let baselineRates: [ModelRate] = [
        ModelRate(
            model: "gemini-4-carbon",
            input: 2.0,
            cache: 0.1,
            output: 10.0,
            until: "2026-12-01",
            nextInput: 4.0,
            nextCache: 0.2,
            nextOutput: 20.0
        ),
        ModelRate(
            model: "gemini-4-argon",
            input: 2.0,
            cache: 0.1,
            output: 10.0,
            until: "2026-12-01",
            nextInput: 4.0,
            nextCache: 0.2,
            nextOutput: 20.0
        ),
        ModelRate(model: "gemini-4-neon", input: 3.0, cache: 0.15, output: 15.0),
        ModelRate(model: "gemini-4-hydrogen", input: 1.5, cache: 0.075, output: 7.5),
        ModelRate(model: "claude-opus-5-5", input: 4.0, cache: 0.2, output: 20.0),
        ModelRate(model: "claude-sonnet-5-5", input: 2.0, cache: 0.1, output: 10.0),
    ]

    public static func loadRates(from pricingFile: URL?) -> [ModelRate] {
        guard let pricingFile,
              let data = try? Data(contentsOf: pricingFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRates = json["rates"] as? [[String: Any]]
        else {
            return baselineRates
        }
        var custom: [ModelRate] = []
        for entry in rawRates {
            guard let model = (entry["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !model.isEmpty,
                  let input = (entry["input"] as? NSNumber)?.doubleValue,
                  let cache = (entry["cache"] as? NSNumber)?.doubleValue,
                  let output = (entry["output"] as? NSNumber)?.doubleValue,
                  input.isFinite, cache.isFinite, output.isFinite,
                  input >= 0, cache >= 0, output >= 0
            else {
                continue
            }
            let until = (entry["until"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = entry["next"] as? [String: Any]
            let nextInput = (next?["input"] as? NSNumber)?.doubleValue
            let nextCache = (next?["cache"] as? NSNumber)?.doubleValue
            let nextOutput = (next?["output"] as? NSNumber)?.doubleValue
            custom.append(ModelRate(
                model: model,
                input: input,
                cache: cache,
                output: output,
                until: (until?.isEmpty == false) ? until : nil,
                nextInput: nextInput,
                nextCache: nextCache,
                nextOutput: nextOutput
            ))
        }
        guard !custom.isEmpty else {
            return baselineRates
        }
        var merged = custom
        for fallback in baselineRates where !merged.contains(where: { $0.model == fallback.model }) {
            merged.append(fallback)
        }
        return merged
    }

    public static func modelKey(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        text = text.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(claude-(?:opus|sonnet|haiku)-\d+)\.(\d+)"#,
            with: "$1-$2",
            options: .regularExpression
        )
        return text
    }

    public static func normalizedModelID(_ label: String) -> String {
        let raw = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ""
        }
        if let orchRange = raw.range(of: #"^orchestrator(?:\s*\(([^)]+)\)|\s+(.+))?$"#, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(raw[orchRange])
            var tail = matched.replacingOccurrences(of: #"^orchestrator"#, with: "", options: [.regularExpression, .caseInsensitive])
            if let paren = firstCapture(in: tail, pattern: #"^\s*\(([^)]+)\)"#) {
                tail = paren
            }
            tail = tail
                .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: #"\s+(low|medium|high|xhigh|extra\s+high|max|minimal|thinking)$"#,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if tail.contains("claude") {
                let norm = tail
                    .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
                    .replacingOccurrences(of: #"(claude-(?:opus|sonnet|haiku)-\d+)\.(\d+)"#, with: "$1-$2", options: .regularExpression)
                return "orchestrator-\(norm)"
            }
            if let variant = firstCapture(in: tail, pattern: #"(?:gemini[\s-]*4[\s-]*)?(neon|carbon|argon|hydrogen)$"#) {
                return variant == "carbon" ? "gemini-pro-orchestrator" : "gemini-pro-orchestrator-\(variant)"
            }
            let slug = tail.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            return slug.isEmpty ? "gemini-pro-orchestrator" : "gemini-pro-orchestrator-\(slug)"
        }

        var id = raw.lowercased()
        id = id.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        id = id.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        id = id.replacingOccurrences(
            of: #"-(low|medium|high|xhigh|extra-high|max|minimal)$"#,
            with: "",
            options: .regularExpression
        )
        id = id.replacingOccurrences(
            of: #"(claude-(?:opus|sonnet|haiku)-\d+)\.(\d+)"#,
            with: "$1-$2",
            options: .regularExpression
        )
        return id
    }

    public static func pricingKey(model: String, role: OrchestratorRole) -> String {
        let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("orchestrator") {
            if role == .execution, lower.hasPrefix("orchestrator") {
                return "gemini-4-hydrogen"
            }
            if let match = regexGroups(
                in: raw,
                pattern: #"claude[\s-]*(opus|sonnet|haiku)[\s-]*(\d+)[.-](\d+)"#,
                options: [.caseInsensitive]
            ), match.count >= 4 {
                return "claude-\(match[1].lowercased())-\(match[2])-\(match[3])"
            }
            if let flash = firstCapture(in: raw, pattern: #"gemini[\s-]*(\d+(?:\.\d+)?)[\s-]*flash"#, caseInsensitive: true) {
                return "gemini-\(flash)-flash"
            }
            if lower.contains("hydrogen") { return "gemini-4-hydrogen" }
            if lower.contains("neon") { return "gemini-4-neon" }
            if lower.contains("argon") { return "gemini-4-argon" }
            if lower.contains("carbon") { return "gemini-4-carbon" }
            if role == .execution { return "gemini-4-hydrogen" }
            return "gemini-4-carbon"
        }
        return modelKey(raw)
    }

    public static func estimateCost(
        model: String,
        role: OrchestratorRole,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        timestampMs: Double?,
        rates: [ModelRate],
        mode: PricingMode,
        now: Date = Date()
    ) -> Double? {
        let key = pricingKey(model: model, role: role)
        guard !key.isEmpty,
              let rate = rates.first(where: { key == $0.model || key.hasPrefix($0.model + "-") })
        else {
            return nil
        }
        let dateText: String = {
            let targetDate = timestampMs.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? now
            return utcDateString(targetDate)
        }()
        let resolved = resolveRate(rate, mode: mode, utcDate: dateText)
        let total = Double(max(0, inputTokens)) * resolved.input
            + Double(max(0, cacheReadTokens)) * resolved.cache
            + Double(max(0, outputTokens)) * resolved.output
        return total / 1_000_000.0
    }

    public static func resolveRate(_ rate: ModelRate, mode: PricingMode, utcDate: String) -> (input: Double, cache: Double, output: Double) {
        guard let until = rate.until,
              let nextInput = rate.nextInput,
              let nextCache = rate.nextCache,
              let nextOutput = rate.nextOutput
        else {
            return (rate.input, rate.cache, rate.output)
        }
        if mode == .standard || utcDate >= until {
            return (nextInput, nextCache, nextOutput)
        }
        return (rate.input, rate.cache, rate.output)
    }

    public static func shortModelDisplayName(_ name: String) -> String {
        let clean = name
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return "Unknown"
        }
        if let g4 = firstCapture(in: clean, pattern: #"^gemini[\s-]+4[\s-]+([a-z0-9]+)"#, caseInsensitive: true) {
            return g4.prefix(1).uppercased() + g4.dropFirst().lowercased()
        }
        if let groups = regexGroups(
            in: clean,
            pattern: #"^gemini[\s-]+(\d+(?:\.\d+)?)[\s-]+(pro|flash)"#,
            options: [.caseInsensitive]
        ), groups.count >= 3 {
            let tier = groups[2].prefix(1).uppercased() + groups[2].dropFirst().lowercased()
            return "\(groups[1]) \(tier)"
        }
        return clean.replacingOccurrences(
            of: #"-(?:high|xhigh|medium|low|trial|n)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    public static func shortSubagentModelName(_ label: String) -> String {
        let raw = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ""
        }
        let stripped = raw
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.range(of: "orchestrator", options: .caseInsensitive) != nil {
            let trimmed = stripped.replacingOccurrences(
                of: #"^gemini[-\s]*pro[-\s]*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Orchestrator" : trimmed
        }
        let genericTiers: Set<String> = ["flash", "pro", "ultra", "nano", "lite", "mini", "exp", "thinking"]
        if let groups = regexGroups(
            in: stripped,
            pattern: #"gemini[\s-]*(\d+(?:\.\d+)?)[\s-]+([a-z0-9]+)(?:[\s-]+([a-z0-9]+))?"#,
            options: [.caseInsensitive]
        ), groups.count >= 3 {
            let version = groups[1]
            let family = groups[2]
            let lower = family.lowercased()
            let cap = lower.prefix(1).uppercased() + lower.dropFirst()
            if !genericTiers.contains(lower) {
                return cap
            }
            var extra = ""
            if groups.count >= 4, !groups[3].isEmpty {
                let candidate = groups[3].lowercased()
                let effortSet: Set<String> = ["low", "medium", "high", "xhigh", "max", "minimal", "thinking", "preview", "exp"]
                if !effortSet.contains(candidate) {
                    extra = " " + candidate.prefix(1).uppercased() + candidate.dropFirst()
                }
            }
            return "\(version) \(cap)\(extra)"
        }
        if let groups = regexGroups(
            in: stripped,
            pattern: #"claude[\s-]+(opus|sonnet|haiku)(?:[\s-]+([\d.]+))?"#,
            options: [.caseInsensitive]
        ), groups.count >= 2 {
            let family = groups[1].prefix(1).uppercased() + groups[1].dropFirst().lowercased()
            if groups.count >= 3, !groups[2].isEmpty {
                return "\(family) \(groups[2])"
            }
            return family
        }
        if stripped.lowercased().hasPrefix("gpt") {
            return stripped
                .replacingOccurrences(of: #"^gpt[-\s]+oss[-\s]+"#, with: "GPT-OSS ", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"^gpt[-\s]+"#, with: "GPT-", options: [.regularExpression, .caseInsensitive])
                .uppercased()
        }
        return stripped.count > 18 ? String(stripped.prefix(18)) : stripped
    }

    private static func utcDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func firstCapture(in text: String, pattern: String, caseInsensitive: Bool = false) -> String? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let groups = regexGroups(in: text, pattern: pattern, options: options), groups.count >= 2, !groups[1].isEmpty else {
            return nil
        }
        return groups[1]
    }

    private static func regexGroups(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        return (0 ..< match.numberOfRanges).map { index in
            let subrange = match.range(at: index)
            guard subrange.location != NSNotFound, let swiftRange = Range(subrange, in: text) else {
                return ""
            }
            return String(text[swiftRange])
        }
    }
}
