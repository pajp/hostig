import Foundation
import SwiftUI

@main
struct HostigVisionApp: App {
    @StateObject private var store = VisionCompanionStore()

    var body: some Scene {
        WindowGroup {
            VisionDashboardView(store: store)
        }
        .defaultSize(width: 1180, height: 760)

        WindowGroup("Host", id: HostigVisionWindowID.host, for: UUID.self) { $hostID in
            VisionHostWindow(hostID: hostID, store: store)
        }
        .defaultSize(width: 440, height: 620)
        .windowResizability(.contentSize)
    }
}

enum HostigVisionWindowID {
    static let host = "host-detail"
}
