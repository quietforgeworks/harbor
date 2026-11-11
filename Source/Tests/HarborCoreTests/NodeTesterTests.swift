import XCTest
@testable import HarborCore

private actor ProbeRecorder {
    var active = 0
    var maximum = 0
    var started: [String] = []
    var completed: [String] = []
    func begin(_ name: String) {
        active += 1
        maximum = max(maximum, active)
        started.append(name)
    }
    func end() { active -= 1 }
    func record(_ name: String) { completed.append(name) }
    func snapshot() -> (Int, Int, [String], [String]) { (active, maximum, started, completed) }
}

final class NodeTesterTests: XCTestCase {
    func testRollingQueueFillsSlotsBeforeSlowNodeCompletes() async throws {
        let recorder = ProbeRecorder()
        let names = (0..<170).map(String.init)
        try await NodeTester.run(names: names, measure: { name in
            await recorder.begin(name)
            try? await Task.sleep(nanoseconds: name == "0" ? 120_000_000 : 1_000_000)
            await recorder.end()
            return "1 ms"
        }, onResult: { name, _ in await recorder.record(name) })
        let (active, maximum, started, completed) = await recorder.snapshot()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(maximum, 4)
        XCTAssertEqual(Set(started), Set(names))
        XCTAssertEqual(Set(completed), Set(names))
        XCTAssertEqual(completed.count, names.count)
        XCTAssertLessThan(completed.firstIndex(of: "4")!, completed.firstIndex(of: "0")!)
    }

    func testCancellationStopsSchedulingAndDoesNotPublishCancelledResults() async {
        let recorder = ProbeRecorder()
        let task = Task {
            try await NodeTester.run(names: (0..<170).map(String.init), measure: { name in
                await recorder.begin(name)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await recorder.end()
                return "失败"
            }, onResult: { name, _ in await recorder.record(name) })
        }
        while await recorder.snapshot().2.count < 4 { await Task.yield() }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let (active, maximum, started, completed) = await recorder.snapshot()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(maximum, 4)
        XCTAssertEqual(started.count, 4)
        XCTAssertTrue(completed.isEmpty)
    }
}
