import SwiftUI

@main
struct AIReasoningSmokeApp: App {
    init() {
        ISHHostBootstrap.registerLinkedHostIfPresent()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
