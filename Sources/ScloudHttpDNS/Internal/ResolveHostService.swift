import Foundation

final class ResolveHostService {
    private let queue: DispatchQueue
    private let cache: CacheStore
    private let getConfig: () -> ScloudInitConfig
    private let normalizeHost: (String) -> String?
    private let shouldBypassHttpDns: (String) -> Bool
    private let fallbackResult: (String) -> ScloudHTTPDNSResult
    private let toPublicResult: (ResolveItem, Bool) -> ScloudHTTPDNSResult
    private let requestResolve: (String, ScloudRequestIpType) throws -> ScloudHTTPDNSResult
    private let triggerResolveInBackground: (String, ScloudRequestIpType) -> Void
    private let log: (String) -> Void

    init(
        queue: DispatchQueue,
        cache: CacheStore,
        getConfig: @escaping () -> ScloudInitConfig,
        normalizeHost: @escaping (String) -> String?,
        shouldBypassHttpDns: @escaping (String) -> Bool,
        fallbackResult: @escaping (String) -> ScloudHTTPDNSResult,
        toPublicResult: @escaping (ResolveItem, Bool) -> ScloudHTTPDNSResult,
        requestResolve: @escaping (String, ScloudRequestIpType) throws -> ScloudHTTPDNSResult,
        triggerResolveInBackground: @escaping (String, ScloudRequestIpType) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.queue = queue
        self.cache = cache
        self.getConfig = getConfig
        self.normalizeHost = normalizeHost
        self.shouldBypassHttpDns = shouldBypassHttpDns
        self.fallbackResult = fallbackResult
        self.toPublicResult = toPublicResult
        self.requestResolve = requestResolve
        self.triggerResolveInBackground = triggerResolveInBackground
        self.log = log
    }

    func getHttpDnsResultForHostSync(_ host: String, requestIpType: ScloudRequestIpType) -> ScloudHTTPDNSResult {
        guard let normalizedHost = normalizeHost(host) else {
            return fallbackResult(host)
        }
        if shouldBypassHttpDns(normalizedHost) {
            log("host=\(normalizedHost) is filtered by notUseHttpDnsFilter")
            return fallbackResult(normalizedHost)
        }

        let now = nowMillis()
        if let cached = cache.get(host: normalizedHost, type: requestIpType), (!cached.isExpired(nowMillis: now) || getConfig().enableExpiredIp) {
            if cached.isExpired(nowMillis: now) {
                triggerResolveInBackground(normalizedHost, requestIpType)
            }
            return toPublicResult(cached.item, cached.isExpired(nowMillis: now))
        }

        do {
            return try requestResolve(normalizedHost, requestIpType)
        } catch {
            log("sync resolve failed host=\(normalizedHost) type=\(requestIpType.rawValue): \(error.localizedDescription)")
            return fallbackResult(normalizedHost)
        }
    }

    func getHttpDnsResultForHostAsync(
        _ host: String,
        requestIpType: ScloudRequestIpType,
        callback: @escaping (ScloudHTTPDNSResult) -> Void
    ) {
        queue.async {
            let result = self.getHttpDnsResultForHostSync(host, requestIpType: requestIpType)
            callback(result)
        }
    }

    func getHttpDnsResultForHostSyncNonBlocking(_ host: String, requestIpType: ScloudRequestIpType) -> ScloudHTTPDNSResult {
        guard let normalizedHost = normalizeHost(host) else {
            return fallbackResult(host)
        }
        if shouldBypassHttpDns(normalizedHost) {
            return fallbackResult(normalizedHost)
        }

        let now = nowMillis()
        if let cached = cache.get(host: normalizedHost, type: requestIpType), (!cached.isExpired(nowMillis: now) || getConfig().enableExpiredIp) {
            if cached.isExpired(nowMillis: now) {
                triggerResolveInBackground(normalizedHost, requestIpType)
            }
            return toPublicResult(cached.item, cached.isExpired(nowMillis: now))
        }

        triggerResolveInBackground(normalizedHost, requestIpType)
        return fallbackResult(normalizedHost)
    }

    func setPreResolveHosts(_ hostList: [String], requestIpType: ScloudRequestIpType) {
        let now = nowMillis()
        let normalized = Array(Set(hostList.compactMap { normalizeHost($0) }.filter { !shouldBypassHttpDns($0) }))
        for host in normalized {
            let cached = cache.get(host: host, type: requestIpType)
            if cached == nil || cached?.isExpired(nowMillis: now) == true {
                triggerResolveInBackground(host, requestIpType)
            }
        }
    }

    private func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
