import Foundation

protocol BonjourScannerDelegate: AnyObject {
    func scanner(_ scanner: BonjourScanner, didResolve service: ResolvedSSHService)
    func scanner(_ scanner: BonjourScanner, didRemove serviceName: String)
}

final class BonjourScanner: NSObject {
    weak var delegate: BonjourScannerDelegate?

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.values.forEach { service in
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
    }
}

extension BonjourScanner: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        services[service.name] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        services.removeValue(forKey: service.name)
        delegate?.scanner(self, didRemove: service.name)
    }
}

extension BonjourScanner: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = (sender.hostName ?? sender.name)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        delegate?.scanner(
            self,
            didResolve: ResolvedSSHService(
                serviceName: sender.name,
                hostname: host,
                port: sender.port,
                domain: sender.domain
            )
        )
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services.removeValue(forKey: sender.name)
    }
}
