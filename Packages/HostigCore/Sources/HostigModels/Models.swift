import Foundation

public enum HostSource: String, Codable, Equatable, Sendable {
    case bonjour
    case manual
}

public struct ManualHostEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int

    public init(id: UUID = UUID(), displayName: String = "", hostname: String = "", port: Int = 22) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
    }
}

public struct HostMetrics: Codable, Equatable, Sendable {
    public var uptime: String
    public var loadAverage: String
    public var cpuPercent: Double
    public var diskUsedPercent: Double
    public var diskFree: String
    public var memoryUsedPercent: Double?
    public var userCount: Int
    public var operatingSystem: String
    public var operatingSystemVersion: String
    public var architecture: String
    public var lastUpdated: Date

    public init(
        uptime: String,
        loadAverage: String,
        cpuPercent: Double,
        diskUsedPercent: Double,
        diskFree: String,
        memoryUsedPercent: Double?,
        userCount: Int,
        operatingSystem: String,
        operatingSystemVersion: String,
        architecture: String = "Unavailable",
        lastUpdated: Date
    ) {
        self.uptime = uptime
        self.loadAverage = loadAverage
        self.cpuPercent = cpuPercent
        self.diskUsedPercent = diskUsedPercent
        self.diskFree = diskFree
        self.memoryUsedPercent = memoryUsedPercent
        self.userCount = userCount
        self.operatingSystem = operatingSystem
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.lastUpdated = lastUpdated
    }

    private enum CodingKeys: String, CodingKey {
        case uptime
        case loadAverage
        case cpuPercent
        case diskUsedPercent
        case diskFree
        case memoryUsedPercent
        case userCount
        case operatingSystem
        case operatingSystemVersion
        case architecture
        case lastUpdated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uptime = try container.decode(String.self, forKey: .uptime)
        loadAverage = try container.decode(String.self, forKey: .loadAverage)
        cpuPercent = try container.decode(Double.self, forKey: .cpuPercent)
        diskUsedPercent = try container.decode(Double.self, forKey: .diskUsedPercent)
        diskFree = try container.decode(String.self, forKey: .diskFree)
        memoryUsedPercent = try container.decodeIfPresent(Double.self, forKey: .memoryUsedPercent)
        userCount = try container.decode(Int.self, forKey: .userCount)
        operatingSystem = try container.decode(String.self, forKey: .operatingSystem)
        operatingSystemVersion = try container.decode(String.self, forKey: .operatingSystemVersion)
        architecture = try container.decodeIfPresent(String.self, forKey: .architecture) ?? "Unavailable"
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uptime, forKey: .uptime)
        try container.encode(loadAverage, forKey: .loadAverage)
        try container.encode(cpuPercent, forKey: .cpuPercent)
        try container.encode(diskUsedPercent, forKey: .diskUsedPercent)
        try container.encode(diskFree, forKey: .diskFree)
        try container.encodeIfPresent(memoryUsedPercent, forKey: .memoryUsedPercent)
        try container.encode(userCount, forKey: .userCount)
        try container.encode(operatingSystem, forKey: .operatingSystem)
        try container.encode(operatingSystemVersion, forKey: .operatingSystemVersion)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
}

public enum SSHState: Codable, Equatable, Sendable {
    case idle
    case probing
    case authenticated
    case metricsUnavailable(String)
    case unavailable(String)
}

public struct PingSnapshot: Codable, Equatable, Sendable {
    public var latencyMS: Double?
    public var packetLossPercent: Double?
    public var lastUpdated: Date

    public init(latencyMS: Double?, packetLossPercent: Double?, lastUpdated: Date) {
        self.latencyMS = latencyMS
        self.packetLossPercent = packetLossPercent
        self.lastUpdated = lastUpdated
    }
}

public struct PingHistoryPoint: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var timestamp: Date
    public var latencyMS: Double?

    public init(id: UUID = UUID(), timestamp: Date, latencyMS: Double?) {
        self.id = id
        self.timestamp = timestamp
        self.latencyMS = latencyMS
    }
}

public struct HostRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var source: HostSource
    public var serviceName: String
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var lastResolved: Date
    public var sshState: SSHState
    public var ping: PingSnapshot?
    public var pingHistory: [PingHistoryPoint]
    public var metrics: HostMetrics?
    public var rebootStatus: RebootStatus?

    public init(
        id: UUID = UUID(),
        source: HostSource = .bonjour,
        serviceName: String,
        displayName: String,
        hostname: String,
        port: Int,
        lastResolved: Date = .now,
        sshState: SSHState = .idle,
        ping: PingSnapshot? = nil,
        pingHistory: [PingHistoryPoint] = [],
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
        self.pingHistory = pingHistory
        self.metrics = metrics
        self.rebootStatus = rebootStatus
    }
}

public extension HostRecord {
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

public struct ResolvedSSHService: Codable, Equatable, Sendable {
    public var serviceName: String
    public var hostname: String
    public var port: Int
    public var domain: String

    public init(serviceName: String, hostname: String, port: Int, domain: String) {
        self.serviceName = serviceName
        self.hostname = hostname
        self.port = port
        self.domain = domain
    }
}

public enum RebootStatus: Codable, Equatable, Sendable {
    case inProgress
    case succeeded(Date)
    case failed(String)
}

public enum RebootResolution: Codable, Equatable, Sendable {
    case started
    case passwordRequired
}

public enum RebootAttemptResult: Equatable, Sendable {
    case success(RebootResolution)
    case failure(String)
}

public enum PasswordRebootResult: Equatable, Sendable {
    case success
    case failure(String)
}
