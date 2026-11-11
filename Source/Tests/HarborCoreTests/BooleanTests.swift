import XCTest
import HarborCore
final class BooleanTests: XCTestCase {
    func testBooleanNodeOptionsSurviveJSONPersistenceAndYAMLEmission() throws {
        let doc = try ConfigBuilder.parseSubscription("proxies:\n - name: node\n   type: ss\n   server: example.com\n   port: 443\n   cipher: aes-128-gcm\n   password: fake\n   udp: true\n   skip-cert-verify: false\n")
        let config = try ConfigBuilder.build(subscription: doc, mode: .rule, port: 30120, controllerPort: 30121, secret: String(repeating: "x", count: 32))
        XCTAssertTrue(config.contains("\"udp\" : true")); XCTAssertTrue(config.contains("\"skip-cert-verify\" : false"))
    }
}
