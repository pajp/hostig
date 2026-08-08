import Combine
import CryptoKit
import Foundation
import HostigLink
import HostigModels
@preconcurrency import Network
import OSLog
import Security

private let linkLogger = Logger(subsystem: "nu.dll.hostig", category: "HostigLink")

public enum HostigTransportKind: String, Codable, Equatable, Sendable {
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

    init(
        name: String,
        endpointDescription: String,
        transportKind: HostigTransportKind,
        endpoint: NWEndpoint
    ) {
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
    case pairingUnavailable

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
        case .pairingUnavailable:
            return "This source needs to be paired with its 6-digit PIN again."
        }
    }
}

public enum HostigPairingRole: String, Sendable {
    case mac
    case vision
}

public struct HostigRememberedSource: Codable, Equatable, Sendable {
    public var endpointDescription: String
    public var name: String
    public var sourceAppInstanceID: UUID
    public var keyID: String
}

public final class HostigLinkPairingStore: @unchecked Sendable {
    private let role: HostigPairingRole
    private let defaults: UserDefaults
    private let rememberedSourcesKey: String
    private let lastSourceKey: String
    private let keychainService: String

    public init(role: HostigPairingRole, defaults: UserDefaults = .standard) {
        self.role = role
        self.defaults = defaults
        self.rememberedSourcesKey = "nu.dll.hostig.link.\(role.rawValue).rememberedSources"
        self.lastSourceKey = "nu.dll.hostig.link.\(role.rawValue).lastSource"
        self.keychainService = "nu.dll.hostig.link.\(role.rawValue).pairingKeys"
    }

    public func rememberedSources() -> [String: HostigRememberedSource] {
        guard
            let data = defaults.data(forKey: rememberedSourcesKey),
            let sources = try? JSONDecoder().decode([String: HostigRememberedSource].self, from: data)
        else {
            return [:]
        }
        return sources
    }

    public func rememberedSource(endpointDescription: String) -> HostigRememberedSource? {
        rememberedSources()[endpointDescription]
    }

    public func saveRememberedSource(_ source: HostigRememberedSource) {
        var sources = rememberedSources()
        sources[source.endpointDescription] = source
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: rememberedSourcesKey)
        }
    }

    public var lastSourceEndpointDescription: String? {
        get { defaults.string(forKey: lastSourceKey) }
        set { defaults.set(newValue, forKey: lastSourceKey) }
    }

    public func keyData(for keyID: String) -> Data? {
        var query = keychainBaseQuery(account: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    public func saveKeyData(_ keyData: Data, keyID: String) throws {
        let query = keychainBaseQuery(account: keyID)
        let attributes = [kSecValueData as String: keyData]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw HostigNetworkingError.connectionFailed("Could not update pairing key: \(updateStatus).")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HostigNetworkingError.connectionFailed("Could not save pairing key: \(addStatus).")
        }
    }

    private func keychainBaseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
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
            using: .tcp
        )

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            let mappedSources = results.compactMap(Self.source(from:))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let resultSummary = mappedSources
                .map { "\($0.name) [\($0.endpointDescription)]" }
                .joined(separator: ", ")
            linkLogger.info("Vision TCP Bonjour results changed: \(mappedSources.count, privacy: .public) source(s), changes \(changes.count, privacy: .public): \(resultSummary, privacy: .public)")
            Task { @MainActor in
                self?.sources = mappedSources
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            linkLogger.info("Vision TCP Bonjour browser state: \(String(describing: state), privacy: .public)")
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
            transportKind: .tcp,
            endpoint: result.endpoint
        )
    }
}

@MainActor
public final class HostigLinkSourceServer: ObservableObject {
    @Published public private(set) var pairingPIN: String
    @Published public private(set) var isRunning = false
    @Published public private(set) var errorMessage: String?

    private let queue = DispatchQueue(label: "local.hostig.link.tcp-source")
    private var listener: NWListener?
    private var provider: (any HostigSnapshotProvider)?
    private var identity: HostigLinkIdentity?
    private let pairingStore: HostigLinkPairingStore

    public init(pairingPIN: String? = nil, pairingStore: HostigLinkPairingStore = HostigLinkPairingStore(role: .mac)) {
        self.pairingPIN = pairingPIN ?? HostigPIN.generate()
        self.pairingStore = pairingStore
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
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: identity.deviceName,
                type: HostigLinkService.bonjourType,
                domain: HostigLinkService.bonjourDomain
            )
            listener.serviceRegistrationUpdateHandler = { update in
                linkLogger.info("Mac TCP Bonjour registration update: \(String(describing: update), privacy: .public)")
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        linkLogger.info("Mac TCP listener ready on port \(listener.port?.rawValue ?? 0, privacy: .public)")
                        self?.isRunning = true
                        self?.errorMessage = nil
                    case .failed(let error):
                        linkLogger.error("Mac TCP listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.isRunning = false
                        self?.errorMessage = error.localizedDescription
                        self?.listener?.cancel()
                        self?.listener = nil
                    case .cancelled:
                        linkLogger.info("Mac TCP listener cancelled")
                        self?.isRunning = false
                        self?.listener = nil
                    case .waiting(let error):
                        linkLogger.error("Mac TCP listener waiting: \(error.localizedDescription, privacy: .public)")
                    default:
                        linkLogger.debug("Mac TCP listener state: \(String(describing: state), privacy: .public)")
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
            linkLogger.error("Mac TCP listener setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private nonisolated func accept(_ connection: NWConnection) {
        linkLogger.info("Mac TCP accepted connection from \(connection.endpoint.debugDescription, privacy: .public)")
        connection.stateUpdateHandler = { state in
            linkLogger.info("Mac TCP connection \(connection.endpoint.debugDescription, privacy: .public) state: \(String(describing: state), privacy: .public)")
        }
        connection.start(queue: queue)
        Task { @MainActor in
            await self.handle(connection)
        }
    }

    private func handle(_ connection: NWConnection) async {
        guard let provider, let identity else { return }
        defer { connection.cancel() }

        do {
            let requestData = try await connection.receiveFrame(timeoutNanoseconds: HostigLinkFrame.timeoutNanoseconds)
            linkLogger.info("Mac TCP received framed request: \(requestData.count, privacy: .public) bytes from \(connection.endpoint.debugDescription, privacy: .public)")

            let authentication = try authenticate(requestData)
            guard let request = authentication.message else {
                throw HostigNetworkingError.connectionFailed("Received an empty Hostig link request.")
            }
            guard request.protocolVersion == HostigLinkService.protocolVersion else {
                throw HostigNetworkingError.protocolMismatch
            }

            let snapshot = await provider.currentSnapshot(identity: identity)
            let response = HostigLinkMessage(kind: .snapshotResponse, requestID: request.requestID, snapshot: snapshot)
            let responsePayload = try JSONEncoder.hostigLink.encode(response)
            let encryptedResponse = try authentication.seal(response)
            linkLogger.info("Mac TCP sending snapshot response \(request.requestID.uuidString, privacy: .public): payload \(responsePayload.count, privacy: .public) bytes, encrypted \(encryptedResponse.count, privacy: .public) bytes")

            try await connection.sendFrame(encryptedResponse)
            linkLogger.info("Mac TCP sent snapshot response \(request.requestID.uuidString, privacy: .public) to \(connection.endpoint.debugDescription, privacy: .public)")
        } catch {
            linkLogger.error("Mac TCP could not handle request from \(connection.endpoint.debugDescription, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let response = HostigLinkMessage(kind: .error, requestID: UUID(), error: error.localizedDescription)
            if let encryptedResponse = try? HostigSecureEnvelope.seal(response, pin: pairingPIN) {
                try? await connection.sendFrame(encryptedResponse)
            }
        }
    }

    private func authenticate(_ data: Data) throws -> HostigLinkAuthentication {
        if
            let keyID = try HostigSecureEnvelope.keyID(in: data),
            let keyData = pairingStore.keyData(for: keyID)
        {
            let message = try HostigSecureEnvelope.open(data, keyData: keyData)
            linkLogger.info("Mac TCP authenticated request with remembered key \(keyID, privacy: .public)")
            return HostigLinkAuthentication(message: message, keyData: keyData, keyID: keyID)
        }

        let message = try HostigSecureEnvelope.open(data, pin: pairingPIN)
        if let requester = message.requester, let identity {
            let credential = HostigPairingKeys.credential(
                pin: pairingPIN,
                requesterID: requester.appInstanceID,
                sourceID: identity.appInstanceID
            )
            try pairingStore.saveKeyData(credential.keyData, keyID: credential.keyID)
            linkLogger.info("Mac TCP saved remembered pairing key \(credential.keyID, privacy: .public) for requester \(requester.appInstanceID.uuidString, privacy: .public)")
        }
        return HostigLinkAuthentication(message: message, pin: pairingPIN)
    }
}

public struct HostigTCPSnapshotTransport: HostigSnapshotTransport {
    public let kind: HostigTransportKind = .tcp
    private let identity: HostigLinkIdentity
    private let queue = DispatchQueue(label: "local.hostig.link.tcp-client")
    private let timeoutNanoseconds: UInt64
    private let pairingStore: HostigLinkPairingStore

    public init(
        identity: HostigLinkIdentity,
        pairingStore: HostigLinkPairingStore = HostigLinkPairingStore(role: .vision),
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.identity = identity
        self.pairingStore = pairingStore
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func fetchSnapshot(from source: HostigDiscoveredSource, pin: String) async throws -> HostigSnapshot {
        guard source.transportKind == .tcp else {
            throw HostigNetworkingError.unsupportedTransport
        }

        let connection = NWConnection(to: source.endpoint, using: .tcp)
        defer { connection.cancel() }

        linkLogger.info("Vision TCP connecting to \(source.name, privacy: .public) at \(source.endpoint.debugDescription, privacy: .public)")
        try await connection.waitUntilReady(on: queue, timeoutNanoseconds: timeoutNanoseconds)

        let request = HostigLinkMessage(kind: .snapshotRequest, requestID: UUID(), requester: identity)
        let authentication = try authentication(for: source, pin: pin)
        let encryptedRequest = try authentication.seal(request)
        linkLogger.info("Vision TCP sending snapshot request \(request.requestID.uuidString, privacy: .public): \(encryptedRequest.count, privacy: .public) bytes to \(source.endpoint.debugDescription, privacy: .public)")
        try await connection.sendFrame(encryptedRequest)

        let encryptedResponse = try await connection.receiveFrame(timeoutNanoseconds: timeoutNanoseconds)
        linkLogger.info("Vision TCP received encrypted response for \(request.requestID.uuidString, privacy: .public): \(encryptedResponse.count, privacy: .public) bytes from \(source.endpoint.debugDescription, privacy: .public)")
        let response = try authentication.open(encryptedResponse)
        guard response.protocolVersion == HostigLinkService.protocolVersion else {
            throw HostigNetworkingError.protocolMismatch
        }
        guard response.kind == .snapshotResponse, let snapshot = response.snapshot else {
            throw HostigNetworkingError.missingSnapshot
        }
        if case .pin(let pin) = authentication.storage, !pin.isEmpty {
            let credential = HostigPairingKeys.credential(
                pin: pin,
                requesterID: identity.appInstanceID,
                sourceID: snapshot.identity.appInstanceID
            )
            try pairingStore.saveKeyData(credential.keyData, keyID: credential.keyID)
            pairingStore.saveRememberedSource(
                HostigRememberedSource(
                    endpointDescription: source.endpointDescription,
                    name: source.name,
                    sourceAppInstanceID: snapshot.identity.appInstanceID,
                    keyID: credential.keyID
                )
            )
            pairingStore.lastSourceEndpointDescription = source.endpointDescription
            linkLogger.info("Vision TCP saved remembered pairing key \(credential.keyID, privacy: .public) for source \(source.name, privacy: .public)")
        } else {
            pairingStore.lastSourceEndpointDescription = source.endpointDescription
        }
        linkLogger.info("Vision TCP decoded snapshot \(request.requestID.uuidString, privacy: .public): \(snapshot.hosts.count, privacy: .public) host(s)")
        return snapshot
    }

    private func authentication(for source: HostigDiscoveredSource, pin: String) throws -> HostigLinkAuthentication {
        if pin.count == HostigLinkService.pairingPINLength {
            try HostigPIN.validate(pin)
            return HostigLinkAuthentication(message: nil, pin: pin)
        }

        if
            let rememberedSource = pairingStore.rememberedSource(endpointDescription: source.endpointDescription),
            let keyData = pairingStore.keyData(for: rememberedSource.keyID)
        {
            linkLogger.info("Vision TCP using remembered pairing key \(rememberedSource.keyID, privacy: .public) for \(source.name, privacy: .public)")
            return HostigLinkAuthentication(message: nil, keyData: keyData, keyID: rememberedSource.keyID)
        }

        try HostigPIN.validate(pin)
        return HostigLinkAuthentication(message: nil, pin: pin)
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

private struct HostigLinkAuthentication {
    enum Storage {
        case pin(String)
        case key(Data, String)
    }

    var message: HostigLinkMessage?
    var storage: Storage

    init(message: HostigLinkMessage?, pin: String) {
        self.message = message
        self.storage = .pin(pin)
    }

    init(message: HostigLinkMessage?, keyData: Data, keyID: String) {
        self.message = message
        self.storage = .key(keyData, keyID)
    }

    func seal(_ message: HostigLinkMessage) throws -> Data {
        switch storage {
        case .pin(let pin):
            return try HostigSecureEnvelope.seal(message, pin: pin)
        case .key(let keyData, let keyID):
            return try HostigSecureEnvelope.seal(message, keyData: keyData, keyID: keyID)
        }
    }

    func open(_ data: Data) throws -> HostigLinkMessage {
        switch storage {
        case .pin(let pin):
            return try HostigSecureEnvelope.open(data, pin: pin)
        case .key(let keyData, _):
            return try HostigSecureEnvelope.open(data, keyData: keyData)
        }
    }
}

private struct HostigSecureEnvelope: Codable {
    var keyID: String?
    var nonce: Data
    var ciphertext: Data
    var tag: Data

    static func seal(_ message: HostigLinkMessage, pin: String) throws -> Data {
        try HostigPIN.validate(pin)
        return try seal(message, key: key(from: pin), keyID: nil)
    }

    static func seal(_ message: HostigLinkMessage, keyData: Data, keyID: String) throws -> Data {
        try seal(message, key: SymmetricKey(data: keyData), keyID: keyID)
    }

    private static func seal(_ message: HostigLinkMessage, key: SymmetricKey, keyID: String?) throws -> Data {
        let payload = try JSONEncoder.hostigLink.encode(message)
        let sealedBox = try AES.GCM.seal(payload, using: key)
        let envelope = HostigSecureEnvelope(
            keyID: keyID,
            nonce: Data(sealedBox.nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try JSONEncoder.hostigLink.encode(envelope)
    }

    static func keyID(in data: Data) throws -> String? {
        try JSONDecoder.hostigLink.decode(HostigSecureEnvelope.self, from: data).keyID
    }

    static func open(_ data: Data, pin: String) throws -> HostigLinkMessage {
        try HostigPIN.validate(pin)
        return try open(data, key: key(from: pin))
    }

    static func open(_ data: Data, keyData: Data) throws -> HostigLinkMessage {
        try open(data, key: SymmetricKey(data: keyData))
    }

    private static func open(_ data: Data, key: SymmetricKey) throws -> HostigLinkMessage {
        let envelope = try JSONDecoder.hostigLink.decode(HostigSecureEnvelope.self, from: data)
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
        let payload: Data
        do {
            payload = try AES.GCM.open(sealedBox, using: key)
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

private enum HostigPairingKeys {
    static func credential(pin: String, requesterID: UUID, sourceID: UUID) -> (keyID: String, keyData: Data) {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
            salt: Data((HostigLinkService.cryptoSalt + ".pairing").utf8),
            info: Data("\(requesterID.uuidString)|\(sourceID.uuidString)".utf8),
            outputByteCount: 32
        )
        let keyData = key.withUnsafeBytes { Data($0) }
        let keyIDPayload = Data("HostigLinkKey.v1|\(requesterID.uuidString)|\(sourceID.uuidString)".utf8)
        let keyID = SHA256.hash(data: keyIDPayload).map { String(format: "%02x", $0) }.joined()
        return (keyID, keyData)
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeBox()
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
                box.resume {
                    linkLogger.error("TCP connection timed out before ready: \(self.endpoint.debugDescription, privacy: .public)")
                    self.cancel()
                    continuation.resume(throwing: HostigNetworkingError.timedOut)
                }
            }

            self.stateUpdateHandler = { state in
                linkLogger.info("TCP connection \(self.endpoint.debugDescription, privacy: .public) state: \(String(describing: state), privacy: .public)")
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

    func sendFrame(_ content: Data) async throws {
        let frame = HostigLinkFrame.encode(content)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.send(content: frame, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: HostigNetworkingError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveFrame(timeoutNanoseconds: UInt64) async throws -> Data {
        let header = try await receiveExactByteCount(HostigLinkFrame.headerByteCount, timeoutNanoseconds: timeoutNanoseconds)
        let length = try HostigLinkFrame.decodeLength(header)
        linkLogger.debug("TCP frame header from \(self.endpoint.debugDescription, privacy: .public) declares \(length, privacy: .public) bytes")
        return try await receiveExactByteCount(length, timeoutNanoseconds: timeoutNanoseconds)
    }

    private func receiveExactByteCount(_ byteCount: Int, timeoutNanoseconds: UInt64) async throws -> Data {
        var buffer = Data()
        while buffer.count < byteCount {
            let remaining = byteCount - buffer.count
            let chunk = try await receiveBytes(maximumLength: remaining, timeoutNanoseconds: timeoutNanoseconds)
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveBytes(maximumLength: Int, timeoutNanoseconds: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let box = ResumeBox()
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
                box.resume {
                    linkLogger.error("TCP receive timed out from \(self.endpoint.debugDescription, privacy: .public)")
                    self.cancel()
                    continuation.resume(throwing: HostigNetworkingError.timedOut)
                }
            }

            self.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                box.resume {
                    if let error {
                        continuation.resume(throwing: HostigNetworkingError.connectionFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: HostigNetworkingError.connectionFailed("Connection closed before a complete frame was received."))
                    } else {
                        continuation.resume(throwing: HostigNetworkingError.timedOut)
                    }
                }
            }
        }
    }
}

private enum HostigLinkFrame {
    static let headerByteCount = 4
    static let maxPayloadByteCount = 8_000_000
    static let timeoutNanoseconds: UInt64 = 10_000_000_000

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerByteCount)
        frame.append(payload)
        return frame
    }

    static func decodeLength(_ header: Data) throws -> Int {
        guard header.count == headerByteCount else {
            throw HostigNetworkingError.connectionFailed("Received an incomplete frame header.")
        }
        let length = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length > 0, length <= maxPayloadByteCount else {
            throw HostigNetworkingError.connectionFailed("Received an invalid frame length: \(length).")
        }
        return Int(length)
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
