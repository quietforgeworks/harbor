import XCTest
@testable import HarborCore

final class SystemProxyTests: XCTestCase {
    final class MemoryStore: ProxyStore {
        var services: [ProxyService]
        var failAfterCommit = false
        var transactionCount = 0
        var beforeTransaction: (() -> Void)?
        init(_ dictionary: [String: Any] = [:]) {
            services = [.init(id: "wifi", name: "Wi-Fi", configuration: dictionary)]
        }
        func read() throws -> [ProxyService] { services }
        func transaction(_ transform: ([ProxyService]) throws -> [String: [String: Any]]) throws {
            beforeTransaction?()
            transactionCount += 1
            let changes = try transform(services)
            for index in services.indices {
                if let value = changes[services[index].id] { services[index].configuration = value }
            }
            if failAfterCommit { failAfterCommit = false; throw SystemProxyError.unavailable }
        }
    }
    private func journal(_ store: MemoryStore) throws -> ProxyJournal {
        try ProxyTransaction.prepare(services: store.read(), port: 28781, parentPID: 42, corePID: 43)
    }
    func testConnectDisconnectRestoresAllOriginalValues() throws {
        let original: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "old.invalid", "HTTPPort": 7890,
            "HTTPSProxy": "old-secure.invalid", "ProxyAutoConfigURLString": "https://private.invalid/config?token=example",
            "ProxyAutoConfigEnable": 0, "SOCKSEnable": 0, "SOCKSProxy": "keep.invalid",
            "ExceptionsList": ["localhost", "*.local"], "ExcludeSimpleHostnames": 1]
        let store = MemoryStore(original), snapshot = try journal(store)
        try ProxyTransaction.apply(snapshot, store: store)
        XCTAssertEqual(store.services[0].configuration["HTTPPort"] as? Int, 28781)
        XCTAssertEqual(store.services[0].configuration["SOCKSProxy"] as? String, "keep.invalid")
        XCTAssertTrue(try ProxyTransaction.ownsAnySettings(snapshot, services: store.read()))
        try ProxyTransaction.restore(snapshot, store: store)
        XCTAssertTrue(NSDictionary(dictionary: store.services[0].configuration).isEqual(to: original))
        XCTAssertFalse(try ProxyTransaction.ownsAnySettings(snapshot, services: store.read()))
    }
    func testEveryExistingProxyMechanismIsAConflict() throws {
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            let store = MemoryStore([key: 1])
            XCTAssertThrowsError(try journal(store), key)
            XCTAssertEqual(store.transactionCount, 0)
        }
    }
    func testThirdPartyEditsSurviveRollback() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        try ProxyTransaction.apply(snapshot, store: store)
        store.services[0].configuration["HTTPProxy"] = "other-proxy.invalid"
        store.services[0].configuration["HTTPPort"] = 1080
        store.services[0].configuration["ExceptionsList"] = ["new.local"]
        store.services[0].configuration["ProxyAutoConfigEnable"] = 1
        try ProxyTransaction.restore(snapshot, store: store)
        XCTAssertEqual(store.services[0].configuration["HTTPProxy"] as? String, "other-proxy.invalid")
        XCTAssertEqual(store.services[0].configuration["HTTPPort"] as? Int, 1080)
        XCTAssertNil(store.services[0].configuration["HTTPSProxy"])
        XCTAssertEqual(store.services[0].configuration["ExceptionsList"] as? [String], ["new.local"])
        XCTAssertEqual(store.services[0].configuration["ProxyAutoConfigEnable"] as? Int, 1)
    }
    func testChangedSettingsAbortBeforeAnyWrites() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        store.services[0].configuration["HTTPEnable"] = 1
        store.services[0].configuration["HTTPProxy"] = "other.invalid"
        XCTAssertThrowsError(try ProxyTransaction.apply(snapshot, store: store))
        XCTAssertEqual(store.services[0].configuration["HTTPProxy"] as? String, "other.invalid")
        XCTAssertNil(store.services[0].configuration["HTTPSProxy"])
    }
    func testCommittedButUnappliedFailureCanStillRecover() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        store.failAfterCommit = true
        XCTAssertThrowsError(try ProxyTransaction.apply(snapshot, store: store))
        XCTAssertTrue(try ProxyTransaction.ownsAnySettings(snapshot, services: store.read()))
        try ProxyTransaction.restore(snapshot, store: store)
        XCTAssertTrue(store.services[0].configuration.isEmpty)
    }
    func testRecoveryIsIdempotentAndNetworkLocationChangeDoesNotHideOwnedService() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        try ProxyTransaction.apply(snapshot, store: store)
        store.services[0] = .init(id: "wifi", name: "Wi-Fi", configuration: store.services[0].configuration, connectEligible: false)
        store.services.append(.init(id: "ethernet", name: "Ethernet", configuration: ["HTTPEnable": 1, "HTTPProxy": "corporate.invalid"]))
        try ProxyTransaction.restore(snapshot, store: store)
        try ProxyTransaction.restore(snapshot, store: store)
        XCTAssertTrue(store.services[0].configuration.isEmpty)
        XCTAssertEqual(store.services[1].configuration["HTTPProxy"] as? String, "corporate.invalid")
    }
    func testInactiveLocationIsNotChangedOnConnect() throws {
        let store = MemoryStore()
        store.services.append(.init(id: "old-location", name: "Other", configuration: ["HTTPEnable": 1], connectEligible: false))
        let snapshot = try journal(store)
        XCTAssertEqual(snapshot.entries.count, 1)
        try ProxyTransaction.apply(snapshot, store: store)
        XCTAssertEqual(store.services[1].configuration["HTTPEnable"] as? Int, 1)
        XCTAssertNil(store.services[1].configuration["HTTPSProxy"])
    }
    func testRemovingServiceDoesNotRestoreIntoUnrelatedService() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        try ProxyTransaction.apply(snapshot, store: store)
        store.services = [.init(id: "replacement", name: "Wi-Fi", configuration: [:])]
        try ProxyTransaction.restore(snapshot, store: store)
        XCTAssertTrue(store.services[0].configuration.isEmpty)
    }
    func testNetworkLocationOrEligibilityChangeAbortsApply() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        store.services[0] = .init(id: "wifi", name: "Wi-Fi", configuration: [:], connectEligible: false)
        XCTAssertThrowsError(try ProxyTransaction.apply(snapshot, store: store))
        XCTAssertTrue(store.services[0].configuration.isEmpty)
        store.services.append(.init(id: "new-location", name: "Wi-Fi", configuration: [:]))
        XCTAssertThrowsError(try ProxyTransaction.apply(snapshot, store: store))
        XCTAssertTrue(store.services[1].configuration.isEmpty)
    }
    func testNewlyEnabledServiceAbortsApply() throws {
        let store = MemoryStore(), snapshot = try journal(store)
        store.services.append(.init(id: "ethernet", name: "Ethernet", configuration: [:]))
        XCTAssertThrowsError(try ProxyTransaction.apply(snapshot, store: store))
        XCTAssertTrue(store.services.allSatisfy { $0.configuration.isEmpty })
    }
    func testOldGuardianCannotRestoreOrDeleteReplacementJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarborProxyTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.plist")
        let store = MemoryStore(), old = try journal(store)
        let replacement = try journal(store)
        try JournalIO.withLock(at: url) {
            try JournalIO.write(replacement, to: url)
            try ProxyTransaction.apply(replacement, store: store)
        }
        XCTAssertFalse(try JournalIO.restoreIfCurrent(url, token: old.token, store: store))
        XCTAssertEqual(try JournalIO.read(url).token, replacement.token)
        XCTAssertTrue(try ProxyTransaction.ownsAnySettings(replacement, services: store.read()))
        XCTAssertTrue(try JournalIO.restoreIfCurrent(url, token: replacement.token, store: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testGuardRestoreAndReconnectSerializeAcrossStableFileLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarborProxyLockTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.plist")
        let store = MemoryStore(), old = try journal(store)
        try JournalIO.withLock(at: url) {
            try JournalIO.write(old, to: url)
            try ProxyTransaction.apply(old, store: store)
        }
        let restoreEntered = DispatchSemaphore(value: 0), allowRestore = DispatchSemaphore(value: 0)
        let reconnectEntered = DispatchSemaphore(value: 0)
        let restored = expectation(description: "Old guardian finished"), reconnected = expectation(description: "New session published")
        store.beforeTransaction = {
            store.beforeTransaction = nil
            restoreEntered.signal()
            XCTAssertEqual(allowRestore.wait(timeout: .now() + 3), .success)
        }
        DispatchQueue.global().async {
            do { try JournalIO.restoreIfCurrent(url, token: old.token, store: store) }
            catch { XCTFail("Restore failed: \(error)") }
            restored.fulfill()
        }
        XCTAssertEqual(restoreEntered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            do {
                try JournalIO.withLock(at: url) {
                    reconnectEntered.signal()
                    let next = try ProxyTransaction.prepare(services: store.read(), port: 28781, parentPID: 42, corePID: 44)
                    try JournalIO.write(next, to: url)
                    try ProxyTransaction.apply(next, store: store)
                }
            } catch { XCTFail("Reconnect failed: \(error)") }
            reconnected.fulfill()
        }
        XCTAssertEqual(reconnectEntered.wait(timeout: .now() + 0.15), .timedOut)
        allowRestore.signal()
        wait(for: [restored, reconnected], timeout: 5)
        let current = try JournalIO.read(url)
        XCTAssertNotEqual(current.token, old.token)
        XCTAssertTrue(try ProxyTransaction.ownsAnySettings(current, services: store.read()))
        XCTAssertFalse(try JournalIO.restoreIfCurrent(url, token: old.token, store: store))
        XCTAssertEqual(try JournalIO.read(url).token, current.token)
    }
}
