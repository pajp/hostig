import Combine
import HostigLink
import HostigModels
import HostigNetworking
import SwiftUI

struct VisionDashboardView: View {
    @StateObject private var store = VisionCompanionStore()

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(300, max(220, geometry.size.width * 0.32))

            HStack(spacing: 0) {
                sourceSidebar
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)

                Divider()

                snapshotContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        VStack(alignment: .leading, spacing: 18) {
            Text("Hostig")
                .font(.largeTitle.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 24)

            List(selection: $store.selectedSourceID) {
                Section("Sources") {
                    if store.sources.isEmpty {
                        Text("No Hostig Macs found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.body.weight(.medium))
                                Text(source.endpointDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(source.id)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Pairing PIN")
                    .font(.headline)
                TextField("000000", text: $store.pin)
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
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var snapshotContent: some View {
        if let snapshot = store.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderPanel(snapshot: snapshot, isRefreshing: store.isRefreshing) {
                        Task { await store.refresh() }
                    }

                    LazyVStack(spacing: 14) {
                        ForEach(snapshot.hosts) { host in
                            VisionHostCard(host: host)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.thinMaterial)
        } else {
            ContentUnavailableView(
                store.emptyStateTitle,
                systemImage: store.emptyStateSystemImage,
                description: Text(store.emptyStateDescription)
            )
        }
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
    private let identity = HostigLinkIdentity(
        appInstanceID: UUID(),
        deviceName: "Hostig Vision",
        platform: "visionOS"
    )
    private var sourceUpdates: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var lastSelectedSource: HostigDiscoveredSource?

    var canRefresh: Bool {
        selectedSource != nil && pin.count == HostigLinkService.pairingPINLength && !isRefreshing
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
        if pin.count != HostigLinkService.pairingPINLength {
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

        sourceUpdates = browser.$sources.sink { [weak self] sources in
            guard let self else { return }
            self.sources = sources
            if let selectedSourceID = self.selectedSourceID,
               let source = sources.first(where: { $0.id == selectedSourceID }) {
                self.lastSelectedSource = source
            } else if self.selectedSourceID == nil {
                self.selectedSourceID = sources.first?.id
                self.lastSelectedSource = sources.first
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
        let pin = pin
        let sourceName = selectedSource.name
        isRefreshing = true
        didAttemptRefresh = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let transport = HostigUDPSnapshotTransport(identity: identity)
            snapshot = try await transport.fetchSnapshot(from: selectedSource, pin: pin)
        } catch {
            errorMessage = "Could not connect to \(sourceName): \(error.localizedDescription)"
        }
    }

    deinit {
        refreshTask?.cancel()
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
