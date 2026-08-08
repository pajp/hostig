import Combine
import CryptoKit
import Foundation
import HostigLink
import HostigModels
@preconcurrency import Network

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

    init(name: String, endpointDescription: String, transportKind: HostigTransportKind, endpoint: NWEndpoint) {
        self.id = "\(transportKind.rawValue):\(endpointDescription)"
        self.name = name
        self.endpointDescription = endpointDescription
        self.transportKind = transportKind
        self.endpoint = endpoint
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
            endpoint: result.endpoint
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
            let listener = try NWListener(using: .udp)
            listener.service = NWListener.Service(
                name: identity.deviceName,
                type: HostigLinkService.bonjourType,
                domain: HostigLinkService.bonjourDomain
            )
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.errorMessage = nil
                    case .failed(let error):
                        self?.isRunning = false
                        self?.errorMessage = error.localizedDescription
                        self?.listener?.cancel()
                        self?.listener = nil
                    case .cancelled:
                        self?.isRunning = false
                        self?.listener = nil
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data {
                Task { @MainActor in
                    await self?.handle(data, on: connection)
                }
            }

            if error == nil {
                self?.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) async {
        guard let provider, let identity else { return }

        do {
            let request = try HostigSecureEnvelope.open(data, pin: pairingPIN)
            guard request.protocolVersion == HostigLinkService.protocolVersion else {
                throw HostigNetworkingError.protocolMismatch
            }
            let snapshot = await provider.currentSnapshot(identity: identity)
            let response = HostigLinkMessage(kind: .snapshotResponse, requestID: request.requestID, snapshot: snapshot)
            let encryptedResponse = try HostigSecureEnvelope.seal(response, pin: pairingPIN)
            send(encryptedResponse, on: connection)
        } catch {
            let response = HostigLinkMessage(kind: .error, requestID: UUID(), error: HostigNetworkingError.decryptionFailed.localizedDescription)
            if let encryptedResponse = try? HostigSecureEnvelope.seal(response, pin: pairingPIN) {
                send(encryptedResponse, on: connection)
            }
        }
    }

    private nonisolated func send(_ data: Data, on connection: NWConnection) {
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
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

        let connection = NWConnection(to: source.endpoint, using: .udp)
        defer { connection.cancel() }

        try await connection.waitUntilReady(on: queue, timeoutNanoseconds: timeoutNanoseconds)

        let request = HostigLinkMessage(kind: .snapshotRequest, requestID: UUID(), requester: identity)
        let encryptedRequest = try HostigSecureEnvelope.seal(request, pin: pin)
        try await connection.sendDatagram(encryptedRequest)

        let encryptedResponse = try await connection.receiveDatagram(timeoutNanoseconds: timeoutNanoseconds)
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

private extension NWConnection {
    func waitUntilReady(on queue: DispatchQueue, timeoutNanoseconds: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    final class ResumeBox: @unchecked Sendable {
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

                    let box = ResumeBox()
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
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw HostigNetworkingError.timedOut
            }
            try await group.next()
            group.cancelAll()
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
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.receiveMessage { data, _, _, error in
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
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw HostigNetworkingError.timedOut
            }
            guard let data = try await group.next() else {
                throw HostigNetworkingError.timedOut
            }
            group.cancelAll()
            return data
        }
    }
}
