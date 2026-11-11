import XCTest
import Yams
@testable import HarborCore

final class ProviderDNSTests: XCTestCase {
    private let nodeYAML = """
    proxies:
    - name: Provider node
      type: anytls
      server: node.example.com
      port: 443
      password: test-only
    """

    private func document(_ dns: [String: Any] = [:]) throws -> SubscriptionDocument {
        try ConfigBuilder.parseSubscription(nodeYAML + "\n" + Yams.dump(object: ["dns": dns]))
    }

    private func configuration(_ document: SubscriptionDocument) throws -> [String: Any] {
        let text = try ConfigBuilder.build(subscription: document, mode: .rule,
            port: 18901, controllerPort: 18902, secret: String(repeating: "t", count: 32))
        return try XCTUnwrap(Yams.load(yaml: text) as? [String: Any])
    }

    func testSubscriptionDNSIsPersistedForNodeResolutionOnly() throws {
        let endpoints = ["https://dns.example.com:39933/api-query", "https://backup.example.com/api-query"]
        let imported = try document([
            "nameserver": endpoints, "listen": "0.0.0.0:53", "enhanced-mode": "fake-ip",
            "nameserver-policy": ["apple.com": "https://foreign.example.com/dns-query"],
            "default-nameserver": ["8.8.8.8"], "respect-rules": true
        ])
        let restored = try JSONDecoder().decode(SubscriptionDocument.self, from: JSONEncoder().encode(imported))
        XCTAssertEqual(restored, imported)
        XCTAssertEqual(restored.proxyServerDNS, endpoints)
        let config = try configuration(restored)
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["enable"] as? Bool, true)
        XCTAssertEqual(dns["listen"] as? String, "")
        XCTAssertEqual(dns["enhanced-mode"] as? String, "redir-host")
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], endpoints)
        for key in ["nameserver", "default-nameserver", "direct-nameserver"] {
            XCTAssertEqual(dns[key] as? [String], ["system"])
        }
        XCTAssertEqual(dns["respect-rules"] as? Bool, false)
        XCTAssertEqual(dns["direct-nameserver-follow-policy"] as? Bool, false)
        XCTAssertNil(dns["nameserver-policy"])
        XCTAssertNil(dns["fake-ip-range"])
        XCTAssertNil(config["listeners"])
        XCTAssertEqual((config["tun"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((config["rules"] as? [String])?.last, "MATCH,DIRECT")
    }

    func testExplicitNodeDNSHasPrecedenceOverNameserver() throws {
        let endpoint = "https://node-dns.example.com/dns-query"
        let imported = try document([
            "proxy-server-nameserver": [endpoint],
            "nameserver": ["https://general-dns.example.com/dns-query"]
        ])
        XCTAssertEqual(imported.proxyServerDNS, [endpoint])
        let explicitValues: [Any] = [[String](), ["udp://8.8.8.8"], "system"]
        for explicit in explicitValues {
            let disabled = try document([
                "proxy-server-nameserver": explicit,
                "nameserver": ["https://general-dns.example.com/dns-query"]
            ])
            XCTAssertNil(disabled.proxyServerDNS)
        }
    }

    func testUnsupportedOrMalformedEndpointsAreDiscarded() throws {
        let invalid = [
            "http://dns.example.com/dns-query", "tls://dns.example.com", "system", "8.8.8.8",
            "https://user:password@dns.example.com/dns-query", "https://user@dns.example.com/dns-query",
            "https://dns.example.com/dns-query#DIRECT", "https://dns.example.com/dns-query#",
            "https://dns.example.com:0/query", "https://dns.example.com:65536/query",
            "https:///dns-query", "https://bad_host.example.com/query", "https://dns.example.com/with space",
            "https://dns.example.com/query%", "https://dns.example.com:99999999999999999999999/query",
            "https://dns.example.com/\nquery"
        ]
        let endpoint = "https://dns.example.com:39933/api-query"
        XCTAssertEqual(try document(["nameserver": invalid + [endpoint]]).proxyServerDNS, [endpoint])
        XCTAssertNil(try document(["nameserver": invalid]).proxyServerDNS)
    }

    func testEndpointLimitAndIPLiteralSupport() throws {
        let endpoints = (0..<12).map { "https://dns\($0).example.com/dns-query" }
        XCTAssertEqual(try document(["nameserver": endpoints]).proxyServerDNS, Array(endpoints.prefix(8)))
        let literals = ["https://1.1.1.1/dns-query", "https://[2001:db8::1]:443/dns-query"]
        XCTAssertEqual(try document(["nameserver": literals]).proxyServerDNS, literals)
    }

    func testLegacyDocumentsAndSubscriptionsWithoutSupportedDNSKeepDNSDisabled() throws {
        let imported = try document()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any])
        legacy.removeValue(forKey: "proxyServerDNS")
        let restored = try JSONDecoder().decode(SubscriptionDocument.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.proxyServerDNS)
        let dns = try XCTUnwrap(try configuration(restored)["dns"] as? [String: Any])
        XCTAssertEqual(dns.count, 1)
        XCTAssertEqual(dns["enable"] as? Bool, false)
    }

    func testPersistedDNSEndpointsAreRevalidatedAtBuildBoundary() throws {
        let imported = try document()
        let encoded = try JSONEncoder().encode(imported)
        for endpoints in [["https://user:secret@dns.example.com/query"], Array(repeating: "https://dns.example.com/query", count: 9)] {
            var tampered = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            tampered["proxyServerDNS"] = endpoints
            let restored = try JSONDecoder().decode(SubscriptionDocument.self,
                from: JSONSerialization.data(withJSONObject: tampered))
            XCTAssertThrowsError(try configuration(restored)) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }
}
