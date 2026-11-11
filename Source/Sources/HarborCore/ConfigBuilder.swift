import Foundation
import CoreFoundation
import Darwin
import Yams

public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case rule, global
    public var title: String { self == .rule ? "规则" : "全局" }
}

/// Contains credentials. Store only in a private application directory, never log.
public struct SubscriptionDocument: Codable, Equatable, Sendable {
    public let names: [String]
    public let nodesJSON: Data
    public let proxyServerDNS: [String]?
    public var count: Int { names.count }
    fileprivate init(names: [String], nodesJSON: Data, proxyServerDNS: [String]? = nil) {
        self.names = names
        self.nodesJSON = nodesJSON
        self.proxyServerDNS = proxyServerDNS
    }
}

public enum ConfigError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let description) = self { return description }
        return nil
    }
}

public enum ConfigBuilder {
    public static let groupName = "SELECT"
    public static let maximumImportBytes = 4 * 1024 * 1024
    private static let supportedTypes: Set<String> = [
        "ss", "ssr", "vmess", "vless", "trojan", "socks5", "http", "snell",
        "hysteria", "hysteria2", "tuic", "anytls"
    ]
    private static let reservedNames: Set<String> = [
        "SELECT", "GLOBAL", "DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE",
        "COMPATIBLE", "DNS"
    ]

    /// Imports outbound nodes and HTTPS DNS endpoints for resolving their server hostnames.
    public static func parseSubscription(_ text: String) throws -> SubscriptionDocument {
        let value = try parseYAML(text)
        guard let root = value as? [String: Any], let proxies = root["proxies"] as? [[String: Any]], !proxies.isEmpty else {
            throw ConfigError.invalid("请选择含 proxies 节点列表的 Clash / Mihomo YAML 订阅；暂不支持通用 Base64 链接或仅含远程 provider 的配置。")
        }
        guard proxies.count <= 1000 else { throw ConfigError.invalid("节点超过 1000 个，请使用精简订阅。") }
        var names = [String]()
        var seen = Set<String>()
        for (index, node) in proxies.enumerated() {
            let prefix = "第 \(index + 1) 个节点"
            guard let name = node["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 200,
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !reservedNames.contains(name.uppercased()), seen.insert(name).inserted else {
                throw ConfigError.invalid("\(prefix)名称为空、重复、过长或与内置策略冲突。")
            }
            guard let type = node["type"] as? String, supportedTypes.contains(type) else {
                throw ConfigError.invalid("\(prefix)的协议暂不支持。支持常用 SS、VMess、VLESS、Trojan、Hysteria、TUIC、AnyTLS、HTTP 与 SOCKS。")
            }
            guard let server = node["server"] as? String, !server.isEmpty, server.utf8.count <= 253,
                  server.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  let port = integer(node["port"]), (1...65535).contains(port) else {
                throw ConfigError.invalid("\(prefix)缺少有效的服务器地址或端口。")
            }
            // Chained proxies and explicit interface selection can route outside the user's policy.
            let forbiddenTopLevel = ["dialer-proxy", "interface-name", "routing-mark"]
            guard !forbiddenTopLevel.contains(where: { node[$0] != nil }) else {
                throw ConfigError.invalid("\(prefix)包含链式代理或网卡绑定设置；第一版不支持。")
            }
            try rejectLocalFileOptions(node)
            names.append(name)
        }
        guard JSONSerialization.isValidJSONObject(proxies) else {
            throw ConfigError.invalid("节点包含无法保存的 YAML 数据类型。")
        }
        let data = try JSONSerialization.data(withJSONObject: proxies, options: [.sortedKeys])
        let dns = root["dns"] as? [String: Any]
        // An explicit node resolver takes precedence, even when its entries are unsupported.
        let source = dns?["proxy-server-nameserver"] ?? dns?["nameserver"]
        let proxyServerDNS = Array(((source as? [String]) ?? [])
            .filter(validProviderDNS).prefix(8))
        return SubscriptionDocument(names: names, nodesJSON: data,
                                    proxyServerDNS: proxyServerDNS.isEmpty ? nil : proxyServerDNS)
    }

    /// Accepts `rules:`, classical `payload:`, a YAML list, or one rule per line.
    /// Deliberately excludes executable, process, remote-provider and catch-all proxy rules.
    public static func parseRules(_ text: String) throws -> [String] {
        let object = try parseYAML(text)
        let lines: [String]
        if let root = object as? [String: Any] {
            guard let values = (root["rules"] ?? root["payload"]) as? [String] else {
                throw ConfigError.invalid("规则文件需要 rules 或 payload 列表。")
            }
            lines = values
        } else if let values = object as? [String] {
            lines = values
        } else if object is String {
            lines = text.components(separatedBy: .newlines)
        } else {
            throw ConfigError.invalid("无法识别规则文件。")
        }
        guard lines.count <= 10000 else { throw ConfigError.invalid("规则超过 10000 条，请使用精简规则文件。") }
        var result = [String]()
        var seen = Set<String>()
        for (index, line) in lines.enumerated() {
            let rule = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if rule.isEmpty || rule.hasPrefix("#") { continue }
            let parts = rule.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts == ["MATCH", "DIRECT"] { continue }
            let normalized = try normalizedRule(parts, line: index + 1, editable: false)
            if seen.insert(normalized).inserted { result.append(normalized) }
        }
        guard !result.isEmpty else { throw ConfigError.invalid("规则文件没有可导入的域名或 IP 规则。") }
        return result
    }

    /// Edits the entire ordered routing table. A single terminal MATCH is required.
    public static func parseEditableRules(_ text: String) throws -> [String] {
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let forbidden = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t\r"))
            guard line.rangeOfCharacter(from: forbidden) == nil else {
                throw ConfigError.invalid("第 \(index + 1) 行含不支持的控制字符。")
            }
        }
        let node = try parseYAMLNode(text)
        let rows: [(String, Int)]
        switch node {
        case .mapping(let mapping):
            if let entry = mapping.first(where: { !["rules", "payload"].contains($0.key.string ?? "") }) {
                throw ConfigError.invalid("第 \(entry.key.mark?.line ?? 1) 行只能包含 rules 或 payload 规则列表；请勿加入 DNS、节点或其他配置。")
            }
            guard mapping.count == 1, let entry = mapping.first else {
                throw ConfigError.invalid("第 \(node.mark?.line ?? 1) 行需要一个 rules 或 payload 规则列表。")
            }
            rows = try editableRows(entry.value)
        case .sequence:
            rows = try editableRows(node)
        case .scalar:
            rows = text.components(separatedBy: "\n").enumerated().map { ($0.element, $0.offset + 1) }
        default:
            throw ConfigError.invalid("第 \(node.mark?.line ?? 1) 行需要规则列表。")
        }
        let nonempty = rows.filter {
            let value = $0.0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !value.hasPrefix("#")
        }
        guard nonempty.count <= 10000 else { throw ConfigError.invalid("规则超过 10000 条，请使用精简规则文件。") }
        var result = [String]()
        for (index, row) in nonempty.enumerated() {
            let parts = row.0.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let normalized = try normalizedRule(parts, line: row.1, editable: true)
            if parts.first == "MATCH", index != nonempty.count - 1 {
                throw ConfigError.invalid("第 \(row.1) 行的 MATCH 必须是唯一且最后一条规则。")
            }
            result.append(normalized)
        }
        guard result.last?.hasPrefix("MATCH,") == true else {
            throw ConfigError.invalid("第 \(nonempty.last?.1 ?? 1) 行后缺少最终 MATCH 规则，请在末尾添加 MATCH,DIRECT 或 MATCH,SELECT。")
        }
        return result
    }

    /// Only routing strings are emitted. Node credentials and listener settings are excluded.
    public static func editableRulesText(_ rules: [String]) -> String {
        // JSON string quoting is valid YAML and preserves every rule's exact contents.
        let lines = rules.map { rule -> String in
            let data = try! JSONSerialization.data(withJSONObject: rule, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return "  - " + String(decoding: data, as: UTF8.self)
        }
        return lines.isEmpty ? "rules: []\n" : "rules:\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func editableRows(_ node: Node) throws -> [(String, Int)] {
        guard case .sequence(let sequence) = node else {
            throw ConfigError.invalid("第 \(node.mark?.line ?? 1) 行需要 YAML 规则列表。")
        }
        return try sequence.map { item in
            guard case .scalar = item, let value = item.string else {
                throw ConfigError.invalid("第 \(item.mark?.line ?? 1) 行的规则必须是文本。")
            }
            guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ConfigError.invalid("第 \(item.mark?.line ?? 1) 行的规则含不支持的控制字符。")
            }
            return (value, item.mark?.line ?? 1)
        }
    }

    private static func normalizedRule(_ parts: [String], line: Int, editable: Bool) throws -> String {
        let prefix = "第 \(line) 行"
        guard parts.allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw ConfigError.invalid("\(prefix)的规则含不支持的控制字符。")
        }
        let targets = editable ? ["DIRECT", "SELECT", "PROXY", "REJECT"] : ["DIRECT", "SELECT", "PROXY"]
        if editable, parts.first == "MATCH" {
            guard parts.count == 2, targets.contains(parts[1]) else {
                throw ConfigError.invalid("\(prefix)的 MATCH 格式应为 MATCH,目标，目标支持 DIRECT、SELECT、PROXY 或 REJECT。")
            }
            return "MATCH," + (parts[1] == "PROXY" ? groupName : parts[1])
        }
        let types = editable ? ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6"] : ["DOMAIN", "DOMAIN-SUFFIX", "IP-CIDR", "IP-CIDR6"]
        guard (3...4).contains(parts.count), types.contains(parts[0]) else {
            throw ConfigError.invalid("\(prefix)的规则类型或字段数量不支持。支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6 及末尾 MATCH。")
        }
        guard targets.contains(parts[2]) else {
            throw ConfigError.invalid("\(prefix)的规则目标不支持，请使用 DIRECT、SELECT、PROXY 或 REJECT。")
        }
        let target = parts[2] == "PROXY" ? groupName : parts[2]
        if parts[0].hasPrefix("IP-") {
            guard validCIDR(parts[1], ipv6: parts[0] == "IP-CIDR6"),
                  parts.count == 3 || parts[3] == "no-resolve" else {
                throw ConfigError.invalid("\(prefix)的 IP 地址、掩码或选项无效；仅支持 no-resolve。")
            }
            let option = !editable || parts.count == 4 ? ",no-resolve" : ""
            return "\(parts[0]),\(parts[1]),\(target)\(option)"
        }
        let domain = editable ? parts[1].lowercased() : parts[1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let valid: Bool
        if parts[0] == "DOMAIN-KEYWORD" {
            valid = !domain.isEmpty && domain.utf8.count <= 253
                && domain.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
        } else {
            valid = validDomain(domain) || (editable && validDomain(domain + ".local") && !domain.contains("."))
        }
        guard parts.count == 3, valid else {
            throw ConfigError.invalid("\(prefix)的域名或关键词无效；请使用域名文本，不含 URL、空格或通配符。")
        }
        return "\(parts[0]),\(domain),\(target)"
    }

    /// Explicit migration of node resolution only; leaves node credentials and ordering unchanged.
    public static func withNodeDNS(document: SubscriptionDocument, reference: SubscriptionDocument) throws -> SubscriptionDocument {
        guard let resolvers = reference.proxyServerDNS, !resolvers.isEmpty, resolvers.count <= 8, resolvers.allSatisfy(validProviderDNS) else {
            throw ConfigError.invalid("参考配置没有可用的节点专用 DNS。")
        }
        return SubscriptionDocument(names: document.names, nodesJSON: document.nodesJSON, proxyServerDNS: resolvers)
    }

    public static func build(subscription: SubscriptionDocument, mode: RoutingMode,
                             customRules: [String] = [], port: Int, controllerPort: Int,
                             secret: String, ruleOverride: [String]? = nil) throws -> String {
        guard (1024...65535).contains(port), (1024...65535).contains(controllerPort),
              port != controllerPort, secret.utf8.count >= 24 else {
            throw ConfigError.invalid("本机端口或控制密钥无效。")
        }
        guard let nodes = try JSONSerialization.jsonObject(with: subscription.nodesJSON) as? [[String: Any]] else {
            throw ConfigError.invalid("已保存的节点配置损坏，请重新导入。")
        }
        // Revalidate decoded persisted data, rather than trusting Codable as an input boundary.
        let checked = try parseSubscription(Yams.dump(object: ["proxies": nodes]))
        guard checked.names == subscription.names else { throw ConfigError.invalid("节点索引损坏，请重新导入。") }
        let proxyServerDNS = subscription.proxyServerDNS ?? []
        guard proxyServerDNS.count <= 8, proxyServerDNS.allSatisfy(validProviderDNS) else {
            throw ConfigError.invalid("已保存的节点 DNS 配置损坏，请重新导入。")
        }
        var dns: [String: Any] = ["enable": false]
        if !proxyServerDNS.isEmpty {
            // Internal node resolution works without opening a DNS listener or changing system DNS.
            dns = [
                "enable": true, "listen": "", "enhanced-mode": "redir-host",
                "default-nameserver": ["system"], "nameserver": ["system"],
                "direct-nameserver": ["system"], "direct-nameserver-follow-policy": false,
                "respect-rules": false, "proxy-server-nameserver": proxyServerDNS
            ]
        }
        let checkedRules = ruleOverride != nil || customRules.isEmpty ? [] : try parseRules(Yams.dump(object: ["rules": customRules]))
        let checkedOverride = try ruleOverride.map { try parseEditableRules(editableRulesText($0)) }
        let effectiveRules = mode == .rule ? (checkedOverride ?? rules(mode: mode, customRules: checkedRules)) : rules(mode: mode)
        let config: [String: Any] = [
            "mixed-port": port, "allow-lan": false, "bind-address": "127.0.0.1",
            "mode": "rule", "log-level": "silent", "ipv6": true,
            "external-controller": "127.0.0.1:\(controllerPort)", "secret": secret,
            "external-controller-cors": ["allow-origins": [String](), "allow-private-network": false],
            "profile": ["store-selected": false, "store-fake-ip": false],
            "dns": dns, "tun": ["enable": false],
            "find-process-mode": "off", "proxies": nodes,
            "proxy-groups": [["name": groupName, "type": "select", "proxies": subscription.names]],
            "rules": effectiveRules
        ]
        // JSON is a YAML subset; preserves Foundation Boolean versus numeric identity.
        return String(data: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
    }

    public static func rules(mode: RoutingMode, customRules: [String] = []) -> [String] {
        if mode == .global { return localRules + ["MATCH,\(groupName)"] }
        // Required service routes stay on one egress even if imported rules request DIRECT.
        return localRules + appleRules + serviceRules + customRules + ["MATCH,DIRECT"]
    }

    public static let localRules: [String] = [
        "DOMAIN,localhost,DIRECT", "DOMAIN-SUFFIX,local,DIRECT", "DOMAIN-SUFFIX,lan,DIRECT",
        "IP-CIDR,0.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,224.0.0.0/4,DIRECT,no-resolve", "IP-CIDR,255.255.255.255/32,DIRECT,no-resolve",
        "IP-CIDR6,::1/128,DIRECT,no-resolve", "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
        "IP-CIDR6,fe80::/10,DIRECT,no-resolve", "IP-CIDR6,ff00::/8,DIRECT,no-resolve"
    ]

    public static let appleDomains = [
        "apple.com", "apple.com.cn", "icloud.com", "icloud.com.cn", "icloud-content.com",
        "cdn-apple.com", "aaplimg.com", "mzstatic.com", "me.com", "apple-cloudkit.com",
        "apple-mapkit.com", "apple-dns.net", "apple-livephotoskit.com", "apzones.com"
    ]
    public static let appleSharedHosts = [
        "apple-relay.cloudflare.com", "apple-relay.fastly-edge.com", "cp4.cloudflare.com",
        "app-site-association.networking.apple", "crl3.digicert.com", "crl4.digicert.com",
        "ocsp.digicert.cn", "ocsp.digicert.com"
    ]
    public static var appleRules: [String] {
        appleDomains.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
        + appleSharedHosts.map { "DOMAIN,\($0),DIRECT" }
    }

    // Vendor domains, plus exact shared-provider hosts needed for authentication/challenges.
    // No blanket cloudflare.com, amazonaws.com, akamai.net, azure.com or cloud CDN rule.
    public static let serviceDomains = [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "oaistatsig.com",
        "anthropic.com", "claude.ai", "claude.com", "claude.app", "claudeusercontent.com",
        "claudemcpcontent.com",
        "google.com", "google.com.hk", "google.co.jp", "google.co.uk", "googleapis.com",
        "googleusercontent.com", "gstatic.com", "gmail.com", "googledrive.com", "googlegroups.com",
        "youtube.com", "youtu.be", "ytimg.com", "googlevideo.com", "ggpht.com", "gvt1.com"
    ]
    public static let sharedServiceHosts = [
        "challenges.cloudflare.com", "cdn.openaimerge.com", "cdn.workos.com",
        "forwarder.workos.com", "frontend-apps-multi-region.workos.com", "images.workoscdn.com",
        "setup.workos.com", "workos.imgix.net", "js.stripe.com",
        // OpenAI lists these exact shared hosts for support and operational reports.
        "js.intercomcdn.com", "o207216.ingest.sentry.io", "o33249.ingest.sentry.io",
        "rum.browser-intake-datadoghq.com",
        // Anthropic documents these artifact library origins. Keep shared CDN rules exact.
        "cdnjs.cloudflare.com", "cdn.jsdelivr.net", "cdn.tailwindcss.com", "code.jquery.com", "unpkg.com",
        // Remaining exact hosts in Google Workspace's Gemini allowlist.
        "csp.withgoogle.com", "www.googletagmanager.com", "www.google-analytics.com",
        "static.doubleclick.net", "td.doubleclick.net", "googleads.g.doubleclick.net"
    ]
    public static var serviceRules: [String] {
        serviceDomains.map { "DOMAIN-SUFFIX,\($0),\(groupName)" }
        + sharedServiceHosts.map { "DOMAIN,\($0),\(groupName)" }
    }

    private static func parseYAML(_ text: String) throws -> Any {
        try parseYAMLNode(text).any
    }

    private static func parseYAMLNode(_ text: String) throws -> Node {
        guard !text.isEmpty, text.utf8.count <= maximumImportBytes else {
            throw ConfigError.invalid("文件为空或超过 4 MB。")
        }
        try preflight(text)
        do {
            guard let node = try Yams.compose(yaml: text) else { throw ConfigError.invalid("文件为空。") }
            var budget = 50000
            try inspect(node, depth: 0, budget: &budget)
            return node
        } catch let error as ConfigError { throw error }
        catch let error as YamlError {
            let line: Int
            switch error {
            case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
                line = mark.line
            default: line = 1
            }
            throw ConfigError.invalid("第 \(line) 行的 YAML 格式无效，请检查缩进、引号或列表格式。")
        }
        catch { throw ConfigError.invalid("YAML 格式无效，请检查订阅或规则文件。") }
    }

    // Bound parser recursion before constructing the YAML tree, including alias expansion.
    // Quoted credential contents are never interpreted as YAML syntax here.
    private static func preflight(_ text: String) throws {
        let bytes = Array(text.utf8)
        var quote: UInt8? = nil
        var escaped = false, comment = false, lineStart = true
        var indent = 0, depth = 0, index = 0, line = 1
        while index < bytes.count {
            let c = bytes[index]
            let previous: UInt8 = index > 0 ? bytes[index - 1] : 32
            if c == 10 || c == 13 {
                if c == 10 { line += 1 }
                comment = false; lineStart = true; indent = 0
            }
            if comment { index += 1; continue }
            if let q = quote {
                if escaped { escaped = false }
                else if q == 34 && c == 92 { escaped = true }
                else if c == q {
                    if q == 39 && index + 1 < bytes.count && bytes[index + 1] == 39 { index += 1 }
                    else { quote = nil }
                }
                index += 1; continue
            }
            if lineStart && (c == 32 || c == 9) {
                indent += 1
                if indent > 128 { throw ConfigError.invalid("第 \(line) 行的 YAML 缩进过深。") }
            } else if c != 10 && c != 13 { lineStart = false }
            let boundary = [UInt8(32), 9, 10, 13, 58, 44, 91, 123].contains(previous)
            if c == 35 && boundary { comment = true }
            else if (c == 34 || c == 39) && boundary { quote = c }
            else if (c == 38 || c == 42) && boundary {
                throw ConfigError.invalid("第 \(line) 行暂不支持 YAML 锚点与别名，请导出展开后的配置。")
            } else if c == 91 || c == 123 {
                depth += 1
                if depth > 64 { throw ConfigError.invalid("第 \(line) 行的 YAML 嵌套过深。") }
            } else if c == 93 || c == 125 { depth = max(0, depth - 1) }
            index += 1
        }
    }

    private static func inspect(_ node: Node, depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth <= 24, budget >= 0 else { throw ConfigError.invalid("YAML 结构过于复杂。") }
        switch node {
        case .scalar: break
        case .sequence(let items):
            for item in items { try inspect(item, depth: depth + 1, budget: &budget) }
        case .mapping(let items):
            var keys = Set<String>()
            for (key, value) in items {
                guard let string = key.string, string != "<<", keys.insert(string).inserted else {
                    throw ConfigError.invalid("第 \(key.mark?.line ?? 1) 行的 YAML 包含重复键、非文本键或合并键。")
                }
                try inspect(value, depth: depth + 1, budget: &budget)
            }
        default: throw ConfigError.invalid("暂不支持 YAML 别名，请导出展开后的配置。")
        }
    }

    private static func rejectLocalFileOptions(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let lower = key.lowercased()
                if ["certificate", "private-key", "ca", "ca-str", "client-cert", "client-key"].contains(lower)
                    || lower.hasSuffix("-path") || lower.hasSuffix("-file") {
                    throw ConfigError.invalid("节点包含本地证书或文件引用；第一版不支持这类订阅。")
                }
                try rejectLocalFileOptions(child)
            }
        } else if let items = value as? [Any] {
            for item in items { try rejectLocalFileOptions(item) }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
           value.doubleValue.rounded() == value.doubleValue { return value.intValue }
        return nil
    }

    private static func validProviderDNS(_ value: String) -> Bool {
        guard value.utf8.count <= 2048,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URLComponents(string: value), url.scheme == "https",
              url.url != nil, url.string == value,
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              (1...65535).contains(url.port ?? 443) else { return false }
        if url.rangeOfPort != nil && url.port == nil { return false }
        if validDomain(host.lowercased()) { return true }
        var address = in6_addr()
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return literal.withCString { inet_pton(AF_INET, $0, &address) == 1 || inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func validDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.utf8.count <= 253, domain.contains(".") else { return false }
        return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private static func validCIDR(_ cidr: String, ipv6: Bool) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let prefix = Int(parts[1]), String(prefix) == parts[1], (0...(ipv6 ? 128 : 32)).contains(prefix) else { return false }
        var storage = in6_addr()
        return String(parts[0]).withCString { inet_pton(ipv6 ? AF_INET6 : AF_INET, $0, &storage) } == 1
    }
}
