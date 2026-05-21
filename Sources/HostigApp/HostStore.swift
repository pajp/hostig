import Foundation
import Combine

@MainActor
final class HostStore: NSObject, ObservableObject {
    @Published private(set) var hosts: [HostRecord] = []
    @Published private(set) var manualHosts: [ManualHostEntry] = []
    @Published var discoveryActive = true
    @Published private(set) var rebootingHostIDs: Set<UUID> = []
    @Published var latencyMonitorHost: String = "ping.sunet.se"
    @Published private(set) var latencyMonitorSnapshot: PingSnapshot?
    @Published private(set) var latencyHistory: [PingHistoryPoint] = []

    private let scanner = BonjourScanner()
    private var hostIndexByService: [String: UUID] = [:]
    private var hostIndexByManualID: [UUID: UUID] = [:]
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var statsTasks: [UUID: Task<Void, Never>] = [:]
    private var latencyMonitorTask: Task<Void, Never>?
    private let latencyMonitorInterval: Duration = .seconds(1)
    private let maxLatencyHistoryPoints = 20 * 60
    private let manualHostsDefaultsKey = "Hostig.manualHosts"

    override init() {
        super.init()
        loadManualHosts()
        scanner.delegate = self
        scanner.start()
        startLatencyMonitor()
    }

    func toggleDiscovery() {
        discoveryActive.toggle()
        if discoveryActive {
            scanner.start()
        } else {
            scanner.stop()
        }
    }

    func refreshAll() {
        for host in hosts {
            beginMonitoring(for: host.id)
        }
        restartLatencyMonitor()
    }

    func updateLatencyMonitorHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != latencyMonitorHost else { return }
        latencyMonitorHost = trimmed
        latencyHistory.removeAll()
        latencyMonitorSnapshot = nil
        restartLatencyMonitor()
    }

    func replaceManualHosts(_ entries: [ManualHostEntry]) {
        manualHosts = normalizeManualHosts(entries)
        persistManualHosts()
        syncManualHosts()
    }

    func requestReboot(for id: UUID) async -> RebootAttemptResult {
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

    func submitRebootPassword(_ password: String, for id: UUID) async -> PasswordRebootResult {
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
        pingTasks[id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let host = self.hosts.first(where: { $0.id == id }) else { return }
                do {
                    let snapshot = try await PingService.sample(host: host.hostname)
                    self.updateHost(id) { $0.ping = snapshot }
                } catch {
                    self.updateHost(id) {
                        $0.ping = PingSnapshot(latencyMS: nil, packetLossPercent: nil, lastUpdated: .now)
                    }
                }

                try? await Task.sleep(for: .seconds(12))
            }
        }

        statsTasks[id]?.cancel()
        statsTasks[id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let host = self.hosts.first(where: { $0.id == id }) else { return }
                self.updateHost(id) { $0.sshState = .probing }

                let service = SSHService()

                do {
                    try await service.probe(host: host.hostname, port: host.port)
                    self.updateHost(id) { $0.sshState = .authenticated }

                    do {
                        let metrics = try await service.fetchMetrics(host: host.hostname, port: host.port)
                        self.updateHost(id) {
                            $0.sshState = .authenticated
                            $0.metrics = metrics
                        }
                    } catch {
                        self.updateHost(id) {
                            $0.sshState = .metricsUnavailable(error.localizedDescription)
                            $0.metrics = nil
                        }
                    }
                } catch {
                    self.updateHost(id) {
                        $0.sshState = .unavailable(error.localizedDescription)
                        $0.metrics = nil
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
        latencyMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let snapshot = try await PingService.sample(host: self.latencyMonitorHost, count: 1)
                    self.latencyMonitorSnapshot = snapshot
                    self.appendLatencyPoint(snapshot.latencyMS)
                } catch {
                    self.latencyMonitorSnapshot = PingSnapshot(latencyMS: nil, packetLossPercent: nil, lastUpdated: .now)
                    self.appendLatencyPoint(nil)
                }

                try? await Task.sleep(for: latencyMonitorInterval)
            }
        }
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

    private func sortHosts() {
        hosts.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

extension HostStore: BonjourScannerDelegate {
    nonisolated func scanner(_ scanner: BonjourScanner, didResolve service: ResolvedSSHService) {
        Task { @MainActor in
            self.upsert(service)
        }
    }

    nonisolated func scanner(_ scanner: BonjourScanner, didRemove serviceName: String) {
        Task { @MainActor in
            self.remove(serviceName: serviceName)
        }
    }
}
