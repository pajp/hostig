import Foundation
import HostigModels

public enum HostigLinkService {
    public static let bonjourType = "_hostig._tcp"
    public static let bonjourDomain = "local."
    public static let snapshotPath = "/snapshot"
    public static let protocolVersion = 1
    public static let pairingPINLength = 6
    public static let cryptoSalt = "HostigLink.v1"
}

public struct HostigLinkIdentity: Codable, Equatable, Sendable {
    public var appInstanceID: UUID
    public var deviceName: String
    public var platform: String

    public init(appInstanceID: UUID, deviceName: String, platform: String) {
        self.appInstanceID = appInstanceID
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct HostigSnapshot: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var identity: HostigLinkIdentity
    public var generatedAt: Date
    public var latencyMonitorHost: String
    public var latencyMonitorSnapshot: PingSnapshot?
    public var latencyHistory: [PingHistoryPoint]
    public var hosts: [HostRecord]

    public init(
        protocolVersion: Int = HostigLinkService.protocolVersion,
        identity: HostigLinkIdentity,
        generatedAt: Date = .now,
        latencyMonitorHost: String,
        latencyMonitorSnapshot: PingSnapshot?,
        latencyHistory: [PingHistoryPoint],
        hosts: [HostRecord]
    ) {
        self.protocolVersion = protocolVersion
        self.identity = identity
        self.generatedAt = generatedAt
        self.latencyMonitorHost = latencyMonitorHost
        self.latencyMonitorSnapshot = latencyMonitorSnapshot
        self.latencyHistory = latencyHistory
        self.hosts = hosts
    }
}

public protocol HostigSnapshotProvider: Sendable {
    func currentSnapshot(identity: HostigLinkIdentity) async -> HostigSnapshot
}
