/// A cached value that is written from `@MainActor` and read from a C callback
/// that is guaranteed to dispatch on the main run loop.
///
/// **Safety:** All reads and writes must happen on the main thread.
/// A `dispatchPrecondition` assertion in the callback enforces this at runtime.
struct MainThreadCachedValue<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
