import Foundation

final class DefaultScloudHttpDnsService: ScloudHttpDnsService {
    private let accountId: String
    private let configLock = NSLock()
    private var config: ScloudInitConfig

    private let cache = CacheStore()
    private let workerQueue = DispatchQueue(label: "scloud.httpdns.worker", qos: .utility, attributes: .concurrent)
    private let stateLock = NSLock()
    private var inFlightResolveKeys: Set<String> = []

    private let transport = HTTPTransport()

    private lazy var dispatchService: DispatchService = {
        DispatchService(
            accountId: accountId,
            bootstrap: .default,
            getConfig: { [weak self] in self?.safeConfig() ?? ScloudInitConfig(aesSecretKey: "0000000000000000") },
            transport: transport,
            log: { [weak self] message in self?.log(message) }
        )
    }()

    private lazy var resolveRequestExecutor: ResolveRequestExecutor = {
        ResolveRequestExecutor(
            accountId: accountId,
            getConfig: { [weak self] in self?.safeConfig() ?? ScloudInitConfig(aesSecretKey: "0000000000000000") },
            cache: cache,
            dispatchService: dispatchService,
            transport: transport,
            toPublicResult: { [weak self] item, expired in
                self?.toPublicResult(item, expired: expired) ?? ScloudHTTPDNSResult(
                    host: item.host,
                    ips: item.ipsV4,
                    ipv6s: item.ipsV6,
                    extras: item.extras,
                    ttl: item.ttl,
                    expired: expired
                )
            },
            log: { [weak self] message in self?.log(message) }
        )
    }()

    private lazy var resolveHostService: ResolveHostService = {
        ResolveHostService(
            queue: workerQueue,
            cache: cache,
            getConfig: { [weak self] in self?.safeConfig() ?? ScloudInitConfig(aesSecretKey: "0000000000000000") },
            normalizeHost: { [weak self] host in self?.normalizeHost(host) },
            shouldBypassHttpDns: { [weak self] host in self?.shouldBypassHttpDns(host: host) ?? false },
            fallbackResult: { [weak self] host in self?.fallbackResult(host: host) ?? ScloudHTTPDNSResult(host: host, ips: [], ipv6s: [], extras: [:], ttl: 0, expired: true) },
            toPublicResult: { [weak self] item, expired in
                self?.toPublicResult(item, expired: expired) ?? ScloudHTTPDNSResult(
                    host: item.host,
                    ips: item.ipsV4,
                    ipv6s: item.ipsV6,
                    extras: item.extras,
                    ttl: item.ttl,
                    expired: expired
                )
            },
            requestResolve: { [weak self] host, type in
                guard let self else {
                    return ScloudHTTPDNSResult(host: host, ips: [], ipv6s: [], extras: [:], ttl: 0, expired: true)
                }
                return try self.requestResolve(host: host, requestIpType: type)
            },
            triggerResolveInBackground: { [weak self] host, type in
                self?.triggerResolveInBackground(host: host, requestIpType: type)
            },
            log: { [weak self] message in self?.log(message) }
        )
    }()

    init(accountId: String, config: ScloudInitConfig) {
        self.accountId = accountId
        self.config = config
        dispatchService.initialize()
    }

    func updateConfig(_ newConfig: ScloudInitConfig) {
        configLock.lock()
        config = newConfig
        configLock.unlock()
        _ = dispatchService.refresh(forceExpandOverride: false)
    }

    func setPreResolveHosts(_ hostList: [String], requestIpType: ScloudRequestIpType) {
        resolveHostService.setPreResolveHosts(hostList, requestIpType: requestIpType)
    }

    func getHttpDnsResultForHostSync(_ host: String, requestIpType: ScloudRequestIpType) -> ScloudHTTPDNSResult {
        return resolveHostService.getHttpDnsResultForHostSync(host, requestIpType: requestIpType)
    }

    func getHttpDnsResultForHostAsync(
        _ host: String,
        requestIpType: ScloudRequestIpType,
        callback: @escaping (ScloudHTTPDNSResult) -> Void
    ) {
        resolveHostService.getHttpDnsResultForHostAsync(host, requestIpType: requestIpType, callback: callback)
    }

    func getHttpDnsResultForHostSyncNonBlocking(_ host: String, requestIpType: ScloudRequestIpType) -> ScloudHTTPDNSResult {
        return resolveHostService.getHttpDnsResultForHostSyncNonBlocking(host, requestIpType: requestIpType)
    }

    func cleanHostCache(_ hosts: [String]?) {
        guard let hosts else {
            cache.clearAll()
            return
        }
        cache.clearHosts(hosts.compactMap(normalizeHost))
    }

    private func triggerResolveInBackground(host: String, requestIpType: ScloudRequestIpType) {
        let key = inFlightKey(host: host, requestIpType: requestIpType)
        stateLock.lock()
        if inFlightResolveKeys.contains(key) {
            stateLock.unlock()
            return
        }
        inFlightResolveKeys.insert(key)
        stateLock.unlock()

        workerQueue.async { [weak self] in
            defer {
                self?.stateLock.lock()
                self?.inFlightResolveKeys.remove(key)
                self?.stateLock.unlock()
            }
            _ = try? self?.requestResolve(host: host, requestIpType: requestIpType)
        }
    }

    private func requestResolve(host: String, requestIpType: ScloudRequestIpType) throws -> ScloudHTTPDNSResult {
        return try resolveRequestExecutor.requestResolve(host: host, requestIpType: requestIpType)
    }

    private func normalizeHost(_ host: String) -> String? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }

    private func safeConfig() -> ScloudInitConfig {
        configLock.lock()
        defer { configLock.unlock() }
        return config
    }

    private func shouldBypassHttpDns(host: String) -> Bool {
        return safeConfig().notUseHttpDnsFilter?.notUseHttpDns(host: host) == true
    }

    private func fallbackResult(host: String) -> ScloudHTTPDNSResult {
        return ScloudHTTPDNSResult(host: host, ips: [], ipv6s: [], extras: [:], ttl: 0, expired: true)
    }

    private func toPublicResult(_ item: ResolveItem, expired: Bool) -> ScloudHTTPDNSResult {
        return ScloudHTTPDNSResult(host: item.host, ips: item.ipsV4, ipv6s: item.ipsV6, extras: item.extras, ttl: item.ttl, expired: expired)
    }

    private func inFlightKey(host: String, requestIpType: ScloudRequestIpType) -> String {
        return "\(host):\(requestIpType.rawValue)"
    }

    private func log(_ message: String) {
        safeConfig().logger?.log(message)
    }
}
