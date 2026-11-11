import Foundation
import HarborCore
import Darwin

enum HarborCommandLine {
    static func handle() -> Bool {
        if let code = SystemProxyGuard.runIfRequested() { exit(code) }
        if let index = CommandLine.arguments.firstIndex(of:"--functional-check"), CommandLine.arguments.count > index+1, let port = Int(CommandLine.arguments[index+1]) {
            Task { @MainActor in
                do { let model = AppModel(); let result = try await model.runFunctionalCheck(upstreamPort:port); FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])); print(""); exit(0) }
                catch { print("Isolated functional check failed: " + ((error as? HarborError)?.localizedDescription ?? (error as? ConfigError)?.localizedDescription ?? String(describing:type(of:error)))); exit(1) }
            }
            RunLoop.main.run(); return true
        }
        if CommandLine.arguments.contains("--routing-check") {
            Task { @MainActor in
                do {
                    var sample: SubscriptionDocument? = nil
                    if let at = CommandLine.arguments.firstIndex(of: "--node-file"), CommandLine.arguments.count > at + 1 {
                        sample = try ConfigBuilder.parseSubscription(String(contentsOfFile: CommandLine.arguments[at+1], encoding: .utf8))
                    }
                    let result = try await RoutingChecks.run(executable: AppModel.coreExecutable, sample: sample)
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])); print(""); exit(0)
                } catch { print("Routing verification failed"); exit(1) }
            }
            RunLoop.main.run(); return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--fetch-link-file"), CommandLine.arguments.count > index+1 {
            Task { @MainActor in
                do {
                    let value = try String(contentsOfFile: CommandLine.arguments[index+1], encoding: .utf8)
                    let (doc, quota) = try await SubscriptionClient.fetch(value)
                    print("Subscription fetched: \(doc.count) nodes, quota present: \(quota.used != nil), interval: \(quota.updateHours ?? 24)h")
                    exit(0)
                } catch { print((error as? HarborError)?.localizedDescription ?? (error as? ConfigError)?.localizedDescription ?? "Fetch failed"); exit(1) }
            }
            RunLoop.main.run(); return true
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--verify"), CommandLine.arguments.count > index+1 else { return false }
        let source = URL(fileURLWithPath: CommandLine.arguments[index+1])
        Task { @MainActor in
            do {
                let document = try ConfigBuilder.parseSubscription(String(contentsOf: source, encoding: .utf8))
                let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("harbor-verify-" + UUID().uuidString)
                let core = try CoreSession(executable: AppModel.coreExecutable, directory: root)
                defer { core.stop() }
                try await core.start(document: document, mode: .rule, rules: [])
                var checks: [String: Any] = ["nodes": document.count, "core": try await core.request("/version"), "loopbackPort": core.port]
                let values = try await core.request("/rules"); checks["ruleCount"] = (values["rules"] as? [Any])?.count ?? 0
                var measurements = [String: String]()
                let indices = CommandLine.arguments.contains("--all-nodes") ? Array(document.names.indices) : [0,3,10,25,50,75,100,150].filter { $0 < document.count }
                for start in stride(from: 0, to: indices.count, by: 6) {
                    let results = await withTaskGroup(of: (Int,String).self, returning: [(Int,String)].self) { group in
                        for index in indices[start..<min(start+6, indices.count)] { group.addTask { (index, await core.delay(document.names[index])) } }
                        var result = [(Int,String)](); for await value in group { result.append(value) }; return result
                    }
                    for (index, value) in results { measurements[String(index)] = value }
                }
                checks["nodeHTTPS"] = measurements
                if let best = measurements.filter({ $0.value.hasSuffix(" ms") }).min(by: { (Int($0.value.split(separator: " ")[0]) ?? 99999) < (Int($1.value.split(separator: " ")[0]) ?? 99999) }), let index = Int(best.key) {
                    try await core.select(document.names[index]); checks["selectedIndex"] = index
                    let config = URLSessionConfiguration.ephemeral
                    config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": core.port, "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": core.port]
                    config.timeoutIntervalForRequest = 15
                    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
                    var services = [String: Any]()
                    for (title,url) in [("ChatGPT","https://chatgpt.com/"),("Claude","https://claude.ai/"),("Gemini","https://gemini.google.com/app")] {
                        do { var request = URLRequest(url: URL(string:url)!); request.httpMethod = "HEAD"; let (_,response) = try await session.data(for:request); services[title] = (response as? HTTPURLResponse)?.statusCode ?? 0 }
                        catch { services[title] = "HTTPS failed" }
                    }
                    checks["AI_HTTP_status"] = services
                    let totals = try await core.request("/connections"); checks["downloadBytes"] = totals["downloadTotal"]; checks["uploadBytes"] = totals["uploadTotal"]
                }
                // Controller must reject unauthenticated callers.
                let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
                let session = URLSession(configuration: config)
                let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(core.controllerPort)/version")!)
                checks["unauthorizedStatus"] = (response as? HTTPURLResponse)?.statusCode ?? 0
                checks["systemProxyChanged"] = false
                let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]); FileHandle.standardOutput.write(data); print("")
                core.stop(); exit(0)
            } catch { fputs("Verification failed: \((error as? ConfigError)?.localizedDescription ?? (error as? HarborError)?.localizedDescription ?? String(describing: type(of: error)))\n", stderr); exit(1) }
        }
        RunLoop.main.run(); return true
    }
}
