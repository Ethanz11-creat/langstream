import Foundation

/// Lightweight wrapper around `Timer` that automatically invalidates
/// the previous timer when a new one is scheduled, and nils out the
/// reference on cancellation.
///
/// Usage:
/// ```swift
/// private var timer = CancellableTimer()
/// timer.schedule(withTimeInterval: 5) { [weak self] in self?.doWork() }
/// timer.cancel()   // invalidates + nils
/// ```
struct CancellableTimer {
    private var timer: Timer?

    mutating func schedule(
        withTimeInterval interval: TimeInterval,
        repeats: Bool = false,
        block: @escaping @Sendable () -> Void
    ) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            block()
        }
    }

    /// For Objective-C selector-based timers (e.g. `#selector(timerFired)`).
    mutating func schedule(
        timeInterval: TimeInterval,
        target: Any,
        selector: Selector,
        userInfo: Any? = nil,
        repeats: Bool = false
    ) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: timeInterval,
            target: target,
            selector: selector,
            userInfo: userInfo,
            repeats: repeats
        )
    }

    mutating func cancel() {
        timer?.invalidate()
        timer = nil
    }

    var isScheduled: Bool {
        timer != nil
    }
}
