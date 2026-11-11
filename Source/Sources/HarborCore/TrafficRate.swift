import Foundation

/// Traffic handled by the current core, averaged over the latest sampling interval.
public struct TrafficRateSample: Equatable {
    public let uploadBytesPerSecond: Double
    public let downloadBytesPerSecond: Double

    public init(uploadBytesPerSecond: Double, downloadBytesPerSecond: Double) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }
}

/// Converts cumulative byte counters into rates using caller-supplied monotonic time.
public struct TrafficRateTracker {
    private struct Baseline {
        let upload: UInt64
        let download: UInt64
        let time: TimeInterval
        let sessionID: UUID
    }

    private var baseline: Baseline?

    public init() {}

    /// Call after an unavailable read or when the core stops to discard stale history.
    public mutating func reset() {
        baseline = nil
    }

    /// Returns nil while establishing a baseline or when an interval cannot yield a valid rate.
    /// Supply a monotonic clock such as ProcessInfo.processInfo.systemUptime.
    public mutating func record(
        uploadTotal: UInt64,
        downloadTotal: UInt64,
        at monotonicTime: TimeInterval,
        sessionID: UUID
    ) -> TrafficRateSample? {
        guard monotonicTime.isFinite, monotonicTime >= 0 else {
            reset()
            return nil
        }

        let previous = baseline
        baseline = Baseline(upload: uploadTotal, download: downloadTotal,
                            time: monotonicTime, sessionID: sessionID)
        guard let previous, previous.sessionID == sessionID else { return nil }
        let elapsed = monotonicTime - previous.time
        guard elapsed > 0, elapsed <= 10 else { return nil }

        // Subtract integers before conversion so small changes remain accurate above 2^53.
        let uploadDelta = uploadTotal.subtractingReportingOverflow(previous.upload)
        let downloadDelta = downloadTotal.subtractingReportingOverflow(previous.download)
        guard !uploadDelta.overflow, !downloadDelta.overflow else { return nil }
        let uploadRate = Double(uploadDelta.partialValue) / elapsed
        let downloadRate = Double(downloadDelta.partialValue) / elapsed
        guard uploadRate.isFinite, downloadRate.isFinite else { return nil }
        return TrafficRateSample(uploadBytesPerSecond: uploadRate,
                                 downloadBytesPerSecond: downloadRate)
    }
}
