import Foundation
import Combine

@MainActor
final class HostStore: NSObject, ObservableObject {
    @Published private(set) var hosts: [HostRecord] = []
    @Published var discoveryActive = true
    @Published private(set) var rebootingHostIDs: Set<UUID> = []

    private let scanner = BonjourScanner()
    private var hostIndexByService: [String: UUID] = [:]
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var statsTasks: [UUID: Task<Void, Never>] = [:]

    override init() {
        super.init()
        scanner.delegate = self
        scanner.start()
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
            hosts[index].displayName = service.serviceName
            hosts[index].hostname = service.hostname
            hosts[index].port = service.port
            hosts[index].lastResolved = .now
            sortHosts()
            beginMonitoring(for: id)
            return
        }

        let record = HostRecord(
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
        hosts.removeAll { $0.id == id }
        pingTasks[id]?.cancel()
        statsTasks[id]?.cancel()
        pingTasks.removeValue(forKey: id)
        statsTasks.removeValue(forKey: id)
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

    private func updateHost(_ id: UUID, change: (inout HostRecord) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        change(&hosts[index])
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
