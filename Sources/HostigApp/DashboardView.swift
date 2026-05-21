import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: HostStore
    @ObservedObject var mainWindowBridge: MainWindowBridge
    let statusBarController: StatusBarController
    @State private var passwordPromptHost: HostRecord?
    @State private var sudoPassword = ""
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
                            )
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 0.98),
                    Color(red: 0.90, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
        .background(WindowAccessor(mainWindowBridge: mainWindowBridge))
        .task {
            statusBarController.configureIfNeeded(store: store, mainWindowBridge: mainWindowBridge)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            SummaryPill(title: "Hosts", value: "\(store.hosts.count)")
            SummaryPill(title: "Authed", value: "\(store.hosts.filter(\.hasAuthenticatedSSH).count)")
            SummaryPill(title: "No SSH", value: "\(store.hosts.filter { !$0.hasAuthenticatedSSH }.count)")

            Divider()
                .frame(height: 26)

            Button(store.discoveryActive ? "Pause Discovery" : "Resume Discovery") {
                store.toggleDiscovery()
            }
            .buttonStyle(.bordered)

            Button("Refresh Now") {
                store.refreshAll()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
            Text("The app scans for `_ssh._tcp` on the local network and will start ping and SSH probes as hosts appear.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HostCard: View {
    let host: HostRecord
    let isRebooting: Bool
    let onReboot: (HostRecord) -> Void

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
                VStack(alignment: .trailing, spacing: 8) {
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
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
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
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
