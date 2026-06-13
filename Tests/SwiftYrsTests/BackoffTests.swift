import Testing
@testable import SwiftYrs

@Test
func backoffDelayIsExponentialAndCapped() {
    #expect(Backoff.reconnectDelay(
        attempt: 0,
        initialDelay: .milliseconds(10),
        maxDelay: .milliseconds(100)
    ) == .milliseconds(10))
    #expect(Backoff.reconnectDelay(
        attempt: 3,
        initialDelay: .milliseconds(10),
        maxDelay: .milliseconds(100)
    ) == .milliseconds(80))
    #expect(Backoff.reconnectDelay(
        attempt: 6,
        initialDelay: .milliseconds(10),
        maxDelay: .milliseconds(100)
    ) == .milliseconds(100))
}
