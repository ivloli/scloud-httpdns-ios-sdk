import Foundation

final class ResolveHostService {
    private let queue: DispatchQueue
    private let cache: CacheStore
    private let getConfig: () -> ScloudInitConfig
    private let normalizeHost: (String) -> String?
    private let shouldBypassHttpDns: (String) -> Bool
    private let fallbackResult: (String) -> ScloudHTTPDNSResult
    private let toPublicResult: (ResolveItem, Bool) -> ScloudHTTPDNSResult
    private let requestResolve: (String, ScloudRequestIpType, String) throws -> ScloudHTTPDNSResult
    private let triggerResolveInBackground: (String, ScloudRequestIpType, String) -> Void
    private let log: (String) -> Void

    init(
        queue: DispatchQueue,
        cache: CacheStore,
        getConfig: @escaping () -> ScloudInitConfig,
        normalizeHost: @escaping (String) -> String?,
        shouldBypassHttpDns: @escaping (String) -> Bool,
        fallbackResult: @escaping (String) -> ScloudHTTPDNSResult,
        toPublicResult: @escaping (ResolveItem, Bool) -> ScloudHTTPDNSResult,
        requestResolve: @escaping (String, ScloudRequestIpType, String) throws -> ScloudHTTPDNSResult,
        triggerResolveInBackground: @escaping (String, ScloudRequestIpType, String) -> Void,
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
                log("source=sync cache hit expired host=\(normalizedHost) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
                log("source=sync cache refresh in background host=\(normalizedHost) type=\(requestIpType.rawValue)")
                triggerResolveInBackground(normalizedHost, requestIpType, "sync-expired")
            } else {
                log("source=sync cache hit host=\(normalizedHost) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
            }
            return toPublicResult(cached.item, cached.isExpired(nowMillis: now))
        }

        log("source=sync cache miss host=\(normalizedHost) type=\(requestIpType.rawValue)")

        do {
            return try requestResolve(normalizedHost, requestIpType, "sync")
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
            guard let normalizedHost = self.normalizeHost(host) else {
                callback(self.fallbackResult(host))
                return
            }
            if self.shouldBypassHttpDns(normalizedHost) {
                callback(self.fallbackResult(normalizedHost))
                return
            }
            let result = (try? self.requestResolve(normalizedHost, requestIpType, "async")) ?? self.fallbackResult(normalizedHost)
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
                log("source=nonblocking cache hit expired host=\(normalizedHost) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
                log("source=nonblocking cache refresh in background host=\(normalizedHost) type=\(requestIpType.rawValue)")
                triggerResolveInBackground(normalizedHost, requestIpType, "nonblocking-expired")
            } else {
                log("source=nonblocking cache hit host=\(normalizedHost) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
            }
            return toPublicResult(cached.item, cached.isExpired(nowMillis: now))
        }

        log("source=nonblocking cache miss host=\(normalizedHost) type=\(requestIpType.rawValue)")
        triggerResolveInBackground(normalizedHost, requestIpType, "nonblocking")
        return fallbackResult(normalizedHost)
    }

    func setPreResolveHosts(_ hostList: [String], requestIpType: ScloudRequestIpType) {
        let now = nowMillis()
        let normalized = Array(Set(hostList.compactMap { normalizeHost($0) }.filter { !shouldBypassHttpDns($0) }))
        for host in normalized {
            let cached = cache.get(host: host, type: requestIpType)
            if cached == nil || cached?.isExpired(nowMillis: now) == true {
                log("source=preResolve schedule host=\(host) type=\(requestIpType.rawValue)")
                triggerResolveInBackground(host, requestIpType, "preResolve")
            } else if let cached {
                log("source=preResolve skip cache-hit host=\(host) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
            }
        }
    }

    private func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
