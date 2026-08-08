import Combine
import CryptoKit
import Darwin
import Foundation
import HostigLink
import HostigModels
@preconcurrency import Network
import OSLog

private let linkLogger = Logger(subsystem: "nu.dll.hostig", category: "HostigLink")

public enum HostigTransportKind: String, Codable, Equatable, Sendable {
    case udpBonjour
    case tcp
    case sshBounce
    case https
}

public struct HostigDiscoveredSource: Identifiable, Equatable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let endpointDescription: String
    public let transportKind: HostigTransportKind
    let endpoint: NWEndpoint
    let serviceName: String?
    let serviceType: String?
    let serviceDomain: String?

    init(
        name: String,
        endpointDescription: String,
        transportKind: HostigTransportKind,
        endpoint: NWEndpoint,
        serviceName: String? = nil,
        serviceType: String? = nil,
        serviceDomain: String? = nil
    ) {
        self.id = "\(transportKind.rawValue):\(endpointDescription)"
        self.name = name
        self.endpointDescription = endpointDescription
        self.transportKind = transportKind
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.serviceDomain = serviceDomain
    }
}

@MainActor
public protocol HostigSourceDiscovery: ObservableObject {
    var sources: [HostigDiscoveredSource] { get }
    func start()
    func stop()
}

public protocol HostigSnapshotTransport {
    var kind: HostigTransportKind { get }
    func fetchSnapshot(from source: HostigDiscoveredSource, pin: String) async throws -> HostigSnapshot
}

public enum HostigNetworkingError: LocalizedError {
    case invalidPIN
    case missingSnapshot
    case unsupportedTransport
    case timedOut
    case connectionFailed(String)
    case protocolMismatch
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPIN:
            return "Enter the 6-digit PIN shown on the Mac."
        case .missingSnapshot:
            return "The source did not return a snapshot."
        case .unsupportedTransport:
            return "This source uses an unsupported transport."
        case .timedOut:
            return "The source did not respond."
        case .connectionFailed(let message):
            return message
        case .protocolMismatch:
            return "The source is using an incompatible Hostig link protocol."
        case .decryptionFailed:
            return "Pairing failed. Check the PIN shown on the Mac."
        }
    }
}

@MainActor
public final class HostigBonjourSourceBrowser: ObservableObject, HostigSourceDiscovery {
    @Published public private(set) var sources: [HostigDiscoveredSource] = []

    private var browser: NWBrowser?
    private var restartTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "local.hostig.link.browser")

    public init() {}

    public func start() {
        guard browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: HostigLinkService.bonjourType, domain: HostigLinkService.bonjourDomain),
            using: .udp
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let mappedSources = results.compactMap(Self.source(from:))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.sources = mappedSources
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.restartAfterFailure()
                }
            }
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        restartTask?.cancel()
        restartTask = nil
        browser?.cancel()
        browser = nil
        sources = []
    }

    private func restartAfterFailure() {
        browser?.cancel()
        browser = nil
        sources = []
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    nonisolated private static func source(from result: NWBrowser.Result) -> HostigDiscoveredSource? {
        guard case .service(let name, let type, let domain, _) = result.endpoint else {
            return nil
        }

        let displayName = name.isEmpty ? "Hostig Source" : name
        return HostigDiscoveredSource(
            name: displayName,
            endpointDescription: "\(name).\(type).\(domain)",
            transportKind: .udpBonjour,
            endpoint: result.endpoint,
            serviceName: name,
            serviceType: type,
            serviceDomain: domain
        )
    }
}

@MainActor
public final class HostigUDPSourceServer: ObservableObject {
    @Published public private(set) var pairingPIN: String
    @Published public private(set) var isRunning = false
    @Published public private(set) var errorMessage: String?

    private let queue = DispatchQueue(label: "local.hostig.link.udp-source")
    private var listener: NWListener?
    private var ipv4Socket: Int32 = -1
    private var ipv4ReadSource: DispatchSourceRead?
    private var provider: (any HostigSnapshotProvider)?
    private var identity: HostigLinkIdentity?

    public init(pairingPIN: String? = nil) {
        self.pairingPIN = pairingPIN ?? HostigPIN.generate()
    }

    public func rotatePIN() {
        pairingPIN = HostigPIN.generate()
    }

    public func start(provider: any HostigSnapshotProvider, identity: HostigLinkIdentity) {
        self.provider = provider
        self.identity = identity

        guard listener == nil else {
            return
        }

        do {
            let linkPort = NWEndpoint.Port(rawValue: HostigLinkService.udpPort) ?? .any
            let listener = try NWListener(using: .udp, on: linkPort)
            listener.service = NWListener.Service(
                name: identity.deviceName,
                type: HostigLinkService.bonjourType,
                domain: HostigLinkService.bonjourDomain
            )
            listener.newConnectionHandler = { [weak self] connection in
                linkLogger.info("Mac UDP listener accepted connection from \(connection.endpoint.debugDescription, privacy: .public)")
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        linkLogger.info("Mac UDP listener ready on port \(listener.port?.rawValue ?? 0, privacy: .public)")
                        self?.isRunning = true
                        self?.errorMessage = nil
                    case .failed(let error):
                        linkLogger.error("Mac UDP listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.isRunning = false
                        self?.errorMessage = error.localizedDescription
                        self?.listener?.cancel()
                        self?.listener = nil
                    case .cancelled:
                        linkLogger.info("Mac UDP listener cancelled")
                        self?.isRunning = false
                        self?.listener = nil
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            startIPv4SocketResponder()
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        ipv4ReadSource?.cancel()
        ipv4ReadSource = nil
        ipv4Socket = -1
        isRunning = false
    }

    private func startIPv4SocketResponder() {
        guard ipv4Socket < 0, ipv4ReadSource == nil else { return }

        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            linkLogger.error("Mac IPv4 UDP socket creation failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if os(macOS)
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: HostigLinkService.udpPort.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(socketFD)
            linkLogger.error("Mac IPv4 UDP bind failed on port \(HostigLinkService.udpPort, privacy: .public): \(message, privacy: .public)")
            return
        }

        ipv4Socket = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receiveIPv4Datagrams(socketFD: socketFD)
        }
        source.setCancelHandler {
            close(socketFD)
        }
        ipv4ReadSource = source
        source.resume()
        linkLogger.info("Mac IPv4 UDP socket ready on port \(HostigLinkService.udpPort, privacy: .public)")
    }

    nonisolated private func receiveIPv4Datagrams(socketFD: Int32) {
        while true {
            var buffer = [UInt8](repeating: 0, count: 65_535)
            var remoteAddress = sockaddr_storage()
            var remoteAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let byteCount = withUnsafeMutablePointer(to: &remoteAddress) { remotePointer in
                remotePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    recvfrom(socketFD, &buffer, buffer.count, MSG_DONTWAIT, socketAddress, &remoteAddressLength)
                }
            }

            if byteCount > 0 {
                let data = Data(buffer.prefix(Int(byteCount)))
                let remoteDescription = Self.describe(remoteAddress, length: remoteAddressLength)
                linkLogger.info("Mac IPv4 UDP socket received request: \(data.count, privacy: .public) bytes from \(remoteDescription, privacy: .public)")
                Task { @MainActor in
                    await self.handle(data, responder: .ipv4Socket(socketFD, remoteAddress, remoteAddressLength, remoteDescription))
                }
            } else if byteCount == 0 {
                return
            } else {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    linkLogger.error("Mac IPv4 UDP recvfrom failed: \(String(cString: strerror(errno)), privacy: .public)")
                }
                return
            }
        }
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data {
                linkLogger.info("Mac UDP listener received request: \(data.count, privacy: .public) bytes from \(connection.endpoint.debugDescription, privacy: .public)")
                Task { @MainActor in
                    await self?.handle(data, on: connection)
                }
            }

            if let error {
                linkLogger.error("Mac UDP listener receive failed from \(connection.endpoint.debugDescription, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            if error == nil {
                self?.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) async {
        await handle(data, responder: .networkConnection(connection))
    }

    private func handle(_ data: Data, responder: HostigUDPResponder) async {
        guard let provider, let identity else { return }

        do {
            let request = try HostigSecureEnvelope.open(data, pin: pairingPIN)
            guard request.protocolVersion == HostigLinkService.protocolVersion else {
                throw HostigNetworkingError.protocolMismatch
            }
            let snapshot = await provider.currentSnapshot(identity: identity).compactedForDatagram()
            let response = HostigLinkMessage(kind: .snapshotResponse, requestID: request.requestID, snapshot: snapshot)
            let responsePayload = try JSONEncoder.hostigLink.encode(response)
            let encryptedResponse = try HostigSecureEnvelope.seal(response, pin: pairingPIN)
            linkLogger.info("Mac UDP listener sending snapshot response \(request.requestID.uuidString, privacy: .public): payload \(responsePayload.count, privacy: .public) bytes, encrypted \(encryptedResponse.count, privacy: .public) bytes")
            send(encryptedResponse, responder: responder)
        } catch {
            linkLogger.error("Mac UDP listener could not handle request from \(responder.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let response = HostigLinkMessage(kind: .error, requestID: UUID(), error: HostigNetworkingError.decryptionFailed.localizedDescription)
            if let encryptedResponse = try? HostigSecureEnvelope.seal(response, pin: pairingPIN) {
                send(encryptedResponse, responder: responder)
            }
        }
    }

    private nonisolated func send(_ data: Data, responder: HostigUDPResponder) {
        switch responder {
        case .networkConnection(let connection):
            send(data, on: connection)
        case .ipv4Socket(let socketFD, let remoteAddress, let remoteAddressLength, let remoteDescription):
            send(data, socketFD: socketFD, remoteAddress: remoteAddress, remoteAddressLength: remoteAddressLength, remoteDescription: remoteDescription)
        }
    }

    private nonisolated func send(_ data: Data, on connection: NWConnection) {
        let datagrams = HostigDatagramChunk.datagrams(for: data)
        linkLogger.info("Mac UDP listener sending \(datagrams.count, privacy: .public) datagram(s), total encrypted bytes \(data.count, privacy: .public), to \(connection.endpoint.debugDescription, privacy: .public)")
        for (index, datagram) in datagrams.enumerated() {
            connection.send(
                content: datagram,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        linkLogger.error("Mac UDP listener failed sending datagram \(index + 1, privacy: .public)/\(datagrams.count, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    } else {
                        linkLogger.debug("Mac UDP listener sent datagram \(index + 1, privacy: .public)/\(datagrams.count, privacy: .public): \(datagram.count, privacy: .public) bytes")
                    }
                }
            )
        }
    }

    private nonisolated func send(
        _ data: Data,
        socketFD: Int32,
        remoteAddress: sockaddr_storage,
        remoteAddressLength: socklen_t,
        remoteDescription: String
    ) {
        let datagrams = HostigDatagramChunk.datagrams(for: data)
        linkLogger.info("Mac IPv4 UDP socket sending \(datagrams.count, privacy: .public) datagram(s), total encrypted bytes \(data.count, privacy: .public), to \(remoteDescription, privacy: .public)")
        for (index, datagram) in datagrams.enumerated() {
            var address = remoteAddress
            let sentBytes = address.withSocketAddress { socketAddress in
                datagram.withUnsafeBytes { buffer in
                    sendto(socketFD, buffer.baseAddress, datagram.count, 0, socketAddress, remoteAddressLength)
                }
            }
            if sentBytes < 0 {
                linkLogger.error("Mac IPv4 UDP socket failed sending datagram \(index + 1, privacy: .public)/\(datagrams.count, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            } else {
                linkLogger.debug("Mac IPv4 UDP socket sent datagram \(index + 1, privacy: .public)/\(datagrams.count, privacy: .public): \(sentBytes, privacy: .public) bytes")
            }
        }
    }

    nonisolated private static func describe(_ address: sockaddr_storage, length: socklen_t) -> String {
        var address = address
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serviceBuffer = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let result = address.withSocketAddress { socketAddress in
            getnameinfo(
                socketAddress,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                &serviceBuffer,
                socklen_t(serviceBuffer.count),
                NI_NUMERICHOST | NI_NUMERICSERV
            )
        }
        guard result == 0 else {
            return "unknown"
        }
        let host = String(decodingCStringBuffer: hostBuffer)
        let service = String(decodingCStringBuffer: serviceBuffer)
        return "\(host):\(service)"
    }
}

private enum HostigUDPResponder: @unchecked Sendable {
    case networkConnection(NWConnection)
    case ipv4Socket(Int32, sockaddr_storage, socklen_t, String)

    var description: String {
        switch self {
        case .networkConnection(let connection):
            return connection.endpoint.debugDescription
        case .ipv4Socket(_, _, _, let remoteDescription):
            return remoteDescription
        }
    }
}

private extension sockaddr_storage {
    mutating func withSocketAddress<T>(_ body: (UnsafePointer<sockaddr>) -> T) -> T {
        withUnsafePointer(to: &self) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
        }
    }
}

private extension String {
    init(decodingCStringBuffer buffer: [CChar]) {
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}

public struct HostigUDPSnapshotTransport: HostigSnapshotTransport {
    public let kind: HostigTransportKind = .udpBonjour
    private let identity: HostigLinkIdentity
    private let queue = DispatchQueue(label: "local.hostig.link.udp-client")
    private let timeoutNanoseconds: UInt64

    public init(identity: HostigLinkIdentity, timeoutNanoseconds: UInt64 = 2_500_000_000) {
        self.identity = identity
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func fetchSnapshot(from source: HostigDiscoveredSource, pin: String) async throws -> HostigSnapshot {
        guard source.transportKind == .udpBonjour else {
            throw HostigNetworkingError.unsupportedTransport
        }
        try HostigPIN.validate(pin)

        let endpoints = await source.resolvedUDPEndpoints(timeoutNanoseconds: timeoutNanoseconds)
        let endpointDescriptions = endpoints.map(\.debugDescription).joined(separator: ", ")
        linkLogger.info("Vision UDP fetch for \(source.name, privacy: .public) using \(endpoints.count, privacy: .public) endpoint(s): \(endpointDescriptions, privacy: .public)")
        return try await fetchSnapshot(from: endpoints, pin: pin)
    }

    private func fetchSnapshot(from endpoints: [NWEndpoint], pin: String) async throws -> HostigSnapshot {
        let identity = identity
        let queue = queue
        let timeoutNanoseconds = timeoutNanoseconds

        return try await withThrowingTaskGroup(of: HostigSnapshot.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    try await Self.fetchSnapshot(
                        from: endpoint,
                        pin: pin,
                        identity: identity,
                        queue: queue,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                }
            }

            var lastError: Error = HostigNetworkingError.timedOut
            while let result = await group.nextResult() {
                switch result {
                case .success(let snapshot):
                    group.cancelAll()
                    return snapshot
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func fetchSnapshot(
        from endpoint: NWEndpoint,
        pin: String,
        identity: HostigLinkIdentity,
        queue: DispatchQueue,
        timeoutNanoseconds: UInt64
    ) async throws -> HostigSnapshot {
        let connection = NWConnection(to: endpoint, using: .udp)
        defer { connection.cancel() }

        linkLogger.info("Vision UDP connecting to \(endpoint.debugDescription, privacy: .public)")
        try await connection.waitUntilReady(on: queue, timeoutNanoseconds: timeoutNanoseconds)

        let request = HostigLinkMessage(kind: .snapshotRequest, requestID: UUID(), requester: identity)
        let encryptedRequest = try HostigSecureEnvelope.seal(request, pin: pin)
        linkLogger.info("Vision UDP sending snapshot request \(request.requestID.uuidString, privacy: .public): \(encryptedRequest.count, privacy: .public) bytes to \(endpoint.debugDescription, privacy: .public)")
        try await connection.sendDatagram(encryptedRequest)

        let encryptedResponse = try await connection.receiveDatagramMessage(timeoutNanoseconds: timeoutNanoseconds)
        linkLogger.info("Vision UDP received encrypted response for \(request.requestID.uuidString, privacy: .public): \(encryptedResponse.count, privacy: .public) bytes from \(endpoint.debugDescription, privacy: .public)")
        let response = try HostigSecureEnvelope.open(encryptedResponse, pin: pin)
        guard response.protocolVersion == HostigLinkService.protocolVersion else {
            throw HostigNetworkingError.protocolMismatch
        }
        guard response.kind == .snapshotResponse, let snapshot = response.snapshot else {
            throw HostigNetworkingError.missingSnapshot
        }
        return snapshot
    }
}

struct HostigPIN {
    static func generate() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func validate(_ pin: String) throws {
        guard pin.count == HostigLinkService.pairingPINLength, pin.allSatisfy(\.isNumber) else {
            throw HostigNetworkingError.invalidPIN
        }
    }
}

private struct HostigLinkMessage: Codable {
    enum Kind: String, Codable {
        case snapshotRequest
        case snapshotResponse
        case error
    }

    var protocolVersion = HostigLinkService.protocolVersion
    var kind: Kind
    var requestID: UUID
    var requester: HostigLinkIdentity?
    var snapshot: HostigSnapshot?
    var error: String?
}

private struct HostigDatagramChunk: Codable {
    static let kind = "hostig.chunk.v1"
    static let maxRawDatagramBytes = 1_200
    static let maxChunkPayloadBytes = 700

    var kind = Self.kind
    var transferID: UUID
    var index: Int
    var count: Int
    var payload: Data

    static func datagrams(for data: Data) -> [Data] {
        guard data.count > maxRawDatagramBytes else {
            return [data]
        }

        let transferID = UUID()
        let count = Int(ceil(Double(data.count) / Double(maxChunkPayloadBytes)))

        return (0..<count).compactMap { index in
            let start = index * maxChunkPayloadBytes
            let end = min(start + maxChunkPayloadBytes, data.count)
            let payload = data[start..<end]
            let chunk = HostigDatagramChunk(
                transferID: transferID,
                index: index,
                count: count,
                payload: Data(payload)
            )
            return try? JSONEncoder.hostigLink.encode(chunk)
        }
    }

    var isValid: Bool {
        kind == Self.kind && index >= 0 && index < count && count > 0
    }
}

private struct HostigSecureEnvelope: Codable {
    var nonce: Data
    var ciphertext: Data
    var tag: Data

    static func seal(_ message: HostigLinkMessage, pin: String) throws -> Data {
        try HostigPIN.validate(pin)

        let payload = try JSONEncoder.hostigLink.encode(message)
        let sealedBox = try AES.GCM.seal(payload, using: key(from: pin))
        let envelope = HostigSecureEnvelope(
            nonce: Data(sealedBox.nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try JSONEncoder.hostigLink.encode(envelope)
    }

    static func open(_ data: Data, pin: String) throws -> HostigLinkMessage {
        try HostigPIN.validate(pin)

        let envelope = try JSONDecoder.hostigLink.decode(HostigSecureEnvelope.self, from: data)
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
        let payload: Data
        do {
            payload = try AES.GCM.open(sealedBox, using: key(from: pin))
        } catch {
            throw HostigNetworkingError.decryptionFailed
        }
        return try JSONDecoder.hostigLink.decode(HostigLinkMessage.self, from: payload)
    }

    private static func key(from pin: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
            salt: Data(HostigLinkService.cryptoSalt.utf8),
            info: Data("snapshot".utf8),
            outputByteCount: 32
        )
    }
}

private extension JSONEncoder {
    static var hostigLink: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var hostigLink: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension HostigSnapshot {
    func compactedForDatagram() -> HostigSnapshot {
        HostigSnapshot(
            protocolVersion: protocolVersion,
            identity: identity,
            generatedAt: generatedAt,
            latencyMonitorHost: latencyMonitorHost,
            latencyMonitorSnapshot: latencyMonitorSnapshot,
            latencyHistory: latencyHistory.suffixPoints(40),
            hosts: hosts.map { host in
                var compactHost = host
                compactHost.pingHistory = host.pingHistory.suffixPoints(24)
                return compactHost
            }
        )
    }
}

private extension Array where Element == PingHistoryPoint {
    func suffixPoints(_ maxCount: Int) -> [PingHistoryPoint] {
        guard count > maxCount else { return self }
        return Array(suffix(maxCount))
    }
}

private extension HostigDiscoveredSource {
    func resolvedUDPEndpoints(timeoutNanoseconds: UInt64) async -> [NWEndpoint] {
        guard
            let serviceName,
            let serviceType,
            let serviceDomain,
            case .service = endpoint
        else {
            return [endpoint]
        }

        var fallbackEndpoints = [endpoint]
        if let fixedPort = NWEndpoint.Port(rawValue: HostigLinkService.udpPort) {
            let hostName = serviceName.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + ".local"
            fallbackEndpoints.append(.hostPort(host: NWEndpoint.Host(hostName), port: fixedPort))
        }

        do {
            let resolved = try await HostigNetServiceResolver.resolve(
                name: serviceName,
                type: serviceType,
                domain: serviceDomain,
                timeoutNanoseconds: timeoutNanoseconds
            )
            return (fallbackEndpoints + resolved).uniquedByDescription()
        } catch {
            linkLogger.error("Vision UDP Bonjour resolve failed for \(serviceName, privacy: .public).\(serviceType, privacy: .public)\(serviceDomain, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return fallbackEndpoints.uniquedByDescription()
        }
    }
}

private final class HostigNetServiceResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<[NWEndpoint], Error>?
    private var service: NetService?
    private var retainCycle: HostigNetServiceResolver?
    private let resumeBox = ResumeBox()

    static func resolve(name: String, type: String, domain: String, timeoutNanoseconds: UInt64) async throws -> [NWEndpoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NWEndpoint], Error>) in
            let resolver = HostigNetServiceResolver()
            resolver.continuation = continuation
            resolver.retainCycle = resolver

            let service = NetService(domain: domain, type: type, name: name)
            resolver.service = service
            service.delegate = resolver

            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
                resolver.finish(.failure(HostigNetworkingError.timedOut))
            }
            DispatchQueue.main.async {
                service.resolve(withTimeout: TimeInterval(timeoutNanoseconds) / 1_000_000_000)
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else {
            finish(.failure(HostigNetworkingError.timedOut))
            return
        }

        let addressEndpoints = Self.endpoints(from: sender.addresses, port: sender.port)
        let hostNames = [sender.hostName, sender.name + "." + sender.domain]
            .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }

        let hostNameEndpoints = Array(Set(hostNames)).compactMap { hostName -> NWEndpoint? in
            guard let port = NWEndpoint.Port(rawValue: UInt16(sender.port)) else { return nil }
            return .hostPort(host: NWEndpoint.Host(hostName), port: port)
        }
        let endpoints = (addressEndpoints + hostNameEndpoints).uniquedByDescription()

        if endpoints.isEmpty {
            finish(.failure(HostigNetworkingError.timedOut))
        } else {
            finish(.success(endpoints))
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(.failure(HostigNetworkingError.connectionFailed("Could not resolve \(sender.name).")))
    }

    private func finish(_ result: Result<[NWEndpoint], Error>) {
        resumeBox.resume {
            service?.stop()
            service?.delegate = nil
            service = nil

            switch result {
            case .success(let endpoints):
                continuation?.resume(returning: endpoints)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
            continuation = nil
            retainCycle = nil
        }
    }

    private static func endpoints(from addresses: [Data]?, port: Int) -> [NWEndpoint] {
        guard let addresses, let port = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return []
        }

        return addresses.compactMap { address -> NWEndpoint? in
            address.withUnsafeBytes { rawBuffer -> NWEndpoint? in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return nil
                }

                let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    sockaddrPointer,
                    socklen_t(rawBuffer.count),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard result == 0 else {
                    return nil
                }

                let hostLength = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
                let hostBytes = hostBuffer[..<hostLength].map { UInt8(bitPattern: $0) }
                let host = String(decoding: hostBytes, as: UTF8.self)
                guard !host.isEmpty else {
                    return nil
                }
                return .hostPort(host: NWEndpoint.Host(host), port: port)
            }
        }
    }
}

private extension Array where Element == NWEndpoint {
    func uniquedByDescription() -> [NWEndpoint] {
        var seen = Set<String>()
        return filter { endpoint in
            seen.insert(endpoint.debugDescription).inserted
        }
    }
}

private extension NWConnection {
    func waitUntilReady(on queue: DispatchQueue, timeoutNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeBox()
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
                box.resume {
                    self.cancel()
                    continuation.resume(throwing: HostigNetworkingError.timedOut)
                }
            }

            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume { continuation.resume() }
                case .failed(let error):
                    box.resume { continuation.resume(throwing: HostigNetworkingError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    box.resume { continuation.resume(throwing: HostigNetworkingError.connectionFailed("Connection cancelled.")) }
                default:
                    break
                }
            }
            self.start(queue: queue)
        }
    }

    func sendDatagram(_ content: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.send(content: content, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: HostigNetworkingError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveDatagram(timeoutNanoseconds: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let box = ResumeBox()
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
                box.resume {
                    self.cancel()
                    continuation.resume(throwing: HostigNetworkingError.timedOut)
                }
            }

            self.receiveMessage { data, _, _, error in
                box.resume {
                    if let error {
                        continuation.resume(throwing: HostigNetworkingError.connectionFailed(error.localizedDescription))
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: HostigNetworkingError.timedOut)
                    }
                }
            }
        }
    }

    func receiveDatagramMessage(timeoutNanoseconds: UInt64) async throws -> Data {
        let firstDatagram = try await receiveDatagram(timeoutNanoseconds: timeoutNanoseconds)
        guard
            let firstChunk = try? JSONDecoder.hostigLink.decode(HostigDatagramChunk.self, from: firstDatagram),
            firstChunk.isValid
        else {
            return firstDatagram
        }

        var chunks = Array<Data?>(repeating: nil, count: firstChunk.count)
        chunks[firstChunk.index] = firstChunk.payload

        while chunks.contains(where: { $0 == nil }) {
            let datagram = try await receiveDatagram(timeoutNanoseconds: timeoutNanoseconds)
            guard
                let chunk = try? JSONDecoder.hostigLink.decode(HostigDatagramChunk.self, from: datagram),
                chunk.isValid,
                chunk.transferID == firstChunk.transferID,
                chunk.count == firstChunk.count
            else {
                continue
            }
            chunks[chunk.index] = chunk.payload
        }

        return chunks.reduce(into: Data()) { result, chunk in
            if let chunk {
                result.append(chunk)
            }
        }
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        block()
    }
}
