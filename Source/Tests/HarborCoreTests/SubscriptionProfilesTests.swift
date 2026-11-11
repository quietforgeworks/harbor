import XCTest
@testable import HarborCore

final class SubscriptionProfilesTests: XCTestCase {
    private func document(_ name: String) throws -> SubscriptionDocument {
        try ConfigBuilder.parseSubscription("""
        proxies:
          - name: \(name)
            type: socks5
            server: node.example.com
            port: 1080
        proxy-server-nameserver: [https://dns.example.com/dns-query]
        """)
    }
    func testLegacyMigrationRetainsDocumentMetadataAndGlobalPreferences() throws {
        let doc = try document("Legacy")
        let quota = SubscriptionQuota.parse("upload=12; download=34; total=1024; expire=2000000000")
        struct Legacy: Encodable {
            let credentialAccount = "legacy-account"
            let name = "MESL"
            let document: SubscriptionDocument
            let quota: SubscriptionQuota
            let selected = "Legacy"
            let automatic = false
            let updated = Date(timeIntervalSince1970: 1700000000)
            let rules = ["DOMAIN,example.com,DIRECT"]
            let mode = "global"
        }
        let data = try JSONEncoder().encode(Legacy(document: doc, quota: quota))
        let store = try JSONDecoder().decode(SubscriptionProfiles.self, from: data)
        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(store.active?.name, "MESL")
        XCTAssertEqual(store.document, doc)
        XCTAssertEqual(store.credentialAccount, "legacy-account")
        XCTAssertEqual(store.quota, quota)
        XCTAssertEqual(store.selected, "Legacy")
        XCTAssertFalse(store.automatic)
        XCTAssertEqual(store.updated, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(store.rules, ["DOMAIN,example.com,DIRECT"])
        XCTAssertEqual(store.mode, "global")
        XCTAssertNil(store.ruleOverride)
    }
    func testUpdatingOneAirportPreservesOtherAirportAndSelection() throws {
        let first = SubscriptionProfile(name: "MESL", credentialAccount: "account-a", document: try document("A"), selected: "A")
        let second = SubscriptionProfile(name: "Other", credentialAccount: "account-b", document: try document("B"), selected: "B", automatic: false)
        var store = SubscriptionProfiles()
        store.upsert(first, activate: true)
        store.upsert(second, activate: false)
        var updated = second
        updated.document = try document("B2")
        updated.selected = "B2"
        updated.updated = Date()
        store.upsert(updated, activate: false)
        XCTAssertEqual(store.activeSubscriptionID, first.id)
        XCTAssertEqual(store.active, first)
        XCTAssertEqual(store.subscriptions[1], updated)
    }
    func testRoundTripPreservesAllAirportsAndIndependentMetadata() throws {
        var store = SubscriptionProfiles()
        store.rules = ["MATCH,DIRECT"]
        store.ruleOverride = ["DOMAIN,example.org,PROXY", "MATCH,DIRECT"]
        store.mode = "global"
        store.upsert(SubscriptionProfile(name: "One", credentialAccount: "opaque-reference", document: try document("A"), quota: .parse("upload=5; download=6; total=20"), selected: "A", updated: Date(timeIntervalSince1970: 42)), activate: true)
        store.upsert(SubscriptionProfile(name: "Local", document: try document("B"), selected: "B", automatic: false), activate: true)
        let encoded = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(SubscriptionProfiles.self, from: encoded)
        XCTAssertEqual(decoded.subscriptions, store.subscriptions)
        XCTAssertEqual(decoded.activeSubscriptionID, store.activeSubscriptionID)
        XCTAssertEqual(decoded.rules, store.rules)
        XCTAssertEqual(decoded.ruleOverride, store.ruleOverride)
        XCTAssertEqual(decoded.mode, store.mode)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["url"])
        XCTAssertNil(object["originalURL"])
        XCTAssertNil(object["document"])
    }
    func testActiveCompatibilityWritebackOnlyChangesSelectedAirport() throws {
        var store = SubscriptionProfiles()
        let first = SubscriptionProfile(name: "One", document: try document("A"), selected: "A")
        let second = SubscriptionProfile(name: "Two", document: try document("B"), selected: "B")
        store.upsert(first, activate: true)
        store.upsert(second, activate: true)
        store.automatic = false
        store.quota = .parse("upload=3; download=4; total=50")
        XCTAssertEqual(store.subscriptions[0], first)
        XCTAssertFalse(store.subscriptions[1].automatic)
        XCTAssertEqual(store.subscriptions[1].quota.used, 7)
    }
    func testRemovalAndInvalidActiveIDRecoverToExistingAirport() throws {
        var store = SubscriptionProfiles()
        let first = SubscriptionProfile(name: "One")
        let second = SubscriptionProfile(name: "Two")
        store.upsert(first, activate: true)
        store.upsert(second, activate: false)
        store.activeSubscriptionID = "missing"
        let restored = try JSONDecoder().decode(SubscriptionProfiles.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(restored.activeSubscriptionID, first.id)
        store.activeSubscriptionID = first.id
        store.remove(first.id)
        XCTAssertEqual(store.activeSubscriptionID, second.id)
        store.remove(second.id)
        XCTAssertNil(store.activeSubscriptionID)
        XCTAssertTrue(store.subscriptions.isEmpty)
    }
    func testEmptyLegacyAndSafeDisplayNames() throws {
        let store = try JSONDecoder().decode(SubscriptionProfiles.self, from: Data("{}".utf8))
        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertNil(store.document)
        XCTAssertEqual(SubscriptionProfile.displayName(for: "https://api.mesl.cloud/private?token=secret"), "MESL")
        XCTAssertEqual(SubscriptionProfile.displayName(for: "https://airport.example/private?token=secret"), "airport.example")
    }
}
