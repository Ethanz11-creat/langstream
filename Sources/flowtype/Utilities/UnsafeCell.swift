/// A mutable cell for storing state in `@unchecked Sendable` types.
///
/// **Safety:** This struct is `@unchecked Sendable`; the caller must ensure
/// that all accesses to `value` happen on the same thread or are otherwise
/// synchronized. It exists solely to reduce the visual noise of
/// `nonisolated(unsafe)` repeated across many properties.
struct UnsafeCell<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
