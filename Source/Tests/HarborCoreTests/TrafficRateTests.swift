import XCTest
import HarborCore

final class TrafficRateTests: XCTestCase {
    private let sessionID = UUID()

    func testFirstSampleIsUnavailableThenUsesActualElapsedTime() {
        var tracker = TrafficRateTracker()
        XCTAssertNil(tracker.record(uploadTotal: 100, downloadTotal: 500, at: 1, sessionID: sessionID))
        let rate = tracker.record(uploadTotal: 400, downloadTotal: 1700, at: 4, sessionID: sessionID)
        XCTAssertEqual(rate?.uploadBytesPerSecond, 100)
        XCTAssertEqual(rate?.downloadBytesPerSecond, 400)
    }

    func testUnchangedCountersProduceZeroRates() {
        var tracker = TrafficRateTracker()
        _ = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 1, sessionID: sessionID)
        let rate = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 3, sessionID: sessionID)
        XCTAssertEqual(rate, TrafficRateSample(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0))
    }

    func testSessionChangeResetsBaselineEvenIfCountersIncrease() {
        var tracker = TrafficRateTracker()
        _ = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 1, sessionID: sessionID)
        let newSession = UUID()
        XCTAssertNil(tracker.record(uploadTotal: 200, downloadTotal: 400, at: 3, sessionID: newSession))
        let rate = tracker.record(uploadTotal: 300, downloadTotal: 600, at: 5, sessionID: newSession)
        XCTAssertEqual(rate?.uploadBytesPerSecond, 50)
        XCTAssertEqual(rate?.downloadBytesPerSecond, 100)
    }

    func testEitherCounterResetReestablishesBothBaselines() {
        for counters in [(UInt64(90), UInt64(300)), (UInt64(200), UInt64(190))] {
            var tracker = TrafficRateTracker()
            _ = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 1, sessionID: sessionID)
            XCTAssertNil(tracker.record(uploadTotal: counters.0, downloadTotal: counters.1, at: 3, sessionID: sessionID))
            let rate = tracker.record(uploadTotal: counters.0 + 10, downloadTotal: counters.1 + 20, at: 5, sessionID: sessionID)
            XCTAssertEqual(rate?.uploadBytesPerSecond, 5)
            XCTAssertEqual(rate?.downloadBytesPerSecond, 10)
        }
    }

    func testSleepGapReestablishesBaseline() {
        var tracker = TrafficRateTracker()
        _ = tracker.record(uploadTotal: 0, downloadTotal: 0, at: 1, sessionID: sessionID)
        XCTAssertNotNil(tracker.record(uploadTotal: 100, downloadTotal: 100, at: 11, sessionID: sessionID))
        XCTAssertNil(tracker.record(uploadTotal: 200, downloadTotal: 200, at: 21.01, sessionID: sessionID))
        XCTAssertEqual(tracker.record(uploadTotal: 202, downloadTotal: 204, at: 23.01, sessionID: sessionID),
                       TrafficRateSample(uploadBytesPerSecond: 1, downloadBytesPerSecond: 2))
    }

    func testFailedReadResetMakesNextSampleUnavailable() {
        var tracker = TrafficRateTracker()
        _ = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 1, sessionID: sessionID)
        tracker.reset()
        XCTAssertNil(tracker.record(uploadTotal: 200, downloadTotal: 400, at: 3, sessionID: sessionID))
        XCTAssertNotNil(tracker.record(uploadTotal: 300, downloadTotal: 600, at: 5, sessionID: sessionID))
    }

    func testInvalidTimestampsDiscardHistory() {
        for time in [Double.nan, Double.infinity, -Double.infinity, -1] {
            var tracker = TrafficRateTracker()
            _ = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 1, sessionID: sessionID)
            XCTAssertNil(tracker.record(uploadTotal: 200, downloadTotal: 400, at: time, sessionID: sessionID))
            XCTAssertNil(tracker.record(uploadTotal: 300, downloadTotal: 600, at: 3, sessionID: sessionID))
        }
    }

    func testNonIncreasingTimeReestablishesBaseline() {
        for time in [1.0, 0.5] {
            var tracker = TrafficRateTracker()
            _ = tracker.record(uploadTotal: 100, downloadTotal: 200, at: 1, sessionID: sessionID)
            XCTAssertNil(tracker.record(uploadTotal: 200, downloadTotal: 400, at: time, sessionID: sessionID))
            XCTAssertEqual(tracker.record(uploadTotal: 202, downloadTotal: 404, at: time + 2, sessionID: sessionID),
                           TrafficRateSample(uploadBytesPerSecond: 1, downloadBytesPerSecond: 2))
        }
    }

    func testLargeCountersPreserveSmallDeltasAndWrappingIsUnavailable() {
        var tracker = TrafficRateTracker()
        _ = tracker.record(uploadTotal: UInt64.max - 2, downloadTotal: UInt64.max - 4, at: 1, sessionID: sessionID)
        XCTAssertEqual(tracker.record(uploadTotal: UInt64.max, downloadTotal: UInt64.max, at: 3, sessionID: sessionID),
                       TrafficRateSample(uploadBytesPerSecond: 1, downloadBytesPerSecond: 2))
        XCTAssertNil(tracker.record(uploadTotal: 0, downloadTotal: 0, at: 5, sessionID: sessionID))
    }

    func testNonFiniteRateIsUnavailable() {
        var tracker = TrafficRateTracker()
        _ = tracker.record(uploadTotal: 0, downloadTotal: 0, at: 0, sessionID: sessionID)
        XCTAssertNil(tracker.record(uploadTotal: UInt64.max, downloadTotal: UInt64.max,
                                    at: Double.leastNonzeroMagnitude, sessionID: sessionID))
    }
}
