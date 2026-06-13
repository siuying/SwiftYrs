import Foundation

/// Exponential reconnect backoff shared by the transport providers: the delay
/// doubles each attempt, starting at `initialDelay` and capped at `maxDelay`.
/// `attempt` is zero-based, so attempt 0 waits `initialDelay`.
package enum Backoff {
    package static func reconnectDelay(attempt: Int, initialDelay: Duration, maxDelay: Duration) -> Duration {
        var delay = initialDelay
        guard attempt > 0 else {
            return min(delay, maxDelay)
        }
        for _ in 0..<attempt {
            delay = min(delay + delay, maxDelay)
        }
        return delay
    }
}
