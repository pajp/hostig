import SwiftUI
import HostigLink
import HostigLocalServices
import HostigModels
import HostigNetworking

struct DashboardView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var store: HostStore
    @ObservedObject var linkServer: HostigLinkSourceServer
    @ObservedObject var reversePusher: HostigReverseSnapshotPusher
    @ObservedObject var mainWindowBridge: MainWindowBridge
    let statusBarController: StatusBarController
    @State private var passwordPromptHost: HostRecord?
    @State private var sudoPassword = ""
    @State private var rebootConfirmationHost: HostRecord?
    @State private var rebootAlert: RebootAlert?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 14) {
                    if store.hosts.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.hosts) { host in
                            HostCard(
                                host: host,
                                isRebooting: store.rebootingHostIDs.contains(host.id),
                                onReboot: { selectedHost in
                                    rebootConfirmationHost = selectedHost
                                },
                                onOpenTerminal: { selectedHost in
                                    let url = URL(string: "ssh://\(selectedHost.hostname)")!
                                    // open URL through LaunchServices
                                    NSWorkspace.shared.open(url)
                                    
                                }
                            )
                            .equatable()
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $passwordPromptHost) { host in
            PasswordPromptSheet(
                host: host,
                password: $sudoPassword,
                isSubmitting: store.rebootingHostIDs.contains(host.id),
                onCancel: {
                    sudoPassword = ""
                    passwordPromptHost = nil
                },
                onSubmit: {
                    let password = sudoPassword
                    let hostStore = store
                    Task {
                        let result = await hostStore.submitRebootPassword(password, for: host.id)
                        await MainActor.run {
                            switch result {
                            case .success:
                                rebootAlert = RebootAlert(title: "Reboot Started", message: "\(host.displayName) accepted `sudo reboot`.")
                                sudoPassword = ""
                                passwordPromptHost = nil
                            case .failure(let message):
                                rebootAlert = RebootAlert(title: "Reboot Failed", message: message)
                            }
                        }
                    }
                }
            )
            .frame(width: 420)
        }
        .alert(item: $rebootAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            rebootConfirmationHost.map { "Reboot \($0.displayName)?" } ?? "Reboot Host?",
            isPresented: Binding(
                get: { rebootConfirmationHost != nil },
                set: { isPresented in
                    if !isPresented {
                        rebootConfirmationHost = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: rebootConfirmationHost
        ) { host in
            Button("Reboot \(host.displayName)", role: .destructive) {
                rebootConfirmationHost = nil
                requestReboot(host)
            }
            Button("Cancel", role: .cancel) {
                rebootConfirmationHost = nil
            }
        } message: { host in
            Text("This will run `sudo reboot` on \(host.hostname).")
        }
        .background(WindowAccessor(mainWindowBridge: mainWindowBridge))
        .task {
            statusBarController.configureIfNeeded(store: store, mainWindowBridge: mainWindowBridge)
            linkServer.start(
                provider: store,
                identity: macLinkIdentity
            )
            reversePusher.startBrowsing()
        }
    }

    private var macLinkIdentity: HostigLinkIdentity {
        .persisted(
            storageKey: "nu.dll.hostig.mac.appInstanceID",
            deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            platform: "macOS"
        )
    }

    private func requestReboot(_ selectedHost: HostRecord) {
        let hostStore = store
        Task {
            let result = await hostStore.requestReboot(for: selectedHost.id)
            await MainActor.run {
                switch result {
                case .success(.started):
                    rebootAlert = RebootAlert(title: "Reboot Started", message: "\(selectedHost.displayName) accepted `sudo reboot`.")
                case .success(.passwordRequired):
                    sudoPassword = ""
                    passwordPromptHost = selectedHost
                case .failure(let message):
                    rebootAlert = RebootAlert(title: "Reboot Failed", message: message)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            LatencyPanel(
                host: store.latencyMonitorHost,
                snapshot: store.latencyMonitorSnapshot,
                history: store.latencyHistory
            )
            .frame(maxWidth: 520)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    SummaryPill(title: "Hosts", value: "\(store.hosts.count)")
                    SummaryPill(title: "Authed", value: "\(store.hosts.filter(\.hasAuthenticatedSSH).count)")
                    SummaryPill(title: "No SSH", value: "\(store.hosts.filter { !$0.hasAuthenticatedSSH }.count)")
                    SummaryPill(title: "Pairing PIN", value: linkServer.pairingPIN, revealsValueOnHover: true)
                }

                HStack(spacing: 10) {
                    Button("Settings…") { openSettings() }
                    .buttonStyle(.bordered)

                    Button(store.discoveryActive ? "Pause Discovery" : "Resume Discovery") {
                        store.toggleDiscovery()
                    }
                    .buttonStyle(.bordered)

                    Button("Refresh Now") {
                        store.refreshAll()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bonjour")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No Bonjour SSH hosts discovered yet")
                .font(.headline)
            Text("The app scans for `_ssh._tcp` on the local network and can also monitor manually added hosts.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }
}

struct HostigSettingsView: View {
    @ObservedObject var store: HostStore
    @ObservedObject var linkServer: HostigLinkSourceServer
    @ObservedObject var reversePusher: HostigReverseSnapshotPusher

    var body: some View {
        TabView {
            MonitoringSettingsTab(store: store)
                .tabItem { Label("Monitoring", systemImage: "waveform.path") }
            HostsSettingsTab(store: store)
                .tabItem { Label("Hosts", systemImage: "server.rack") }
            ConnectionsSettingsTab(store: store, linkServer: linkServer, reversePusher: reversePusher)
                .tabItem { Label("Connections", systemImage: "network") }
        }
        .frame(width: 760, height: 520)
    }
}

private struct MonitoringSettingsTab: View {
    @ObservedObject var store: HostStore
    @State private var hostDraft = ""
    @State private var hasLoadedHostDraft = false

    var body: some View {
        Form {
            Section("Latency Monitor") {
                HStack {
                    TextField("Host", text: $hostDraft)
                        .onSubmit(saveHost)
                    Button("Set Host", action: saveHost)
                        .disabled(hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hostDraft == store.latencyMonitorHost)
                }
                Toggle("Show latency monitor graph in menu bar", isOn: Binding(
                    get: { store.showsMenuBarGraph(for: HostStore.latencyMonitorGraphKey) },
                    set: { store.setMenuBarGraphVisible($0, for: HostStore.latencyMonitorGraphKey) }
                ))
            }

            Section("Menu Bar Graph Scale") {
                Toggle("Use the same scale for all visible graphs", isOn: Binding(
                    get: { store.menuBarGraphsUseSharedScale },
                    set: { store.setMenuBarGraphsUseSharedScale($0) }
                ))
                Text("When enabled, every graph uses 0 ms at the bottom and the highest recent latency across visible hosts at the top. Max and min labels still show each host’s own values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !hasLoadedHostDraft {
                hostDraft = store.latencyMonitorHost
                hasLoadedHostDraft = true
            }
        }
    }

    private func saveHost() {
        store.updateLatencyMonitorHost(hostDraft)
        hostDraft = store.latencyMonitorHost
    }
}

private struct HostsSettingsTab: View {
    @ObservedObject var store: HostStore
    @State private var manualHosts: [ManualHostEntry] = []
    @State private var selectedManualGraphIDs: Set<UUID> = []
    @State private var hasLoadedDrafts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bonjour hosts are discovered automatically. Add or edit manual SSH hosts below.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !discoveredHosts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bonjour Hosts").font(.headline)
                            ForEach(discoveredHosts) { host in
                                HStack(spacing: 12) {
                                    Text(host.displayName)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(host.hostname)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(host.port)")
                                        .monospacedDigit()
                                        .frame(width: 56, alignment: .trailing)
                                    Toggle("Menu bar graph", isOn: graphBinding(for: HostStore.menuBarGraphKey(for: host)))
                                        .labelsHidden()
                                        .frame(width: 108)
                                }
                                .padding(10)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Manual Hosts").font(.headline)
                            Spacer()
                            Button("Add Host") { manualHosts.append(ManualHostEntry()) }
                        }

                        HStack(spacing: 12) {
                            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Hostname").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Port").frame(width: 72, alignment: .leading)
                            Text("Menu bar graph").frame(width: 108)
                            Color.clear.frame(width: 60, height: 1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        if manualHosts.isEmpty {
                            Text("No manual hosts yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach($manualHosts) { $host in
                                ManualHostRow(host: $host, showsMenuBarGraph: Binding(
                                    get: { selectedManualGraphIDs.contains(host.id) },
                                    set: { visible in
                                        if visible { selectedManualGraphIDs.insert(host.id) }
                                        else { selectedManualGraphIDs.remove(host.id) }
                                    }
                                )) {
                                    manualHosts.removeAll { $0.id == host.id }
                                    selectedManualGraphIDs.remove(host.id)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Revert") { loadDrafts() }
                    .disabled(!hasChanges)
                Button("Save Host Changes") { saveHosts() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }
        }
        .padding(20)
        .onAppear {
            if !hasLoadedDrafts {
                loadDrafts()
                hasLoadedDrafts = true
            }
        }
    }

    private var discoveredHosts: [HostRecord] {
        store.hosts.filter { $0.source == .bonjour }
    }

    private var storedManualGraphIDs: Set<UUID> {
        Set(store.manualHosts.filter { store.showsMenuBarGraph(for: "manual-\($0.id.uuidString)") }.map(\.id))
    }

    private var hasChanges: Bool {
        manualHosts != store.manualHosts || selectedManualGraphIDs != storedManualGraphIDs
    }

    private func graphBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { store.showsMenuBarGraph(for: key) },
            set: { store.setMenuBarGraphVisible($0, for: key) }
        )
    }

    private func loadDrafts() {
        manualHosts = store.manualHosts
        selectedManualGraphIDs = storedManualGraphIDs
    }

    private func saveHosts() {
        store.replaceManualHosts(manualHosts)
        let otherKeys = store.menuBarGraphHostKeys.filter { !$0.hasPrefix("manual-") }
        let manualKeys = selectedManualGraphIDs.intersection(Set(manualHosts.map(\.id)))
            .map { "manual-\($0.uuidString)" }
        store.updateMenuBarGraphHosts(Set(otherKeys).union(manualKeys))
        loadDrafts()
    }
}

private struct ManualHostRow: View {
    @Binding var host: ManualHostEntry
    @Binding var showsMenuBarGraph: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Optional name", text: $host.displayName)
                .textFieldStyle(.roundedBorder)

            TextField("ssh.example.net", text: $host.hostname)
                .textFieldStyle(.roundedBorder)

            TextField(
                "22",
                value: $host.port,
                format: .number.grouping(.never)
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)

            Toggle("Menu bar graph", isOn: $showsMenuBarGraph)
                .labelsHidden()
                .help("Show ping graph in menu bar")
                .frame(width: 108)

            Button("Remove", role: .destructive, action: onRemove)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ConnectionsSettingsTab: View {
    @ObservedObject var store: HostStore
    @ObservedObject var linkServer: HostigLinkSourceServer
    @ObservedObject var reversePusher: HostigReverseSnapshotPusher

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reverse Connection")
                        .font(.title3.weight(.semibold))
                    Text("Send snapshots outbound to a visionOS device when inbound Mac connections are blocked.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("visionOS Devices")
                    .font(.headline)

                if reversePusher.receivers.isEmpty {
                    Text("No reverse receivers found. Open Hostig on visionOS and use the PIN shown there.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    List(reversePusher.receivers) { receiver in
                        Button {
                            reversePusher.selectedReceiverID = receiver.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(receiver.name)
                                        .font(.body.weight(.medium))
                                    Text(receiver.endpointDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if reversePusher.selectedReceiverID == receiver.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: 170)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pairing PIN")
                        .font(.headline)
                    if reversePusher.hasRememberedPairingForSelectedReceiver {
                        Text("Remembered")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                TextField(reversePusher.hasRememberedPairingForSelectedReceiver ? "Optional" : "000000", text: $reversePusher.pin)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .onChange(of: reversePusher.pin) { _, newValue in
                        reversePusher.pin = String(newValue.filter(\.isNumber).prefix(6))
                    }
            }

            if let errorMessage = reversePusher.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Disconnect Reverse Pairing", role: .destructive) {
                    reversePusher.disconnectPairing()
                }
                    .buttonStyle(.bordered)
                    .disabled(reversePusher.selectedReceiver == nil && !reversePusher.isConnected)

                Spacer()

                Button(reversePusher.isConnecting ? "Connecting" : "Connect") {
                    reversePusher.connect(provider: store, identity: macLinkIdentity)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reversePusher.canConnect)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Incoming Pairings").font(.headline)
                    Text("Forget devices paired with this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget Pairings", role: .destructive) {
                    linkServer.disconnectPairings()
                }
            }
        }
        .padding(24)
    }

    private var macLinkIdentity: HostigLinkIdentity {
        .persisted(
            storageKey: "nu.dll.hostig.mac.appInstanceID",
            deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            platform: "macOS"
        )
    }
}

private struct LatencyPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let host: String
    let snapshot: PingSnapshot?
    let history: [PingHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latency Monitor")
                        .font(.headline)
                    Text(host)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 14) {
                LatencyStat(
                    title: "Avg",
                    value: snapshot?.latencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a",
                    prominent: true
                )

                LatencyStat(
                    title: "Min",
                    value: snapshot?.minLatencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a"
                )

                LatencyStat(
                    title: "Max",
                    value: snapshot?.maxLatencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a"
                )

                LatencyStat(
                    title: "Std Dev",
                    value: snapshot?.standardDeviationMS.map { String(format: "%.1f ms", $0) } ?? "n/a"
                )

                if let packetLoss = snapshot?.packetLossPercent {
                    LatencyStat(
                        title: "Loss",
                        value: String(format: "%.0f%%", packetLoss)
                    )
                }
            }

            MiniLatencyGraph(history: history)
                .frame(height: 88)
        }
        .padding(16)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        )
    }

    private var panelFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.72)
    }

    private var panelStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
    }
}

private struct LatencyStat: View {
    let title: String
    let value: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(prominent ? .system(size: 24, weight: .semibold, design: .rounded) : .title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct MiniLatencyGraph: View {
    @Environment(\.colorScheme) private var colorScheme
    let history: [PingHistoryPoint]
    private let maxRenderedPoints = 400
    private let topLabelHeight: CGFloat = 12
    private let bottomLabelHeight: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let renderedHistory = self.renderedHistory
            let values = renderedHistory.compactMap(\.latencyMS)
            let maxValue = max(values.max() ?? 1, 1)
            let inset: CGFloat = 5
            let graphWidth = max(1, geometry.size.width - (inset * 2))
            let graphHeight = max(1, geometry.size.height - topLabelHeight - bottomLabelHeight - (inset * 2))
            let plotTop = inset + topLabelHeight
            let plotBottom = geometry.size.height - inset - bottomLabelHeight

            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 6) {
                        Capsule()
                            .fill(Color.teal.opacity(colorScheme == .dark ? 0.88 : 0.78))
                            .frame(width: 14, height: 2)
                        Text("Latency")
                        Spacer(minLength: 8)
                        Text("max \(Self.formatLatency(maxValue))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)

                    HStack {
                        Text(timeRangeLabel)
                        Spacer(minLength: 8)
                        Text("0 ms")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                if renderedHistory.count > 1 {
                    Path { path in
                        var started = false
                        for (index, point) in renderedHistory.enumerated() {
                            guard let latency = point.latencyMS else {
                                started = false
                                continue
                            }

                            let x = inset + (graphWidth * CGFloat(index) / CGFloat(max(renderedHistory.count - 1, 1)))
                            let y = plotTop + graphHeight - ((CGFloat(latency) / CGFloat(maxValue)) * graphHeight)
                            let cgPoint = CGPoint(x: x, y: max(plotTop, min(plotBottom, y)))

                            if started {
                                path.addLine(to: cgPoint)
                            } else {
                                path.move(to: cgPoint)
                                started = true
                            }
                        }
                    }
                    .stroke(
                        Color.teal.opacity(colorScheme == .dark ? 0.88 : 0.78),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    private var renderedHistory: [PingHistoryPoint] {
        guard history.count > maxRenderedPoints else { return history }
        return Array(history.suffix(maxRenderedPoints))
    }

    private var timeRangeLabel: String {
        guard let first = renderedHistory.first?.timestamp,
              let last = renderedHistory.last?.timestamp else {
            return "time"
        }

        let minutes = max(1, Int(last.timeIntervalSince(first) / 60))
        if minutes < 60 {
            return "~\(minutes)m ago"
        }

        let hours = max(1, Int(round(Double(minutes) / 60)))
        return "~\(hours)h ago"
    }

    private static func formatLatency(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.1f ms", value)
        }
        return String(format: "%.0f ms", value)
    }
}

private struct SummaryPill: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    let title: String
    let value: String
    var revealsValueOnHover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            valueText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(pillFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(pillStroke, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .accessibilityValue(accessibilityValue)
        .help(revealsValueOnHover ? "Hover to reveal" : value)
    }

    private var displayValue: String {
        guard revealsValueOnHover, !isHovering else { return value }
        return String(repeating: "*", count: value.count)
    }

    private var accessibilityValue: String {
        revealsValueOnHover && !isHovering ? "Hidden" : value
    }

    @ViewBuilder
    private var valueText: some View {
        let text = Text(displayValue)
            .font(.headline.monospacedDigit().weight(.semibold))

        if revealsValueOnHover && !isHovering {
            text
        } else {
            text.textSelection(.enabled)
        }
    }

    private var pillFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.72)
    }

    private var pillStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.04)
    }
}

private struct HostCard: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let host: HostRecord
    let isRebooting: Bool
    let onReboot: (HostRecord) -> Void
    let onOpenTerminal: (HostRecord) -> Void

    nonisolated static func == (lhs: HostCard, rhs: HostCard) -> Bool {
        lhs.host == rhs.host && lhs.isRebooting == rhs.isRebooting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(host.displayName)
                        .font(.title3.weight(.semibold))
                    Text("\(host.hostname):\(host.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Terminal") {
                        onOpenTerminal(host)
                    }
                    if host.canShowRebootAction {
                        Button(isRebooting ? "Rebooting..." : "Reboot") {
                            onReboot(host)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRebooting)
                    }
                    StatusBadge(state: host.sshState)
                    HStack(spacing: 8) {
                        StatChip(
                            title: "Latency",
                            value: host.ping?.latencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a"
                        )
                        StatChip(
                            title: "Loss",
                            value: host.ping?.packetLossPercent.map { String(format: "%.0f%%", $0) } ?? "n/a"
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ping")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Last ~12 min")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                MiniLatencyGraph(history: host.pingHistory)
                    .frame(height: 42)
            }

            if let metrics = host.metrics {
                HStack(alignment: .top, spacing: 18) {
                    GaugeTile(title: "CPU", value: metrics.cpuPercent / 100, tint: .orange, label: String(format: "%.1f%%", metrics.cpuPercent))
                    GaugeTile(title: "Disk", value: metrics.diskUsedPercent / 100, tint: .blue, label: String(format: "%.0f%%", metrics.diskUsedPercent))
                    GaugeTile(title: "Memory", value: (metrics.memoryUsedPercent ?? 0) / 100, tint: .green, label: metrics.memoryUsedPercent.map { String(format: "%.1f%%", $0) } ?? "n/a")
                    VStack(alignment: .leading, spacing: 10) {
                        DetailsRow(label: "Uptime", value: metrics.uptime)
                        DetailsRow(label: "Load", value: metrics.loadAverage)
                        DetailsRow(label: "Disk Free", value: metrics.diskFree)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        DetailsRow(label: "OS", value: metrics.operatingSystem)
                        DetailsRow(label: "Version", value: metrics.operatingSystemVersion)
                        if metrics.distributionDescription != "Unavailable" {
                            DetailsRow(label: "Distro", value: metrics.distributionDescription)
                        }
                        DetailsRow(label: "Arch", value: metrics.architecture)
                        DetailsRow(label: "Users", value: "\(metrics.userCount)")
                        DetailsRow(label: "Updated", value: metrics.lastUpdated.formatted(date: .omitted, time: .standard))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sshErrorText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let rebootStatus = host.rebootStatus {
                        RebootStatusView(status: rebootStatus)
                    }
                }
            }

            if host.metrics != nil, let rebootStatus = host.rebootStatus {
                RebootStatusView(status: rebootStatus)
            }
        }
        .padding(18)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private var sshErrorText: String {
        if case .metricsUnavailable(let reason) = host.sshState {
            return reason
        }
        if case .unavailable(let reason) = host.sshState {
            return reason
        }
        return "SSH metrics unavailable. Ping continues even when login fails."
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.82)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
    }
}

private struct RebootStatusView: View {
    let status: RebootStatus

    var body: some View {
        switch status {
        case .inProgress:
            Label("Sending reboot command…", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .succeeded(let date):
            Label("Reboot command accepted at \(date.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }
}

private struct PasswordPromptSheet: View {
    let host: HostRecord
    @Binding var password: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sudo Password Required")
                .font(.title3.weight(.semibold))
            Text("Enter the remote sudo password for \(host.displayName) to run `sudo reboot`.")
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button(isSubmitting ? "Sending..." : "Reboot") {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || isSubmitting)
            }
        }
        .padding(24)
    }
}

private struct RebootAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct GaugeTile: View {
    let title: String
    let value: Double
    let tint: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Gauge(value: max(0, min(value, 1))) {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            Text(label)
                .font(.headline.monospacedDigit())
        }
        .frame(width: 110)
    }
}

private struct DetailsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .frame(minWidth: 180)
    }
}

private struct StatChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct StatusBadge: View {
    let state: SSHState

    var body: some View {
        let style = style(for: state)
        Text(style.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(style.background, in: Capsule())
    }

    private func style(for state: SSHState) -> (title: String, foreground: Color, background: Color) {
        switch state {
        case .idle:
            return ("Idle", .secondary, Color.gray.opacity(0.16))
        case .probing:
            return ("Probing SSH", .orange, Color.orange.opacity(0.15))
        case .authenticated:
            return ("SSH OK", .green, Color.green.opacity(0.14))
        case .metricsUnavailable:
            return ("SSH OK, Metrics Failed", .yellow, Color.yellow.opacity(0.18))
        case .unavailable:
            return ("SSH Failed", .red, Color.red.opacity(0.13))
        }
    }
}
