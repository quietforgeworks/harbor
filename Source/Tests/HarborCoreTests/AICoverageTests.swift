import XCTest
import Yams
@testable import HarborCore

final class AICoverageTests: XCTestCase {
    private func target(for host: String, in rules: [String]) -> String? {
        for rule in rules {
            let parts = rule.components(separatedBy: ",")
            switch parts[0] {
            case "DOMAIN":
                if host == parts[1] { return parts[2] }
            case "DOMAIN-SUFFIX":
                if host == parts[1] || host.hasSuffix("." + parts[1]) { return parts[2] }
            case "MATCH":
                return parts[1]
            default:
                continue
            }
        }
        return nil
    }

    func testBuiltConfigProtectsRequiredServiceRoutesFromCustomDirect() throws {
        let document = try ConfigBuilder.parseSubscription("""
        proxies:
          - {name: Test, type: socks5, server: proxy.example.com, port: 1080}
        """)
        let customRules = ConfigBuilder.serviceDomains.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
            + ConfigBuilder.sharedServiceHosts.map { "DOMAIN,\($0),DIRECT" }
        let text = try ConfigBuilder.build(subscription: document, mode: .rule,
            customRules: customRules, port: 18901, controllerPort: 18902,
            secret: String(repeating: "t", count: 32))
        let object = try XCTUnwrap(Yams.load(yaml: text) as? [String: Any])
        let rules = try XCTUnwrap(object["rules"] as? [String])
        for domain in ConfigBuilder.serviceDomains {
            XCTAssertEqual(target(for: domain, in: rules), "SELECT", domain)
            XCTAssertEqual(target(for: "sub." + domain, in: rules), "SELECT", domain)
        }
        for host in ConfigBuilder.sharedServiceHosts {
            XCTAssertEqual(target(for: host, in: rules), "SELECT", host)
        }
        XCTAssertEqual(rules.last, "MATCH,DIRECT")
    }

    func testCoreAILoginUploadsStreamingAndArtifacts() {
        let hosts = [
            "chatgpt.com", "auth.openai.com", "auth0.openai.com", "setup.auth.openai.com",
            "api.openai.com", "ws.chatgpt.com", "cdn.oaistatic.com", "files.oaiusercontent.com",
            "ab.chatgpt.com", "cdn.openaimerge.com", "frontend-apps-multi-region.workos.com",
            "challenges.cloudflare.com", "claude.ai", "platform.claude.com", "sso.claude.com",
            "api.anthropic.com", "assets-proxy.anthropic.com", "downloads.claude.ai",
            "bridge.claudeusercontent.com", "artifact.frame.claudeusercontent.com",
            "project.livepreview.claude.app", "widget.claudemcpcontent.com",
            "cdnjs.cloudflare.com", "cdn.jsdelivr.net", "cdn.tailwindcss.com", "code.jquery.com", "unpkg.com",
            "gemini.google.com", "accounts.google.com", "aistudio.google.com",
            "generativelanguage.googleapis.com", "aiplatform.googleapis.com",
            "us-central1-aiplatform.googleapis.com", "oauth2.googleapis.com",
            "storage.googleapis.com", "drive.google.com", "drive.usercontent.google.com",
            "content-push.googleapis.com"
        ]
        let rules = ConfigBuilder.rules(mode: .rule)
        for host in hosts { XCTAssertEqual(target(for: host, in: rules), "SELECT", host) }
    }

    func testCompletePublishedGeminiHostList() {
        // Google Workspace firewall-and-proxy-settings, Gemini hosts, checked 2026-11-06.
        let hosts = [
            "lh5.googleusercontent.com", "www.googleapis.com", "ssl.gstatic.com", "fonts.googleapis.com",
            "play.google.com", "ogs.google.com", "www.google.com", "apis.google.com",
            "jnn-pa.googleapis.com", "waa-pa.clients6.google.com", "i.ytimg.com", "yt3.ggpht.com",
            "lh3.googleusercontent.com", "maps.gstatic.com", "lh3.google.com", "ogads-pa.clients6.google.com",
            "csp.withgoogle.com", "www.googletagmanager.com", "www.youtube.com", "fonts.gstatic.com",
            "maps.googleapis.com", "static.doubleclick.net", "www.gstatic.com", "gemini.google.com",
            "td.doubleclick.net", "googleads.g.doubleclick.net", "www.google-analytics.com",
            "optimizationguide-pa.googleapis.com", "encrypted-tbn0.gstatic.com", "encrypted-tbn1.gstatic.com",
            "encrypted-tbn2.gstatic.com", "encrypted-tbn3.gstatic.com", "streetviewpixels-pa.googleapis.com",
            "content-autofill.googleapis.com"
        ]
        let rules = ConfigBuilder.rules(mode: .rule)
        for host in hosts { XCTAssertEqual(target(for: host, in: rules), "SELECT", host) }
    }

    func testAppleLANSharedProvidersAndUnlistedTrafficRemainDirect() {
        let rules = ConfigBuilder.rules(mode: .rule, customRules: ["DOMAIN-SUFFIX,apple.com,SELECT"])
        let hosts = ["humb.apple.com", "icloud.com", "apple-relay.cloudflare.com", "localhost", "nas.local",
                     "router.lan", "example.com", "cloudflare.com", "other.cloudflare.com", "amazonaws.com",
                     "unrelated.amazonaws.com", "azure.com", "akamai.net", "other.jsdelivr.net",
                     "other.workos.com", "unlisted.doubleclick.net", "notchatgpt.com", "chatgpt.com.example.org"]
        for host in hosts { XCTAssertEqual(target(for: host, in: rules), "DIRECT", host) }
        XCTAssertEqual(Array(rules.prefix(ConfigBuilder.localRules.count)), ConfigBuilder.localRules)
        XCTAssertEqual(ConfigBuilder.rules(mode: .global), ConfigBuilder.localRules + ["MATCH,SELECT"])
    }

    func testCustomRulesStillApplyToUnlistedHosts() {
        let rules = ConfigBuilder.rules(mode: .rule, customRules: ["DOMAIN,example.com,SELECT"])
        XCTAssertEqual(target(for: "example.com", in: rules), "SELECT")
        XCTAssertEqual(target(for: "www.example.com", in: rules), "DIRECT")
        XCTAssertEqual(Set(ConfigBuilder.serviceDomains).count, ConfigBuilder.serviceDomains.count)
        XCTAssertEqual(Set(ConfigBuilder.sharedServiceHosts).count, ConfigBuilder.sharedServiceHosts.count)
    }
}
