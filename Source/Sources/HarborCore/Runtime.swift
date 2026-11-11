import Foundation
import Darwin
import Security

public enum HarborError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
public enum PrivateFiles {
    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else { throw HarborError.message("无法保护本机配置目录。") }
    }
    public static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent()); try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw HarborError.message("无法保护本机配置。") }
    }
}
public enum SecretStore {
    public static func save(_ text: String, account: String = "subscription") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.harbor.proxy", kSecAttrAccount as String: account]
        let data = Data(text.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw HarborError.message("无法保存订阅到钥匙串。") }
        } else if result != errSecSuccess { throw HarborError.message("无法更新钥匙串。") }
    }
    public static func delete(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.harbor.proxy", kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HarborError.message("无法清理未使用的订阅凭据。") }
    }
    public static func read(account: String = "subscription") -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.harbor.proxy", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
public struct SubscriptionQuota: Codable, Equatable {
    public var upload: UInt64?, download: UInt64?, total: UInt64?, expire: Date?
    public var updateHours: Int? = nil
    public static func parse(_ header: String?) -> Self {
        var fields = [String: UInt64]()
        for part in (header ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let value = UInt64(pair[1]) { fields[pair[0].lowercased()] = value }
        }
        return .init(upload: fields["upload"], download: fields["download"], total: fields["total"], expire: fields["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil })
    }
    public var used: UInt64? { guard let u = upload, let d = download else { return nil }; let r = u.addingReportingOverflow(d); return r.overflow ? nil : r.partialValue }
}
// Cross-origin redirects are refused so subscription credentials are never forwarded to another origin.
final class SubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let a = response.url, let b = request.url, b.scheme == "https", a.host == b.host, a.port == b.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}
public enum SubscriptionClient {
    public static func fetch(_ text: String) async throws -> (SubscriptionDocument, SubscriptionQuota) {
        do { return try await fetchAttempt(text, direct: false) }
        catch { return try await fetchDirect(text) }
    }
    private static func fetchDirect(_ text: String) async throws -> (SubscriptionDocument, SubscriptionQuota) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw HarborError.message("请输入有效的 HTTPS 订阅链接。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-fetch-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                do {
                    try PrivateFiles.directory(directory)
                    let body = directory.appendingPathComponent("body"), headers = directory.appendingPathComponent("headers")
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    process.arguments = ["--disable", "--globoff", "--silent", "--noproxy", "*", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "35", "--max-filesize", String(ConfigBuilder.maximumImportBytes), "--user-agent", "clash.meta", "--output", body.path, "--dump-header", headers.path, "--config", "-"]
                    let input = Pipe(); process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run()
                    // Credentials pass through stdin only, never argv, logs, environment, or a URL file.
                    let escaped = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    try input.fileHandleForWriting.write(contentsOf: Data(("url = \"" + escaped + "\"\n").utf8)); try input.fileHandleForWriting.close()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw HarborError.message("订阅直连重试失败，已保留原配置。") }
                    let headerText = try String(contentsOf: headers, encoding: .utf8)
                    var fields = [String: String](); var status = 0
                    for line in headerText.components(separatedBy: .newlines) {
                        if line.hasPrefix("HTTP/") { status = Int(line.split(separator: " ").dropFirst().first ?? "0") ?? 0; fields = [:] }
                        else if let split = line.firstIndex(of: ":") { fields[String(line[..<split]).lowercased()] = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    guard status == 200 else { throw HarborError.message("订阅服务器返回 HTTP \(status)，已保留原配置。") }
                    let data = try Data(contentsOf: body)
                    guard data.count <= ConfigBuilder.maximumImportBytes, let payload = String(data: data, encoding: .utf8) else { throw HarborError.message("订阅文件过大或格式无效。") }
                    var quota = SubscriptionQuota.parse(fields["subscription-userinfo"])
                    quota.updateHours = Int(fields["profile-update-interval"] ?? "").map { min(168, max(1, $0)) }
                    continuation.resume(returning: (try ConfigBuilder.parseSubscription(payload), quota))
                } catch let error as HarborError { continuation.resume(throwing: error) }
                  catch let error as ConfigError { continuation.resume(throwing: error) }
                  catch { continuation.resume(throwing: HarborError.message("订阅直连重试失败，原配置已保留。")) }
            }
        }
    }
    private static func fetchAttempt(_ text: String, direct: Bool) async throws -> (SubscriptionDocument, SubscriptionQuota) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw HarborError.message("请输入有效的 HTTPS 订阅链接。") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35; config.urlCache = nil; config.httpCookieStorage = nil
        if direct { config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0] }
        let session = URLSession(configuration: config, delegate: SubscriptionRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("clash.meta", forHTTPHeaderField: "User-Agent"); request.setValue("application/yaml, text/yaml, */*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw HarborError.message("订阅服务器未返回有效响应。") }
            guard http.statusCode == 200 else { throw HarborError.message("订阅服务器返回 HTTP \(http.statusCode)，已保留原配置。") }
            var data = Data()
            for try await byte in bytes { guard data.count < ConfigBuilder.maximumImportBytes else { throw HarborError.message("订阅文件过大，已保留原配置。") }; data.append(byte) }
            guard let text = String(data: data, encoding: .utf8) else { throw HarborError.message("订阅不是 UTF-8 配置文件。") }
            var quota = SubscriptionQuota.parse(http.value(forHTTPHeaderField: "subscription-userinfo"))
            quota.updateHours = Int(http.value(forHTTPHeaderField: "profile-update-interval") ?? "").map { min(168, max(1, $0)) }
            return (try ConfigBuilder.parseSubscription(text), quota)
        } catch let error as HarborError { throw error }
          catch let error as ConfigError { throw error }
          catch { throw HarborError.message("订阅下载失败，请检查网络或稍后重试；原配置已保留。") }
    }
}

public final class CoreSession {
    public let process = Process()
    public let port: Int, controllerPort: Int, secret: String, directory: URL
    private let executable: URL
    private let stopLock = NSLock()
    private var stopping = false
    private let session: URLSession
    public init(executable: URL, directory: URL) throws {
        self.executable = executable; self.directory = directory
        port = try Self.freePort(); var second = try Self.freePort(); while second == port { second = try Self.freePort() }; controllerPort = second
        secret = UUID().uuidString + UUID().uuidString
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }
    public static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw HarborError.message("无法创建本机端口。") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard status == 0 else { throw HarborError.message("无法分配本机端口。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    public func configuration(_ document: SubscriptionDocument, mode: RoutingMode, rules: [String], selected: String? = nil, ruleOverride: [String]? = nil) throws -> String {
        let text = try ConfigBuilder.build(subscription: document, mode: mode, customRules: rules, port: port, controllerPort: controllerPort, secret: secret, ruleOverride: ruleOverride)
        guard let selected, document.names.contains(selected), var object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], var groups = object["proxy-groups"] as? [[String: Any]] else { return text }
        groups[0]["proxies"] = [selected] + document.names.filter { $0 != selected }; object["proxy-groups"] = groups
        return String(data: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
    }
    public func start(document: SubscriptionDocument, mode: RoutingMode, rules: [String], ruleOverride: [String]? = nil) async throws {
        let file = directory.appendingPathComponent("config.yaml")
        try PrivateFiles.write(Data(try configuration(document, mode: mode, rules: rules, ruleOverride: ruleOverride).utf8), to: file)
        let check = Process(); check.executableURL = executable; check.arguments = ["-t", "-d", directory.path, "-f", file.path]; check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        try check.run(); check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw HarborError.message("内核校验未通过，已保留原配置。") }
        process.executableURL = executable; process.arguments = ["-d", directory.path, "-f", file.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            for _ in 0..<50 {
                guard process.isRunning else { throw HarborError.message("内核启动失败或本机端口已被占用。") }
                if (try? await request("/version")) != nil { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw HarborError.message("内核未能就绪。")
        } catch { stop(); throw error }
    }
    public func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(controllerPort)\(path)") else { throw HarborError.message("本机控制请求无效。") }
        var request = URLRequest(url: url); request.httpMethod = method; request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        // A local controller can briefly rebind while applying a configuration.
        // Retry reads only; never replay configuration mutations or swallow cancellation.
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw HarborError.message("内核未能完成请求。") }
                return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
            } catch let error as URLError where method == "GET" && attempt < 2 && [.cannotConnectToHost, .networkConnectionLost].contains(error.code) {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 100_000_000)
            }
        }
        throw HarborError.message("本机控制接口暂时不可用。")
    }
    public func select(_ name: String) async throws { _ = try await request("/proxies/SELECT", method: "PUT", body: ["name": name]) }
    public func delay(_ name: String) async -> String {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let started = Date()
        do {
            let object = try await request("/proxies/\(escaped)/delay?timeout=6000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&expected=204")
            if let delay = object["delay"] as? Int, delay >= 0 { return "\(delay) ms" }
            return "失败"
        } catch { return Date().timeIntervalSince(started) >= 5.8 ? "超时" : "失败" }
    }
    private func beginStop() -> Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        guard !stopping else { return false }; stopping = true
        session.invalidateAndCancel()
        if process.isRunning { process.terminate() }
        return true
    }
    private func finishStop() {
        if process.isRunning {
            for _ in 0..<30 { if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }
    public func stop() { guard beginStop() else { return }; finishStop() }
    public func requestStop() {
        guard beginStop() else { return }
        DispatchQueue.global(qos: .utility).async { self.finishStop() }
    }
    public func stopAsync() async { await withCheckedContinuation { continuation in DispatchQueue.global(qos: .utility).async { self.stop(); continuation.resume() } } }

}
