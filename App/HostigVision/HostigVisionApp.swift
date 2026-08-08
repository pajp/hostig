import SwiftUI

@main
struct HostigVisionApp: App {
    var body: some Scene {
        WindowGroup {
            VisionDashboardView()
        }
        .defaultSize(width: 1180, height: 760)
    }
}
