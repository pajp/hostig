import Combine
import HostigLink
import HostigModels
import HostigNetworking
import SwiftUI

struct VisionDashboardView: View {
    @StateObject private var store = VisionCompanionStore()
    @State private var isSourceSidebarVisible = true
    private let hostColumns = [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(520, max(380, geometry.size.width * 0.34))

            HStack(alignment: .top, spacing: 12) {
                if isSourceSidebarVisible {
                    sourceSidebar
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .spatialGlassPanel(depth: 18)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                snapshotContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 18)
            .padding(.bottom, 18)
            .padding(.trailing, 18)
            .padding(.leading, isSourceSidebarVisible ? 0 : 18)
            .background {
                SpatialBackdrop()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.22), value: isSourceSidebarVisible)
        }
        .task {
            store.start()
        }
        .onChange(of: store.selectedSourceID) { _, _ in
            Task { await store.refreshIfReady() }
        }
        .onChange(of: store.pin) { _, newValue in
            if newValue.count == HostigLinkService.pairingPINLength {
                Task { await store.refreshIfReady() }
            }
        }
    }

    private var sourceSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Hostig")
                    .font(.title.weight(.semibold))

                Spacer()

                Button {
                    isSourceSidebarVisible = false
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .help("Hide sources")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            sourceRows

            VStack(alignment: .leading, spacing: 10) {
                Text("Pairing PIN")
                    .font(.headline)
                if store.hasRememberedPairingForSelectedSource {
                    Text("Remembered")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                TextField(store.hasRememberedPairingForSelectedSource ? "Optional" : "000000", text: $store.pin)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .onChange(of: store.pin) { _, newValue in
                        store.pin = String(newValue.filter(\.isNumber).prefix(6))
                    }

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Connecting" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canRefresh)

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .offset(z: 8)
        }
    }

    private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
                .padding(.horizontal, 4)

            if store.sources.isEmpty {
                Text("No Hostig Macs found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.sources) { source in
                            sourceButton(for: source)
                        }
                    }
                }
                .scrollClipDisabled()
                .frame(maxHeight: min(220, CGFloat(store.sources.count) * 72))
            }
        }
        .padding(.horizontal, 12)
        .offset(z: 8)
    }

    private func sourceButton(for source: HostigDiscoveredSource) -> some View {
        Button {
            store.selectedSourceID = source.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(source.endpointDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                store.selectedSourceID == source.id ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    @ViewBuilder
    private var snapshotContent: some View {
        if let snapshot = store.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isSourceSidebarVisible {
                        sourceToggleButton
                            .offset(z: 30)
                            .transition(.opacity)
                    }

                    HeaderPanel(snapshot: snapshot, isRefreshing: store.isRefreshing) {
                        Task { await store.refresh() }
                    }

                    LazyVGrid(columns: hostColumns, alignment: .leading, spacing: 12) {
                        ForEach(snapshot.hosts) { host in
                            VisionHostCard(host: host)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        } else {
            ContentUnavailableView(
                store.emptyStateTitle,
                systemImage: store.emptyStateSystemImage,
                description: Text(store.emptyStateDescription)
            )
            .padding(28)
            .spatialGlassPanel(depth: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if !isSourceSidebarVisible {
                    sourceToggleButton
                        .padding(18)
                        .offset(z: 30)
                        .transition(.opacity)
                }
            }
        }
    }

    private var sourceToggleButton: some View {
        Button {
            isSourceSidebarVisible = true
        } label: {
            Label("Sources", systemImage: "sidebar.left")
        }
        .buttonStyle(.bordered)
        .help("Show sources")
    }
}

@MainActor
private final class VisionCompanionStore: ObservableObject {
    @Published var sources: [HostigDiscoveredSource] = []
    @Published var selectedSourceID: String?
    @Published var pin = ""
    @Published var snapshot: HostigSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var didAttemptRefresh = false

    private let browser = HostigBonjourSourceBrowser()
    private let pairingStore = HostigLinkPairingStore(role: .vision)
    private let identity = HostigLinkIdentity.persisted(
        storageKey: "nu.dll.hostig.vision.appInstanceID",
        deviceName: "Hostig Vision",
        platform: "visionOS"
    )
    private var sourceUpdates: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var lastSelectedSource: HostigDiscoveredSource?
    private var rememberedSources: [String: HostigRememberedSource] = [:]

    var canRefresh: Bool {
        guard let selectedSource, !isRefreshing else { return false }
        return pin.count == HostigLinkService.pairingPINLength || hasRememberedPairing(for: selectedSource)
    }

    var hasRememberedPairingForSelectedSource: Bool {
        selectedSource.map(hasRememberedPairing(for:)) ?? false
    }

    var emptyStateTitle: String {
        if isRefreshing {
            return "Connecting to Hostig"
        }
        if errorMessage != nil {
            return "Could Not Load Snapshot"
        }
        if selectedSource == nil {
            return "Select a Hostig Mac"
        }
        if !hasRememberedPairingForSelectedSource && pin.count != HostigLinkService.pairingPINLength {
            return "Enter Pairing PIN"
        }
        return didAttemptRefresh ? "No Snapshot Yet" : "Ready to Connect"
    }

    var emptyStateSystemImage: String {
        if isRefreshing {
            return "arrow.triangle.2.circlepath"
        }
        if errorMessage != nil {
            return "exclamationmark.triangle"
        }
        return "visionpro"
    }

    var emptyStateDescription: String {
        if let errorMessage {
            return errorMessage
        }
        if selectedSource == nil {
            return "Choose one of the Hostig Macs discovered on your local network."
        }
        if hasRememberedPairingForSelectedSource {
            return "Tap Refresh to load the current host snapshot."
        }
        if pin.count != HostigLinkService.pairingPINLength {
            return "Enter the 6-digit PIN shown by the Mac app to pair with this source."
        }
        return "Tap Refresh to load the current host snapshot."
    }

    private var selectedSource: HostigDiscoveredSource? {
        if let selectedSourceID, let source = sources.first(where: { $0.id == selectedSourceID }) {
            return source
        }
        if lastSelectedSource?.id == selectedSourceID {
            return lastSelectedSource
        }
        return nil
    }

    func start() {
        guard sourceUpdates == nil else { return }

        rememberedSources = pairingStore.rememberedSources()
        sourceUpdates = browser.$sources.sink { [weak self] sources in
            guard let self else { return }
            self.sources = sources
            if let selectedSourceID = self.selectedSourceID,
               let source = sources.first(where: { $0.id == selectedSourceID }) {
                self.lastSelectedSource = source
            } else if self.selectedSourceID == nil {
                let rememberedEndpoint = self.pairingStore.lastSourceEndpointDescription
                let rememberedSource = rememberedEndpoint.flatMap { endpoint in
                    sources.first { $0.endpointDescription == endpoint }
                }
                let source = rememberedSource ?? sources.first
                self.selectedSourceID = source?.id
                self.lastSelectedSource = source
                if source != nil {
                    Task { await self.refreshIfReady() }
                }
            }
        }
        browser.start()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.refreshIfReady()
            }
        }
    }

    func refreshIfReady() async {
        guard canRefresh else { return }
        await refresh()
    }

    func refresh() async {
        guard let selectedSource else { return }
        lastSelectedSource = selectedSource
        let currentPIN = pin
        let sourceName = selectedSource.name
        isRefreshing = true
        didAttemptRefresh = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let transport = HostigTCPSnapshotTransport(identity: identity, pairingStore: pairingStore)
            snapshot = try await transport.fetchSnapshot(from: selectedSource, pin: currentPIN)
            rememberedSources = pairingStore.rememberedSources()
            pin = ""
        } catch {
            errorMessage = "Could not connect to \(sourceName): \(error.localizedDescription)"
        }
    }

    private func hasRememberedPairing(for source: HostigDiscoveredSource) -> Bool {
        guard let rememberedSource = rememberedSources[source.endpointDescription] else {
            return false
        }
        return pairingStore.keyData(for: rememberedSource.keyID) != nil
    }

    deinit {
        refreshTask?.cancel()
    }
}

private struct SpatialBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.cyan.opacity(0.12),
                    Color.indigo.opacity(0.08),
                    Color.green.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct SpatialGlassPanel: ViewModifier {
    let depth: CGFloat

    func body(content: Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.05))
                .offset(y: 10)
                .offset(z: -depth)
                .blur(radius: 10)

            content
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 28, y: 18)
                .offset(z: depth)
        }
    }
}

private extension View {
    func spatialGlassPanel(depth: CGFloat) -> some View {
        modifier(SpatialGlassPanel(depth: depth))
    }
}

private struct HeaderPanel: View {
    let snapshot: HostigSnapshot
    let isRefreshing: Bool
    let refresh: () -> Void
    private let summaryColumns = [GridItem(.adaptive(minimum: 108), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    headerTitle
                    Spacer()
                    refreshButton
                }

                VStack(alignment: .leading, spacing: 12) {
                    headerTitle
                    refreshButton
                }
            }

            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 8) {
                SummaryPill(title: "Hosts", value: "\(snapshot.hosts.count)")
                SummaryPill(title: "Authed", value: "\(snapshot.hosts.filter(\.hasAuthenticatedSSH).count)")
                SummaryPill(title: "No SSH", value: "\(snapshot.hosts.filter { !$0.hasAuthenticatedSSH }.count)")
                SummaryPill(title: "Latency", value: snapshot.latencyMonitorSnapshot?.latencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a")
            }

            MiniLatencyGraph(history: snapshot.latencyHistory)
                .frame(height: 88)
        }
        .padding(20)
        .spatialGlassPanel(depth: 24)
        .hoverEffect(.lift)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.identity.deviceName)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Updated \(snapshot.generatedAt.formatted(date: .omitted, time: .standard))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshing)
    }
}

private struct VisionHostCard: View {
    let host: HostRecord
    private let statusColumns = [GridItem(.adaptive(minimum: 82), spacing: 8, alignment: .leading)]
    private let gaugeColumns = [GridItem(.adaptive(minimum: 86, maximum: 120), spacing: 14, alignment: .leading)]
    private let detailsColumns = [GridItem(.adaptive(minimum: 165), spacing: 18, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                hostTitle
                LazyVGrid(columns: statusColumns, alignment: .leading, spacing: 8) {
                    StatusBadge(state: host.sshState)
                    StatChip(title: "Latency", value: host.ping?.latencyMS.map { String(format: "%.1f ms", $0) } ?? "n/a")
                    StatChip(title: "Loss", value: host.ping?.packetLossPercent.map { String(format: "%.0f%%", $0) } ?? "n/a")
                }
            }

            MiniLatencyGraph(history: host.pingHistory)
                .frame(height: 48)

            if let metrics = host.metrics {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: gaugeColumns, alignment: .leading, spacing: 12) {
                        GaugeTile(title: "CPU", value: metrics.cpuPercent / 100, tint: .orange, label: String(format: "%.1f%%", metrics.cpuPercent))
                        GaugeTile(title: "Disk", value: metrics.diskUsedPercent / 100, tint: .blue, label: String(format: "%.0f%%", metrics.diskUsedPercent))
                        GaugeTile(title: "Memory", value: (metrics.memoryUsedPercent ?? 0) / 100, tint: .green, label: metrics.memoryUsedPercent.map { String(format: "%.1f%%", $0) } ?? "n/a")
                    }
                    LazyVGrid(columns: detailsColumns, alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            DetailsRow(label: "Uptime", value: metrics.uptime)
                            DetailsRow(label: "Load", value: metrics.loadAverage)
                            DetailsRow(label: "Disk Free", value: metrics.diskFree)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            DetailsRow(label: "OS", value: metrics.operatingSystem)
                            DetailsRow(label: "Version", value: metrics.operatingSystemVersion)
                            DetailsRow(label: "Arch", value: metrics.architecture)
                            DetailsRow(label: "Users", value: "\(metrics.userCount)")
                            DetailsRow(label: "Updated", value: metrics.lastUpdated.formatted(date: .omitted, time: .standard))
                        }
                    }
                }
            } else {
                Text(sshErrorText)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .spatialGlassPanel(depth: 16)
        .hoverEffect(.lift)
    }

    private var hostTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("\(host.hostname):\(host.port)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
}

private struct MiniLatencyGraph: View {
    let history: [PingHistoryPoint]
    private let maxRenderedPoints = 120

    var body: some View {
        GeometryReader { geometry in
            let renderedHistory = downsampledHistory
            let values = renderedHistory.compactMap(\.latencyMS)
            let maxValue = max(values.max() ?? 1, 1)
            let inset: CGFloat = 7
            let graphWidth = max(1, geometry.size.width - (inset * 2))
            let graphHeight = max(1, geometry.size.height - (inset * 2))

            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.secondary.opacity(0.08))
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                if renderedHistory.count > 1 {
                    Path { path in
                        var started = false
                        for (index, point) in renderedHistory.enumerated() {
                            guard let latency = point.latencyMS else {
                                started = false
                                continue
                            }

                            let x = inset + (graphWidth * CGFloat(index) / CGFloat(max(renderedHistory.count - 1, 1)))
                            let y = inset + graphHeight - ((CGFloat(latency) / CGFloat(maxValue)) * graphHeight)
                            let cgPoint = CGPoint(x: x, y: max(inset, min(geometry.size.height - inset, y)))

                            if started {
                                path.addLine(to: cgPoint)
                            } else {
                                path.move(to: cgPoint)
                                started = true
                            }
                        }
                    }
                    .stroke(.cyan.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: .cyan.opacity(0.28), radius: 8)
                    .offset(z: 8)
                }
            }
        }
    }

    private var downsampledHistory: [PingHistoryPoint] {
        guard history.count > maxRenderedPoints else { return history }

        let stride = Double(history.count - 1) / Double(maxRenderedPoints - 1)
        return (0..<maxRenderedPoints).map { index in
            history[Int((Double(index) * stride).rounded())]
        }
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(z: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(z: 8)
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
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(z: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
