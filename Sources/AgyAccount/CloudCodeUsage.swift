import Foundation

struct HTTPRequest {
    var url: URL
    var headers: [String: String]
    var body: Data
    var timeout: TimeInterval = 6
}

struct HTTPResponse {
    var status: Int
    var body: Data
}

protocol HTTPPosting {
    func post(_ request: HTTPRequest) -> HTTPResponse?
}

struct URLSessionPoster: HTTPPosting {
    private static let session = URLSession(configuration: .ephemeral)

    func post(_ request: HTTPRequest) -> HTTPResponse? {
        let timeout = request.timeout
        var call = URLRequest(url: request.url, timeoutInterval: timeout)
        call.httpMethod = "POST"
        call.httpBody = request.body
        for (field, value) in request.headers {
            call.setValue(value, forHTTPHeaderField: field)
        }
        let answer = Shared<HTTPResponse?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = Self.session.dataTask(with: call) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                answer.set(HTTPResponse(status: http.statusCode, body: data ?? Data()))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return nil
        }
        return answer.value
    }
}

// agy 自己用这两个接口取套餐和额度。请求要带 agy 的标识和它的版本号：
// 标识不对时接口返回 403，版本太旧时回答里没有 Gemini 那一组（实测）。
struct CloudCodeUsage: UsageFetching {
    var http: any HTTPPosting = URLSessionPoster()
    var client: AgyClient
    // 切换要等这一步结束，所以全部请求加起来有一个时间上限。
    var budget: TimeInterval = 10

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let planURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let summaryURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    private static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let planBody = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8
    )

    func fetch(_ logins: [(name: String, blob: String)]) -> [String: UsageSnapshot] {
        let tokens = logins.compactMap { login in
            loginRefreshToken(login.blob).map { (name: login.name, refresh: $0) }
        }
        guard !tokens.isEmpty, let agy = client.resolve() else {
            return [:]
        }
        let deadline = Date().addingTimeInterval(budget)
        var working: (offset: Int, value: String)?
        var granted: (index: Int, access: String)?
        // 一个登录被拒绝时，分不清是 secret 不对还是这个登录失效了，所以换下一个登录再试。
        search: for (index, token) in tokens.enumerated() {
            for candidate in agy.secrets {
                switch grant(token.refresh, secret: candidate.value, deadline: deadline) {
                case .granted(let access):
                    working = candidate
                    granted = (index, access)
                    break search
                case .wrongClient:
                    continue
                case .refused:
                    continue search
                case .unreachable:
                    return [:]
                }
            }
            // 每个候选都被当成错误的 client。这和登录无关（实测），换下一个登录也一样。
            break
        }
        guard let working, let granted else {
            return [:]
        }
        client.remember(agy, secretOffset: working.offset)
        #if arch(arm64)
        let machine = "arm64"
        #else
        let machine = "amd64"
        #endif
        let agent = "antigravity/cli/\(agy.version) (aidev_client; os_type=darwin; arch=\(machine))"
        let found = Shared<[String: UsageSnapshot]>([:])
        DispatchQueue.concurrentPerform(iterations: tokens.count) { index in
            var access = index == granted.index ? granted.access : nil
            if access == nil,
               case .granted(let fresh) = grant(tokens[index].refresh, secret: working.value, deadline: deadline)
            {
                access = fresh
            }
            guard let access, let snapshot = snapshot(access: access, agent: agent, deadline: deadline) else {
                return
            }
            found.update { $0[tokens[index].name] = snapshot }
        }
        return found.value
    }

    private enum Grant {
        case granted(String)
        case wrongClient
        case refused
        case unreachable
    }

    // 临时 access token 只留在内存里。Google 不返回新的 refresh token，所以不用回写保存的副本。
    private func send(_ url: URL, _ headers: [String: String], _ body: Data, deadline: Date) -> HTTPResponse? {
        let left = deadline.timeIntervalSinceNow
        guard left > 0.5 else {
            return nil
        }
        return http.post(HTTPRequest(url: url, headers: headers, body: body, timeout: min(6, left)))
    }

    private func grant(_ refresh: String, secret: String, deadline: Date) -> Grant {
        let fields = [
            ("client_id", Self.clientID),
            ("client_secret", secret),
            ("refresh_token", refresh),
            ("grant_type", "refresh_token"),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        let form = ["Content-Type": "application/x-www-form-urlencoded"]
        guard let answer = send(Self.tokenURL, form, Data(body.utf8), deadline: deadline) else {
            return .unreachable
        }
        let object = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any] ?? [:]
        if answer.status == 200, let access = object["access_token"] as? String, !access.isEmpty {
            return .granted(access)
        }
        return object["error"] as? String == "invalid_client" ? .wrongClient : .refused
    }

    private func snapshot(access: String, agent: String, deadline: Date) -> UsageSnapshot? {
        let headers = ["Authorization": "Bearer \(access)", "Content-Type": "application/json", "User-Agent": agent]
        guard let planAnswer = send(Self.planURL, headers, Self.planBody, deadline: deadline),
              planAnswer.status == 200,
              let plan = parsePlan(planAnswer.body)
        else {
            return nil
        }
        let project: [String: Any] = plan.project.isEmpty ? [:] : ["project": plan.project]
        guard let body = try? JSONSerialization.data(withJSONObject: project),
              let summary = send(Self.summaryURL, headers, body, deadline: deadline)
        else {
            return nil
        }
        // 403 表示这个账号不提供额度数据，套餐仍然记下来。
        if summary.status == 403 {
            return UsageSnapshot(planID: plan.id, planName: plan.name, buckets: [])
        }
        guard summary.status == 200, let buckets = parseBuckets(summary.body) else {
            return nil
        }
        return UsageSnapshot(planID: plan.id, planName: plan.name, buckets: buckets)
    }
}

struct AgyIdentity {
    var version: String
    var secrets: [(offset: Int, value: String)]
    var size: Int
    var modified: Double
}

// 换 token 要用 agy 的 OAuth client secret。它不写进仓库，运行时从本机的 agy 二进制里读。
// 二进制里有几个候选，逐个试；记录文件只记 agy 的大小、修改时间、版本号和可用那个的位置。
struct AgyClient {
    var cacheURL: URL
    var locate: () -> String? = { try? agyExecutable() }
    var versionOf: (String) -> String? = agyVersion

    func resolve() -> AgyIdentity? {
        guard let found = locate() else {
            return nil
        }
        let path = (found as NSString).resolvingSymlinksInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
              let binary = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        else {
            return nil
        }
        var secrets = clientSecrets(in: binary)
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let current = (cached?["size"] as? NSNumber)?.intValue == size
            && (cached?["modified"] as? NSNumber)?.doubleValue == modified
        let known = current ? cached?["version"] as? String : nil
        guard !secrets.isEmpty, let version = known ?? versionOf(path), isVersion(version) else {
            return nil
        }
        if current, let offset = (cached?["secret_offset"] as? NSNumber)?.intValue,
           let index = secrets.firstIndex(where: { $0.offset == offset })
        {
            secrets.insert(secrets.remove(at: index), at: 0)
        }
        return AgyIdentity(version: version, secrets: secrets, size: size, modified: modified)
    }

    func remember(_ identity: AgyIdentity, secretOffset: Int) {
        let object: [String: Any] = [
            "size": identity.size,
            "modified": identity.modified,
            "version": identity.version,
            "secret_offset": secretOffset,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? AtomicFile.write(cacheURL, String(decoding: data, as: UTF8.self) + "\n")
    }

    private func isVersion(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 24 && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }
}

// Google 的 client secret 是固定前缀加 28 个字符。二进制里它后面紧跟着别的文字，所以按固定长度取。
func clientSecrets(in data: Data) -> [(offset: Int, value: String)] {
    let marker = Array("GOCSPX-".utf8)
    var found: [(offset: Int, value: String)] = []
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let base = buffer.baseAddress else {
            return
        }
        var cursor = 0
        while cursor < buffer.count, let hit = memmem(base + cursor, buffer.count - cursor, marker, marker.count) {
            let offset = base.distance(to: UnsafeRawPointer(hit))
            let start = offset + marker.count
            cursor = start
            guard start + 28 <= buffer.count else {
                break
            }
            let tail = buffer[start ..< start + 28]
            let value = String(decoding: marker + tail, as: UTF8.self)
            let valid = tail.allSatisfy { byte in
                let scalar = Unicode.Scalar(byte)
                return byte < 0x80 && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
            }
            if valid, !found.contains(where: { $0.value == value }) {
                found.append((offset, value))
            }
        }
    }
    return found
}

func agyVersion(_ path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else {
        return nil
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if process.isRunning {
            process.terminate()
        }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return nil
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class Shared<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        update { $0 = value }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
