import SwiftUI
import HostigLink
import HostigLocalServices
import HostigNetworking

@main
struct HostigApp: App {
    @StateObject private var store = HostStore()
    @StateObject private var linkServer = HostigUDPSourceServer()
    @StateObject private var mainWindowBridge = MainWindowBridge()
    private let statusBarController = StatusBarController()

    var body: some Scene {
        WindowGroup(id: "main") {
            DashboardView(
                store: store,
                linkServer: linkServer,
                mainWindowBridge: mainWindowBridge,
                statusBarController: statusBarController
            )
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }
}
