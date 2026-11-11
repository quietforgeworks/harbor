import XCTest
import Yams
@testable import HarborCore

final class EditableRulesTests: XCTestCase {
    private func document() throws -> SubscriptionDocument {
        try ConfigBuilder.parseSubscription("""
        proxies:
        - name: Test
          type: socks5
          server: localhost
          port: 19080
        """)
    }

    private func build(_ override: [String]?, mode: RoutingMode = .rule) throws -> [String: Any] {
        let text = try ConfigBuilder.build(subscription: document(), mode: mode,
                                           port: 18901, controllerPort: 18902,
                                           secret: String(repeating: "s", count: 32), ruleOverride: override)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testFullDefaultRulesRoundTripIncludingSingleLabelLANRules() throws {
        let defaults = ConfigBuilder.rules(mode: .rule)
        let text = ConfigBuilder.editableRulesText(defaults)
        XCTAssertTrue(text.hasPrefix("rules:\n"))
        XCTAssertEqual(try ConfigBuilder.parseEditableRules(text), defaults)
        XCTAssertEqual(try build(nil)["rules"] as? [String], defaults)
    }

    func testFullTableEditsReplaceDefaultsAndPreserveOrderAndDuplicates() throws {
        let edited = ["DOMAIN-SUFFIX,apple.com,SELECT", "DOMAIN-SUFFIX,chatgpt.com,DIRECT",
                      "DOMAIN,example.com,REJECT", "DOMAIN,example.com,REJECT", "MATCH,SELECT"]
        let object = try build(edited)
        XCTAssertEqual(object["rules"] as? [String], edited)
        XCTAssertEqual(try ConfigBuilder.parseEditableRules(ConfigBuilder.editableRulesText(edited)), edited)
    }

    func testSupportedTypesAndProxyAlias() throws {
        let text = """
        # Ordered full table
        DOMAIN,EXAMPLE.COM,PROXY
        DOMAIN-SUFFIX,example.net,DIRECT
        DOMAIN-KEYWORD,.tracking,REJECT
        IP-CIDR,192.0.2.0/24,PROXY
        IP-CIDR6,2001:db8::/32,DIRECT,no-resolve
        MATCH,PROXY
        """
        XCTAssertEqual(try ConfigBuilder.parseEditableRules(text), [
            "DOMAIN,example.com,SELECT", "DOMAIN-SUFFIX,example.net,DIRECT", "DOMAIN-KEYWORD,.tracking,REJECT",
            "IP-CIDR,192.0.2.0/24,SELECT", "IP-CIDR6,2001:db8::/32,DIRECT,no-resolve", "MATCH,SELECT"
        ])
    }

    func testYAMLListAndPayloadAndCommentLineNumbers() throws {
        XCTAssertEqual(try ConfigBuilder.parseEditableRules("['MATCH,REJECT']"), ["MATCH,REJECT"])
        XCTAssertEqual(try ConfigBuilder.parseEditableRules("payload:\n  - MATCH,DIRECT\n"), ["MATCH,DIRECT"])
        let text = "# full rules\nrules:\n  - DOMAIN,example.com,DIRECT\n  - RULE-SET,private-token,PROXY\n  - MATCH,DIRECT\n"
        XCTAssertThrowsError(try ConfigBuilder.parseEditableRules(text)) { error in
            XCTAssertTrue(error.localizedDescription.contains("第 4 行"))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }

    func testRequiresExactlyOneTerminalMATCH() {
        for text in ["rules: []", "DOMAIN,example.com,DIRECT", "MATCH,DIRECT\nDOMAIN,example.com,PROXY",
                     "MATCH,DIRECT\nMATCH,SELECT", "MATCH,SELECT,no-resolve", "MATCH,unknown"] {
            XCTAssertThrowsError(try ConfigBuilder.parseEditableRules(text), text)
        }
    }

    func testGlobalModeKeepsItsOwnRoutingAndOverrideCanBeReused() throws {
        let edited = ["DOMAIN-SUFFIX,apple.com,SELECT", "MATCH,REJECT"]
        XCTAssertEqual(try build(edited, mode: .global)["rules"] as? [String], ConfigBuilder.localRules + ["MATCH,SELECT"])
        XCTAssertEqual(try build(edited)["rules"] as? [String], edited)
        XCTAssertEqual(try build(nil)["rules"] as? [String], ConfigBuilder.rules(mode: .rule))
    }

    func testInvalidSavedOverrideFailsBeforeBuilding() throws {
        XCTAssertThrowsError(try build(["RULE-SET,remote,SELECT", "MATCH,DIRECT"]))
        XCTAssertThrowsError(try build(["MATCH,SELECT", "DOMAIN,example.com,DIRECT"]))
    }

    func testFullEditDoesNotDependOnLegacyCustomRuleRestrictions() throws {
        let text = try ConfigBuilder.build(subscription: document(), mode: .rule,
                                           customRules: ["invalid legacy data"], port: 18901, controllerPort: 18902,
                                           secret: String(repeating: "s", count: 32), ruleOverride: ["MATCH,REJECT"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["rules"] as? [String], ["MATCH,REJECT"])
    }

    func testRejectsUnsupportedTypesAndMalformedArguments() {
        for row in ["RULE-SET,remote,SELECT", "PROCESS-NAME,Example,SELECT", "SCRIPT,private,SELECT",
                    "DOMAIN,https://private.example,SELECT", "DOMAIN,*.example.com,SELECT", "DOMAIN,-bad,DIRECT",
                    "DOMAIN,example.com,Unknown", "DOMAIN-KEYWORD, ,REJECT", "DOMAIN,example.com,DIRECT,no-resolve",
                    "IP-CIDR,999.0.0.0/24,SELECT", "IP-CIDR,192.0.2.0/+24,DIRECT", "IP-CIDR6,::1/129,DIRECT",
                    "IP-CIDR,192.0.2.0/24,DIRECT,src", "DOMAIN,exam\u{1B}ple.com,DIRECT"] {
            XCTAssertThrowsError(try ConfigBuilder.parseEditableRules(row + "\nMATCH,DIRECT"), row)
        }
        XCTAssertThrowsError(try ConfigBuilder.parseEditableRules("rules:\n- \"DOMAIN,example.com,DIRECT\\nMATCH,SELECT\"\n- MATCH,DIRECT"))
    }

    func testRejectsConfigurationInjectionAndReportsSanitizedSyntaxErrors() {
        for text in ["rules: ['MATCH,DIRECT']\ndns: {enable: true}", "rules: ['MATCH,DIRECT']\ntun: {enable: true}",
                     "rules: ['MATCH,DIRECT']\nproxy-providers: {}", "rules: &secret ['MATCH,DIRECT']", "rules: [[MATCH,DIRECT]]"] {
            XCTAssertThrowsError(try ConfigBuilder.parseEditableRules(text))
        }
        XCTAssertThrowsError(try ConfigBuilder.parseEditableRules("rules:\n- 'private-token")) { error in
            XCTAssertTrue(error.localizedDescription.contains("行"))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }

    func testRejectsOversizedAndExcessiveRuleDocuments() {
        XCTAssertThrowsError(try ConfigBuilder.parseEditableRules(String(repeating: "x", count: ConfigBuilder.maximumImportBytes + 1)))
        let many = Array(repeating: "DOMAIN,example.com,DIRECT", count: 10000) + ["MATCH,DIRECT"]
        XCTAssertThrowsError(try ConfigBuilder.parseEditableRules(ConfigBuilder.editableRulesText(many)))
    }

    func testEditingRoutingDoesNotEnableDNSOrListeners() throws {
        let object = try build(["MATCH,SELECT"])
        XCTAssertEqual(object["allow-lan"] as? Bool, false)
        XCTAssertEqual(object["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual((object["dns"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((object["tun"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertNil(object["listeners"])
        XCTAssertNil(object["rule-providers"])
    }

    func testRuntimeConfigurationUsesFullOverrideWithoutLaunchingCore() throws {
        let session = try CoreSession(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let text = try session.configuration(document(), mode: .rule, rules: [], selected: "Test", ruleOverride: ["MATCH,REJECT"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["rules"] as? [String], ["MATCH,REJECT"])
        XCTAssertFalse(session.isRunning)
    }
}
