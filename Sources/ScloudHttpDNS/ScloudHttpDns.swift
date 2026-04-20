import Foundation

enum ScloudHttpDns {
    private static var services: [String: DefaultScloudHttpDnsService] = [:]
    private static let lock = NSLock()

    static func initialize(accountId: String, config: ScloudInitConfig) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = services[accountId] {
            existing.updateConfig(config)
        } else {
            services[accountId] = DefaultScloudHttpDnsService(accountId: accountId, config: config)
        }
    }

    static func getService(accountId: String) -> ScloudHttpDnsService {
        lock.lock()
        defer { lock.unlock() }
        guard let service = services[accountId] else {
            fatalError("ScloudHttpDns for accountId=\(accountId) is not initialized. Call ScloudHttpDns.init(accountId:config:) first.")
        }
        return service
    }

    static func getService(accountId: String, config: ScloudInitConfig) -> ScloudHttpDnsService {
        initialize(accountId: accountId, config: config)
        return getService(accountId: accountId)
    }
}
