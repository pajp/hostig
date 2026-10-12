import Foundation
import Combine
import HostigLink
import HostigModels

@MainActor
public final class HostStore: NSObject, ObservableObject {
    @Published public private(set) var hosts: [HostRecord] = []
    @Published public private(set) var manualHosts: [ManualHostEntry] = []
    @Published public var discoveryActive = true
    @Published public private(set) var rebootingHostIDs: Set<UUID> = []
    @Published public var latencyMonitorHost: String = "ping.sunet.se"
    @Published public private(set) var latencyMonitorSnapshot: PingSnapshot?
    @Published public private(set) var latencyHistory: [PingHistoryPoint] = []
    @Published public private(set) var menuBarGraphHostKeys: Set<String> = ["latency-monitor"]
    @Published public private(set) var menuBarGraphsUseSharedScale = false

    private let scanner = BonjourScanner()
    private var hostIndexByService: [String: UUID] = [:]
    private var hostIndexByManualID: [UUID: UUID] = [:]
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var statsTasks: [UUID: Task<Void, Never>] = [:]
    private var latencyMonitorTask: Task<Void, Never>?
    private let latencyMonitorInterval: Duration = .seconds(3)
    private let maxLatencyHistoryPoints = 20 * 20
    private let maxPerHostPingHistoryPoints = 60
    private let manualHostsDefaultsKey = "Hostig.manualHosts"
    private let latencyMonitorHostDefaultsKey = "Hostig.latencyMonitorHost"
    private let menuBarGraphDefaultsKey = "Hostig.menuBarGraphHostKeys"
    private let menuBarSharedScaleDefaultsKey = "Hostig.menuBarGraphsUseSharedScale"

    public static let latencyMonitorGraphKey = "latency-monitor"

    public static func menuBarGraphKey(for host: HostRecord) -> String {
        switch host.source {
        case .bonjour: "bonjour:\(host.serviceName)"
        case .manual: host.serviceName
        }
    }

    public override init() {
        super.init()
        if let savedHost = UserDefaults.standard.string(forKey: latencyMonitorHostDefaultsKey),
           !savedHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latencyMonitorHost = savedHost
        }
        if let savedKeys = UserDefaults.standard.stringArray(forKey: menuBarGraphDefaultsKey) {
            menuBarGraphHostKeys = Set(savedKeys)
        }
        menuBarGraphsUseSharedScale = UserDefaults.standard.bool(forKey: menuBarSharedScaleDefaultsKey)
        loadManualHosts()
        scanner.delegate = self
        scanner.start()
        startLatencyMonitor()
    }

    public func toggleDiscovery() {
        discoveryActive.toggle()
        if discoveryActive {
            scanner.start()
        } else {
            scanner.stop()
        }
    }

    public func refreshAll() {
        for host in hosts {
            beginMonitoring(for: host.id)
        }
        restartLatencyMonitor()
    }

    public func updateLatencyMonitorHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != latencyMonitorHost else { return }
        latencyMonitorHost = trimmed
        UserDefaults.standard.set(trimmed, forKey: latencyMonitorHostDefaultsKey)
        latencyHistory.removeAll()
        latencyMonitorSnapshot = nil
        restartLatencyMonitor()
    }

    public func replaceManualHosts(_ entries: [ManualHostEntry]) {
        manualHosts = normalizeManualHosts(entries)
        persistManualHosts()
        syncManualHosts()
    }

    public func showsMenuBarGraph(for key: String) -> Bool {
        menuBarGraphHostKeys.contains(key)
    }

    public func updateMenuBarGraphHosts(_ keys: Set<String>) {
        menuBarGraphHostKeys = keys
        UserDefaults.standard.set(menuBarGraphHostKeys.sorted(), forKey: menuBarGraphDefaultsKey)
    }

    public func setMenuBarGraphVisible(_ visible: Bool, for key: String) {
        var keys = menuBarGraphHostKeys
        if visible { keys.insert(key) }
        else { keys.remove(key) }
        updateMenuBarGraphHosts(keys)
    }

    public func setMenuBarGraphsUseSharedScale(_ enabled: Bool) {
        menuBarGraphsUseSharedScale = enabled
        UserDefaults.standard.set(enabled, forKey: menuBarSharedScaleDefaultsKey)
    }

    public func requestReboot(for id: UUID) async -> RebootAttemptResult {
        guard let host = hosts.first(where: { $0.id == id }) else {
            return .failure("Host no longer exists.")
        }

        rebootingHostIDs.insert(id)
        updateHost(id) { $0.rebootStatus = .inProgress }
        defer { rebootingHostIDs.remove(id) }

        do {
            let resolution = try await SSHService().reboot(host: host.hostname, port: host.port)
            switch resolution {
            case .started:
                updateHost(id) { $0.rebootStatus = .succeeded(.now) }
            case .passwordRequired:
                updateHost(id) { $0.rebootStatus = nil }
            }
            return .success(resolution)
        } catch {
            let message = error.localizedDescription
            updateHost(id) { $0.rebootStatus = .failed(message) }
            return .failure(message)
        }
    }

    public func submitRebootPassword(_ password: String, for id: UUID) async -> PasswordRebootResult {
        guard let host = hosts.first(where: { $0.id == id }) else {
            return .failure("Host no longer exists.")
        }

        rebootingHostIDs.insert(id)
        updateHost(id) { $0.rebootStatus = .inProgress }
        defer { rebootingHostIDs.remove(id) }

        do {
            _ = try await SSHService().reboot(host: host.hostname, port: host.port, sudoPassword: password)
            updateHost(id) { $0.rebootStatus = .succeeded(.now) }
            return .success
        } catch {
            let message = error.localizedDescription
            updateHost(id) { $0.rebootStatus = .failed(message) }
            return .failure(message)
        }
    }

    private func upsert(_ service: ResolvedSSHService) {
        if let id = hostIndexByService[service.serviceName], let index = hosts.firstIndex(where: { $0.id == id }) {
            hosts[index].source = .bonjour
            hosts[index].displayName = service.serviceName
            hosts[index].hostname = service.hostname
            hosts[index].port = service.port
            hosts[index].lastResolved = .now
            sortHosts()
            beginMonitoring(for: id)
            return
        }

        let record = HostRecord(
            source: .bonjour,
            serviceName: service.serviceName,
            displayName: service.serviceName,
            hostname: service.hostname,
            port: service.port
        )
        hostIndexByService[service.serviceName] = record.id
        hosts.append(record)
        sortHosts()
        beginMonitoring(for: record.id)
    }

    private func remove(serviceName: String) {
        guard let id = hostIndexByService.removeValue(forKey: serviceName) else { return }
        removeHost(id: id)
    }

    private func beginMonitoring(for id: UUID) {
        pingTasks[id]?.cancel()
        pingTasks[id] = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let host = await self.host(with: id) else { return }
                do {
                    let snapshot = try await PingService.sample(host: host.hostname)
                    await MainActor.run {
                        self.updateHost(id) {
                            $0.ping = snapshot
                            self.appendHostLatencyPoint(to: &$0.pingHistory, latencyMS: snapshot.latencyMS)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.updateHost(id) {
                            $0.ping = PingSnapshot(latencyMS: nil, packetLossPercent: nil, lastUpdated: .now)
                            self.appendHostLatencyPoint(to: &$0.pingHistory, latencyMS: nil)
                        }
                    }
                }

                try? await Task.sleep(for: .seconds(12))
            }
        }

        statsTasks[id]?.cancel()
        statsTasks[id] = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let host = await self.host(with: id) else { return }
                await MainActor.run {
                    self.updateHost(id) { $0.sshState = .probing }
                }

                let service = SSHService()

                do {
                    try await service.probe(host: host.hostname, port: host.port)
                    await MainActor.run {
                        self.updateHost(id) { $0.sshState = .authenticated }
                    }

                    do {
                        let metrics = try await service.fetchMetrics(host: host.hostname, port: host.port)
                        await MainActor.run {
                            self.updateHost(id) {
                                $0.sshState = .authenticated
                                $0.metrics = metrics
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.updateHost(id) {
                                $0.sshState = .metricsUnavailable(error.localizedDescription)
                                $0.metrics = nil
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.updateHost(id) {
                            $0.sshState = .unavailable(error.localizedDescription)
                            $0.metrics = nil
                        }
                    }
                }

                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func restartLatencyMonitor() {
        latencyMonitorTask?.cancel()
        startLatencyMonitor()
    }

    private func startLatencyMonitor() {
        latencyMonitorTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let monitorHost = await self.latencyMonitorHost

            for await snapshot in PingService.continuousSamples(host: monitorHost, interval: latencyMonitorInterval) {
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    self.latencyMonitorSnapshot = snapshot
                    self.appendLatencyPoint(snapshot.latencyMS)
                }
            }
        }
    }

    private func host(with id: UUID) -> HostRecord? {
        hosts.first { $0.id == id }
    }

    private func updateHost(_ id: UUID, change: (inout HostRecord) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        change(&hosts[index])
    }

    private func loadManualHosts() {
        guard
            let data = UserDefaults.standard.data(forKey: manualHostsDefaultsKey),
            let decoded = try? JSONDecoder().decode([ManualHostEntry].self, from: data)
        else {
            manualHosts = []
            return
        }

        manualHosts = normalizeManualHosts(decoded)
        syncManualHosts()
    }

    private func persistManualHosts() {
        guard let data = try? JSONEncoder().encode(manualHosts) else { return }
        UserDefaults.standard.set(data, forKey: manualHostsDefaultsKey)
    }

    private func syncManualHosts() {
        let activeEntries = manualHosts.filter { !$0.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let activeIDs = Set(activeEntries.map(\.id))

        for manualID in hostIndexByManualID.keys.filter({ !activeIDs.contains($0) }) {
            if let hostID = hostIndexByManualID.removeValue(forKey: manualID) {
                removeHost(id: hostID)
            }
        }

        for entry in activeEntries {
            let displayName = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let hostname = entry.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = displayName.isEmpty ? hostname : displayName

            if let hostID = hostIndexByManualID[entry.id], let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].source = .manual
                hosts[index].serviceName = "manual-\(entry.id.uuidString)"
                hosts[index].displayName = resolvedName
                hosts[index].hostname = hostname
                hosts[index].port = entry.port
                hosts[index].lastResolved = .now
                beginMonitoring(for: hostID)
                continue
            }

            let record = HostRecord(
                source: .manual,
                serviceName: "manual-\(entry.id.uuidString)",
                displayName: resolvedName,
                hostname: hostname,
                port: entry.port
            )
            hostIndexByManualID[entry.id] = record.id
            hosts.append(record)
            beginMonitoring(for: record.id)
        }

        sortHosts()
    }

    private func normalizeManualHosts(_ entries: [ManualHostEntry]) -> [ManualHostEntry] {
        entries.map { entry in
            let trimmedName = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedHost = entry.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPort = max(1, min(entry.port, 65535))
            return ManualHostEntry(id: entry.id, displayName: trimmedName, hostname: trimmedHost, port: normalizedPort)
        }
    }

    private func removeHost(id: UUID) {
        hosts.removeAll { $0.id == id }
        pingTasks[id]?.cancel()
        statsTasks[id]?.cancel()
        pingTasks.removeValue(forKey: id)
        statsTasks.removeValue(forKey: id)
    }

    private func appendLatencyPoint(_ latencyMS: Double?) {
        latencyHistory.append(PingHistoryPoint(timestamp: .now, latencyMS: latencyMS))
        if latencyHistory.count > maxLatencyHistoryPoints {
            latencyHistory.removeFirst(latencyHistory.count - maxLatencyHistoryPoints)
        }
    }

    private func appendHostLatencyPoint(to history: inout [PingHistoryPoint], latencyMS: Double?) {
        history.append(PingHistoryPoint(timestamp: .now, latencyMS: latencyMS))
        if history.count > maxPerHostPingHistoryPoints {
            history.removeFirst(history.count - maxPerHostPingHistoryPoints)
        }
    }

    private func sortHosts() {
        hosts.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

extension HostStore: HostigSnapshotProvider {
    public nonisolated func currentSnapshot(identity: HostigLinkIdentity) async -> HostigSnapshot {
        await MainActor.run {
            HostigSnapshot(
                identity: identity,
                latencyMonitorHost: latencyMonitorHost,
                latencyMonitorSnapshot: latencyMonitorSnapshot,
                latencyHistory: latencyHistory,
                hosts: hosts
            )
        }
    }
}

extension HostStore: BonjourScannerDelegate {
    public nonisolated func scanner(_ scanner: BonjourScanner, didResolve service: ResolvedSSHService) {
        Task { @MainActor in
            self.upsert(service)
        }
    }

    public nonisolated func scanner(_ scanner: BonjourScanner, didRemove serviceName: String) {
        Task { @MainActor in
            self.remove(serviceName: serviceName)
        }
    }
}
