import AppKit
import QuartzCore

struct FrameSample: Codable {
    let elapsed: Double
    let progress: Double
    let values: [Double]
}

/// Applies view properties on the main thread at the display's actual cadence.
final class FrameAnimator {
    private final class Relay: NSObject {
        weak var owner: FrameAnimator?
        let generation: UInt64
        init(owner: FrameAnimator, generation: UInt64) {
            self.owner = owner; self.generation = generation
        }
        @objc func tick(_ sender: CADisplayLink) { owner?.step(generation) }
    }
    private var link: CADisplayLink?
    private var timer: Timer?
    private var relay: Relay?
    private var generation: UInt64 = 0
    private var began: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var receivedFirstTick = false
    private var update: ((CGFloat) -> Void)?
    private var observe: (() -> [Double])?
    private var completion: (() -> Void)?
    private(set) var isAnimating = false
    private(set) var driverName = "none"
    private(set) var samples: [FrameSample] = []

    deinit { link?.invalidate(); timer?.invalidate() }

    func animate(duration: TimeInterval, window: NSWindow?,
                 update: @escaping (CGFloat) -> Void,
                 observe: @escaping () -> [Double] = { [] },
                 completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let token = generation
        samples.removeAll(keepingCapacity: true)
        self.duration = max(0, duration); began = CACurrentMediaTime(); receivedFirstTick = false
        self.update = update; self.observe = observe; self.completion = completion
        isAnimating = true
        guard self.duration > 0 else {
            driverName = "immediate"
            apply(progress: 1, elapsed: 0, token: token)
            finish(token)
            return
        }
        let relay = Relay(owner: self, generation: token)
        self.relay = relay
        if let window, window.isVisible, window.screen != nil {
            driverName = "window-display-link"
            link = window.displayLink(target: relay, selector: #selector(Relay.tick(_:)))
        } else if let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            driverName = "screen-display-link"
            link = screen.displayLink(target: relay, selector: #selector(Relay.tick(_:)))
        } else {
            driverName = "timer-no-display"
            timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step(token) }
        }
        apply(progress: 0, elapsed: 0, token: token)
        guard generation == token, isAnimating else { return }
        if let link { link.add(to: .main, forMode: .common) }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        stopDrivers()
        isAnimating = false
        update = nil; observe = nil; completion = nil
    }

    private func stopDrivers() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil; relay = nil
    }
    private func step(_ token: UInt64) {
        guard generation == token, isAnimating else { return }
        let now = CACurrentMediaTime()
        if !receivedFirstTick { began = now; receivedFirstTick = true }
        let elapsed = max(0, now - began)
        let fraction = min(1, elapsed / duration)
        let eased = fraction * fraction * (3 - 2 * fraction)
        apply(progress: CGFloat(eased), elapsed: elapsed, token: token)
        if fraction >= 1 { finish(token) }
    }
    private func apply(progress: CGFloat, elapsed: Double, token: UInt64) {
        guard generation == token, isAnimating else { return }
        update?(progress)
        guard generation == token, isAnimating else { return }
        let values = observe?() ?? []
        guard generation == token, isAnimating else { return }
        samples.append(FrameSample(elapsed: elapsed, progress: Double(progress), values: values))
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }
    private func finish(_ token: UInt64) {
        guard generation == token, isAnimating else { return }
        let finished = completion
        stopDrivers(); isAnimating = false
        update = nil; observe = nil; completion = nil
        finished?()
    }
}
