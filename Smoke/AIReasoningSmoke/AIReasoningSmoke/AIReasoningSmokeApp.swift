// SPDX-License-Identifier: GPL-3.0-or-later

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
