import Foundation

public enum NodeTester {
    /// Keeps a bounded rolling queue so one slow node does not hold up completed slots.
    public static func run(
        names: [String],
        concurrency: Int = 4,
        measure: @escaping @Sendable (String) async -> String,
        onResult: (String, String) async -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !names.isEmpty else { return }
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            defer { group.cancelAll() }
            var next = 0
            for _ in 0..<min(max(1, concurrency), names.count) {
                let name = names[next]
                next += 1
                group.addTask { (name, await measure(name)) }
            }
            while let (name, result) = try await group.next() {
                try Task.checkCancellation()
                await onResult(name, result)
                if next < names.count {
                    let name = names[next]
                    next += 1
                    group.addTask { (name, await measure(name)) }
                }
            }
        }
    }
}
