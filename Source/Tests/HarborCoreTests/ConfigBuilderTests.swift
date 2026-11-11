import XCTest
import Yams
@testable import HarborCore

final class ConfigBuilderTests: XCTestCase {
    private let nodeYAML = """
    proxies:
      - name: Test node
        type: socks5
        server: 127.0.0.1
        port: 19080
    """
    private func config(_ mode: RoutingMode = .rule, extra: String = "") throws -> [String: Any] {
        let document = try ConfigBuilder.parseSubscription(nodeYAML + "\n" + extra)
        let text = try ConfigBuilder.build(subscription: document, mode: mode,
            port: 18901, controllerPort: 18902, secret: String(repeating: "t", count: 32))
        return try XCTUnwrap(Yams.load(yaml: text) as? [String: Any])
    }

    func testSubscriptionDiscardsAllForeignGlobalSettings() throws {
        let object = try config(extra: """
        rules: [MATCH,REJECT]
        mode: global
        external-controller: 0.0.0.0:9999
        secret: attacker
        allow-lan: true
        listeners: [{name: foreign, type: mixed, port: 9998}]
        dns: {enable: true, listen: '0.0.0.0:53'}
        tun: {enable: true}
        proxy-providers: {untrusted: {type: http, url: 'https://example.com/token'}}
        """)
        XCTAssertEqual(object["mode"] as? String, "rule")
        XCTAssertEqual(object["external-controller"] as? String, "127.0.0.1:18902")
        XCTAssertEqual(object["allow-lan"] as? Bool, false)
        XCTAssertNil(object["listeners"])
        XCTAssertNil(object["proxy-providers"])
        XCTAssertEqual((object["dns"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((object["tun"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((object["rules"] as? [String])?.last, "MATCH,DIRECT")
    }

    func testRoundTripRetainsEscapedNamesAndCredentials() throws {
        let text = """
        proxies:
        - name: '香港 / Test #1'
          type: trojan
          server: proxy.example.com
          port: '443'
          password: 'not-a-real-token:"#&'
        """
        let parsed = try ConfigBuilder.parseSubscription(text)
        let restored = try JSONDecoder().decode(SubscriptionDocument.self, from: JSONEncoder().encode(parsed))
        XCTAssertEqual(parsed, restored)
        let output = try ConfigBuilder.build(subscription: restored, mode: .rule,
            port: 18901, controllerPort: 18902, secret: String(repeating: "s", count: 32))
        let object = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
        let nodes = try XCTUnwrap(object["proxies"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["password"] as? String, "not-a-real-token:\"#&")
        XCTAssertEqual(parsed.names, ["香港 / Test #1"])
    }

    func testRejectsDuplicateAndReservedNames() {
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML + "\n  - {name: Test node, type: socks5, server: localhost, port: 80}"))
        for reserved in ["DIRECT", "SELECT", "GLOBAL", "reject"] {
            XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML.replacingOccurrences(of: "Test node", with: reserved)))
        }
    }

    func testRejectsEmptyProviderOnlyAndUnsupportedFormats() {
        for text in ["proxies: []", "proxy-providers: {}", "c3M6Ly9ub3QtcmVhbA==", "ss://not-real", "<html>error</html>"] {
            XCTAssertThrowsError(try ConfigBuilder.parseSubscription(text))
        }
    }

    func testRejectsLocalFileAndChainedProxyParameters() {
        for parameter in ["certificate: /tmp/test.pem", "private-key: /tmp/key", "ca: /tmp/ca", "dialer-proxy: DIRECT", "interface-name: en0", "routing-mark: 10"] {
            XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML + "\n    " + parameter))
        }
    }

    func testRejectsInvalidPortAndProtocolWithoutLeakingValues() {
        for port in ["0", "65536", "true", "80.5", "secret-value"] {
            XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML.replacingOccurrences(of: "19080", with: port))) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret-value"))
            }
        }
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML.replacingOccurrences(of: "socks5", with: "direct")))
    }

    func testRejectsDuplicateYAMLKeysAndMergeKeys() {
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML + "\nproxies: []"))
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription(nodeYAML + "\n    port: 80"))
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription("a: &a {type: socks5}\nproxies: [{<<: *a, name: Test, server: localhost, port: 80}]"))
    }

    func testRejectsOversizedAndDeepDocuments() {
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription(String(repeating: "x", count: ConfigBuilder.maximumImportBytes + 1)))
        XCTAssertThrowsError(try ConfigBuilder.parseSubscription("x: " + String(repeating: "[", count: 30) + "1" + String(repeating: "]", count: 30)))
    }

    func testProtectedAppleAndLANRulesPrecedeImportedRules() throws {
        let customs = try ConfigBuilder.parseRules("rules: ['DOMAIN-SUFFIX,apple.com,PROXY', 'IP-CIDR,192.168.0.0/16,PROXY']")
        let rules = ConfigBuilder.rules(mode: .rule, customRules: customs)
        XCTAssertLessThan(try XCTUnwrap(rules.firstIndex(of: "DOMAIN-SUFFIX,apple.com,DIRECT")),
                          try XCTUnwrap(rules.firstIndex(of: "DOMAIN-SUFFIX,apple.com,SELECT")))
        XCTAssertLessThan(try XCTUnwrap(rules.firstIndex(of: "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve")),
                          try XCTUnwrap(rules.firstIndex(of: "IP-CIDR,192.168.0.0/16,SELECT,no-resolve")))
        XCTAssertEqual(rules.last, "MATCH,DIRECT")
    }

    func testGlobalProxiesAppleAndOtherExternalTrafficButKeepsLocal() throws {
        let object = try config(.global)
        let rules = try XCTUnwrap(object["rules"] as? [String])
        XCTAssertEqual(rules, ConfigBuilder.localRules + ["MATCH,SELECT"])
        XCTAssertFalse(rules.contains { $0.contains("apple.com") })
        XCTAssertEqual(object["mode"] as? String, "rule")
    }

    func testCustomRulesSupportClassicalYAMLAndPlainText() throws {
        let expected = ["DOMAIN,example.com,SELECT", "IP-CIDR6,2001:db8::/32,DIRECT,no-resolve"]
        XCTAssertEqual(try ConfigBuilder.parseRules("payload: ['DOMAIN,EXAMPLE.COM,PROXY', 'IP-CIDR6,2001:db8::/32,DIRECT', 'MATCH,DIRECT']"), expected)
        XCTAssertEqual(try ConfigBuilder.parseRules("# custom\nDOMAIN,example.com,PROXY\nIP-CIDR6,2001:db8::/32,DIRECT"), expected)
    }

    func testCustomRulesCannotAddRemoteRulesOrChangeDefault() {
        for rule in ["MATCH,PROXY", "RULE-SET,remote,PROXY", "DOMAIN,example.com,Unknown", "IP-CIDR,999.1.1.1/24,DIRECT", "IP-CIDR6,::1/129,DIRECT", "DOMAIN,https://example.com,PROXY", "DOMAIN,example.com,PROXY,no-resolve"] {
            XCTAssertThrowsError(try ConfigBuilder.parseRules(rule))
        }
    }

    func testServiceRulesAvoidBlanketSharedCloudAndKeepAppleDirect() {
        let rules = ConfigBuilder.rules(mode: .rule)
        for domain in ["cloudflare.com", "amazonaws.com", "azure.com", "akamai.net", "workos.com"] {
            XCTAssertFalse(rules.contains("DOMAIN-SUFFIX,\(domain),SELECT"))
        }
        XCTAssertTrue(rules.contains("DOMAIN,challenges.cloudflare.com,SELECT"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,apple.com,DIRECT"))
        XCTAssertFalse(rules.contains("DOMAIN,humb.apple.com,SELECT"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,chatgpt.com,SELECT"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,claude.ai,SELECT"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,googleapis.com,SELECT"))
    }

    func testBuildRejectsInvalidPrivateControllerConfiguration() throws {
        let document = try ConfigBuilder.parseSubscription(nodeYAML)
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: document, mode: .rule, port: 18901, controllerPort: 18901, secret: String(repeating: "s", count: 32)))
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: document, mode: .rule, port: 18901, controllerPort: 18902, secret: "short"))
    }
}
