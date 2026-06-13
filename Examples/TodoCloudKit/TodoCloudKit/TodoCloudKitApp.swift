import SwiftUI

@main
struct TodoCloudKitApp: App {
    @StateObject private var store: TodoStore

    init() {
        // Force-try: the document is created in-memory; failure here is a
        // programmer error worth crashing on at launch.
        _store = StateObject(wrappedValue: try! TodoStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task { await store.start() }
        }
    }
}
