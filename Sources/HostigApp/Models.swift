import Foundation

enum HostSource: String, Codable, Equatable {
    case bonjour
    case manual
}

struct ManualHostEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var hostname: String
    var port: Int

    init(id: UUID = UUID(), displayName: String = "", hostname: String = "", port: Int = 22) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
    }
}

struct HostMetrics: Equatable {
    var uptime: String
    var loadAverage: String
    var cpuPercent: Double
    var diskUsedPercent: Double
    var diskFree: String
    var memoryUsedPercent: Double?
    var userCount: Int
    var operatingSystem: String
    var operatingSystemVersion: String
    var lastUpdated: Date
}

enum SSHState: Equatable {
    case idle
    case probing
    case authenticated
    case metricsUnavailable(String)
    case unavailable(String)
}

struct PingSnapshot: Equatable {
    var latencyMS: Double?
    var packetLossPercent: Double?
    var lastUpdated: Date
}

struct PingHistoryPoint: Identifiable, Equatable {
    let id: UUID
    var timestamp: Date
    var latencyMS: Double?

    init(id: UUID = UUID(), timestamp: Date, latencyMS: Double?) {
        self.id = id
        self.timestamp = timestamp
        self.latencyMS = latencyMS
    }
}

struct HostRecord: Identifiable, Equatable {
    let id: UUID
    var source: HostSource
    var serviceName: String
    var displayName: String
    var hostname: String
    var port: Int
    var lastResolved: Date
    var sshState: SSHState
    var ping: PingSnapshot?
    var metrics: HostMetrics?
    var rebootStatus: RebootStatus?

    init(
        id: UUID = UUID(),
        source: HostSource = .bonjour,
        serviceName: String,
        displayName: String,
        hostname: String,
        port: Int,
        lastResolved: Date = .now,
        sshState: SSHState = .idle,
        ping: PingSnapshot? = nil,
        metrics: HostMetrics? = nil,
        rebootStatus: RebootStatus? = nil
    ) {
        self.id = id
        self.source = source
        self.serviceName = serviceName
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.lastResolved = lastResolved
        self.sshState = sshState
        self.ping = ping
        self.metrics = metrics
        self.rebootStatus = rebootStatus
    }
}

extension HostRecord {
    var hasAuthenticatedSSH: Bool {
        switch sshState {
        case .authenticated, .metricsUnavailable:
            return true
        case .idle, .probing, .unavailable:
            return false
        }
    }

    var canShowRebootAction: Bool {
        hasAuthenticatedSSH || metrics != nil || rebootStatus != nil
    }
}

struct ResolvedSSHService: Equatable {
    var serviceName: String
    var hostname: String
    var port: Int
    var domain: String
}

enum RebootStatus: Equatable {
    case inProgress
    case succeeded(Date)
    case failed(String)
}

enum RebootResolution: Equatable {
    case started
    case passwordRequired
}

enum RebootAttemptResult: Equatable {
    case success(RebootResolution)
    case failure(String)
}

enum PasswordRebootResult: Equatable {
    case success
    case failure(String)
}
