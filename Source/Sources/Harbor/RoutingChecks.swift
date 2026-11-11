import Foundation
import Darwin
import HarborCore

/// Exercises an isolated core. It never changes macOS networking or another controller.
enum RoutingChecks {
    private static let upstream = "E2E_LOCAL_UPSTREAM"
    private static let allowedChains: Set<String> = ["DIRECT", "SELECT", upstream, "E2E_UNUSED"]
    private static let targets = ["chatgpt.com", "claude.ai", "gemini.google.com", "apple.com", "example.com"]

    static func run(executable: URL, sample: SubscriptionDocument? = nil) async throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-routing-" + UUID().uuidString)
        try PrivateFiles.directory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try CoreSession(executable: executable, directory: directory)
        defer { core.stop() }
        // A second node makes preservation of a non-default selection observable.
        let unusedPort = try CoreSession.freePort()
        var document = try ConfigBuilder.parseSubscription("""
        proxies:
          - {name: E2E_UNUSED, type: http, server: 127.0.0.1, port: \(unusedPort)}
          - {name: E2E_LOCAL_UPSTREAM, type: http, server: 127.0.0.1, port: 7897}
        """)
        if let sample, let list = try JSONSerialization.jsonObject(with: sample.nodesJSON) as? [[String: Any]], var node = list.first {
            node["name"] = upstream
            var payload: [String:Any] = ["proxies": [["name":"E2E_UNUSED","type":"http","server":"127.0.0.1","port":unusedPort],node]]
            if let resolvers = sample.proxyServerDNS { payload["dns"] = ["proxy-server-nameserver":resolvers] }
            document = try ConfigBuilder.parseSubscription(String(data: JSONSerialization.data(withJSONObject:payload,options:[.withoutEscapingSlashes]),encoding:.utf8)!)
        }
        try await core.start(document: document, mode: .rule, rules: [])
        try await core.select(upstream)
        var selections = [[String: Any]]()
        selections.append(try await selection(core, stage: "initial-rule"))
        let ruleResults = await checkTargets(core, mode: .rule)
        var globalChecks = [[String: Any]]()
        for (mode, stage) in [(RoutingMode.global, "reload-global"), (.rule, "reload-rule")] {
            let config = try core.configuration(document, mode: mode, rules: [], selected: upstream)
            _ = try await core.request("/configs?force=true", method: "PUT", body: ["payload": config])
            selections.append(try await selection(core, stage: stage))
            if mode == .global {
                let globalResults = await checkTargets(core, mode: mode)
                // Keep results in a private local value until all mode changes are complete.
                globalChecks = globalResults
            }
        }
        let results = ruleResults + globalChecks
        let routingPassed = results.allSatisfy { $0["routingPassed"] as? Bool == true }
        let selectionPassed = selections.allSatisfy { $0["passed"] as? Bool == true }
        let transportProofPassed = results.allSatisfy { ($0["https"] as? [String: Any])?["coreTrafficObserved"] as? Bool == true }
        let availabilityPassed = results.allSatisfy { ($0["https"] as? [String: Any])?["available"] as? Bool == true }
        return ["status": routingPassed && selectionPassed && availabilityPassed && transportProofPassed ? "pass" : "fail",
                "routingPassed": routingPassed, "selectionPreserved": selectionPassed,
                "availabilityPassed": availabilityPassed, "httpsTrafficProofPassed": transportProofPassed, "upstream": sample == nil ? "existing loopback relay" : "isolated real subscription node",
                "scope": "isolated core; explicit proxy requests; existing upstream selection unchanged",
                "httpsScope": "initial HTTPS response only; redirects not followed; page content capped at 65536 bytes",
                "selectionChecks": selections, "checks": results]
    }

    private static func selection(_ core: CoreSession, stage: String) async throws -> [String: Any] {
        let group = try await core.request("/proxies/SELECT")
        let selected = group["now"] as? String ?? ""
        let members = group["all"] as? [String] ?? []
        return ["stage": stage, "selected": allowedChains.contains(selected) ? selected : "[unexpected]",
                "passed": selected == upstream && !members.isEmpty && !members.contains("DIRECT")]
    }

    private static func checkTargets(_ core: CoreSession, mode: RoutingMode) async -> [[String: Any]] {
        await withTaskGroup(of: [String: Any].self) { group in
            for host in targets { group.addTask { await check(core, host: host, mode: mode) } }
            var results = [[String: Any]]()
            for await result in group { results.append(result) }
            return results.sorted { ($0["host"] as? String ?? "") < ($1["host"] as? String ?? "") }
        }
    }

    private static func check(_ core: CoreSession, host: String, mode: RoutingMode) async -> [String: Any] {
        var result: [String: Any] = ["host": host, "mode": mode.rawValue, "routingPassed": false]
        do {
            let tunnel = try Tunnel(port: core.port, host: host)
            defer { tunnel.closeSocket() }
            var evidence: [String: Any]?
            // Sample immediately, including while an upstream CONNECT is still pending.
            for _ in 0..<40 {
                if let current = try await connection(core, host: host, sourcePort: tunnel.sourcePort) {
                    evidence = current
                    if current["chains"] as? [String] != [] { break }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            result["connectResponse"] = tunnel.responseStatus()
            if let evidence {
                result["connection"] = evidence
                let chains = evidence["chains"] as? [String] ?? []
                let proxyExpected = mode == .global || !["apple.com", "example.com"].contains(host)
                let expectedPayload = mode == .global || host == "example.com" ? "" : host == "gemini.google.com" ? "google.com" : host
                let expectedRule = expectedPayload.isEmpty ? "Match" : "DomainSuffix"
                let chainPassed = proxyExpected ? chains.contains(upstream) && chains.contains("SELECT") && !chains.contains("DIRECT") : chains == ["DIRECT"]
                result["expectedPolicy"] = proxyExpected ? "SELECT" : "DIRECT"
                result["routingPassed"] = chainPassed && evidence["rule"] as? String == expectedRule && evidence["rulePayload"] as? String == expectedPayload
            } else { result["routingFailure"] = "No matching live connection observed within 2 seconds" }
        } catch { result["routingFailure"] = "Local CONNECT or controller request failed" }
        result["https"] = await https(core, host: host)
        return result
    }

    private static func connection(_ core: CoreSession, host: String, sourcePort: Int?) async throws -> [String: Any]? {
        let response = try await core.request("/connections")
        let records = response["connections"] as? [[String: Any]] ?? []
        guard let record = records.first(where: { record in
            guard let metadata = record["metadata"] as? [String: Any], metadata["host"] as? String == host else { return false }
            guard let sourcePort else { return true }
            return String(describing: metadata["sourcePort"] ?? "") == String(sourcePort)
        }) else { return nil }
        let payload = record["rulePayload"] as? String ?? ""
        let safePayloads = Set(targets + ["google.com", ""])
        return ["chains": (record["chains"] as? [String] ?? []).map { allowedChains.contains($0) ? $0 : "[unexpected]" },
                "rule": ["Match", "DomainSuffix", "Domain", "IPCIDR", "IPCIDR6"].contains(record["rule"] as? String ?? "") ? record["rule"] as! String : "[unexpected]",
                "rulePayload": safePayloads.contains(payload) ? payload : "[unexpected]",
                "upload": record["upload"] as? Int ?? 0, "download": record["download"] as? Int ?? 0]
    }

    private static func https(_ core: CoreSession, host: String) async -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": core.port,
                                                   "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": core.port,
                                                   "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
                                                   "ExceptionsList": [String](), "ExcludeSimpleHostnames": 0]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let probe = Task<[String: Any], Never> {
            do {
                let (bytes, response) = try await session.bytes(from: URL(string: "https://\(host)/")!)
                var received = 0
                for try await _ in bytes { received += 1; if received >= 65536 { break } }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ["httpStatus": status, "receivedBytes": received, "available": (200..<400).contains(status), "responseObserved": status > 0, "redirectObserved": (300..<400).contains(status),
                        "pageContentObserved": (200..<300).contains(status) && received > 0]
            } catch {
                return ["available": false, "responseObserved": false, "errorCode": (error as NSError).code]
            }
        }
        var traffic: [String: Any]?
        for _ in 0..<120 {
            if let observed = try? await connection(core, host: host, sourcePort: nil) {
                if traffic == nil || (observed["download"] as? Int ?? 0) > (traffic?["download"] as? Int ?? 0) { traffic = observed }
            }
            if probe.isCancelled { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var result = await probe.value
        result["connection"] = traffic ?? [:]
        result["coreTrafficObserved"] = (traffic?["download"] as? Int ?? 0) > 0 || (traffic?["upload"] as? Int ?? 0) > 0
        return result
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private final class Tunnel {
        private var descriptor: Int32
        let sourcePort: Int?
        init(port: Int, host: String) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HarborError.message("CONNECT socket failed") }
            descriptor = fd
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { Darwin.close(fd); descriptor = -1; throw HarborError.message("CONNECT failed") }
            var local = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            sourcePort = found == 0 ? Int(UInt16(bigEndian: local.sin_port)) : nil
            let request = Array("CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n".utf8)
            let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard sent == request.count else { Darwin.close(fd); descriptor = -1; throw HarborError.message("CONNECT send failed") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        }
        func responseStatus() -> String {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            guard count > 0, let line = String(bytes: bytes.prefix(count), encoding: .utf8)?.components(separatedBy: "\r\n").first else { return "pending-or-closed" }
            let parts = line.split(separator: " ")
            return parts.count > 1 && Int(parts[1]) != nil ? String(parts[1]) : "unrecognized"
        }
        func closeSocket() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        deinit { closeSocket() }
    }
}
