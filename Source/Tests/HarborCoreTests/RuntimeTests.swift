import XCTest
@testable import HarborCore

final class RuntimeTests: XCTestCase {
    func testQuotaParsesUsageAndExpiry() throws {
        let quota = SubscriptionQuota.parse("upload=1024; download=2048; total=8192; expire=1893456000")
        XCTAssertEqual(quota.upload, 1024)
        XCTAssertEqual(quota.download, 2048)
        XCTAssertEqual(quota.used, 3072)
        XCTAssertEqual(quota.total, 8192)
        XCTAssertEqual(try XCTUnwrap(quota.expire).timeIntervalSince1970, 1893456000)
        XCTAssertNil(quota.updateHours)
    }

    func testQuotaAcceptsCaseAndSpaces() {
        let quota = SubscriptionQuota.parse(" UPLOAD = 0 ; Download = 12 ; TOTAL = 99 ; expire = 0 ")
        XCTAssertEqual(quota.upload, 0)
        XCTAssertEqual(quota.used, 12)
        XCTAssertEqual(quota.total, 99)
        XCTAssertNil(quota.expire)
    }

    func testMissingAndMalformedFieldsStayUnknown() {
        for header in [nil, "", "upload=-1;download=bad;total=18446744073709551616;expire=-1", "upload;download=;=5;unknown=8"] as [String?] {
            let quota = SubscriptionQuota.parse(header)
            XCTAssertNil(quota.upload)
            XCTAssertNil(quota.download)
            XCTAssertNil(quota.used)
            XCTAssertNil(quota.total)
            XCTAssertNil(quota.expire)
        }
    }

    func testPartialUsageDoesNotImplyZeroForMissingDirection() {
        XCTAssertNil(SubscriptionQuota.parse("upload=10").used)
        XCTAssertNil(SubscriptionQuota.parse("download=10").used)
    }

    func testUsageOverflowRemainsUnknown() {
        let maximum = String(UInt64.max)
        XCTAssertNil(SubscriptionQuota.parse("upload=\(maximum);download=1").used)
        XCTAssertEqual(SubscriptionQuota.parse("upload=\(maximum);download=0").used, UInt64.max)
    }

    func testQuotaRoundTripsSavedProfileRepresentation() throws {
        var original = SubscriptionQuota.parse("upload=10;download=20;total=100;expire=1893456000")
        original.updateHours = 6
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SubscriptionQuota.self, from: data), original)
    }
}
