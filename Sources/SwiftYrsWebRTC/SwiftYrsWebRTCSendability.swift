import SwiftYrs

// Core SwiftYrs types are confined to the provider actor / serial queues; the
// transport marks them Sendable so they can cross into libwebrtc callbacks and
// async tasks. Mirrors SwiftYrsHocuspocus's SwiftYrsSendability.
extension YAwareness: @unchecked Sendable {}
extension YAwarenessUpdate: @unchecked Sendable {}
extension YDoc: @unchecked Sendable {}
extension YUpdate: @unchecked Sendable {}
