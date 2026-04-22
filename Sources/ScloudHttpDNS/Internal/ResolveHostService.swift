import Foundation

final class ResolveHostService {
    private let queue: DispatchQueue
    private let cache: CacheStore
    private let getConfig: () -> ScloudInitConfig
    private let normalizeHost: (String) -> String?
    private let shouldBypassHttpDns: (String) -> Bool
    private let fallbackResult: (String) -> ScloudHTTPDNSResult
    private let toPublicResult: (ResolveItem, Bool) -> ScloudHTTPDNSResult
    private let requestResolveBatch: ([String], ScloudRequestIpType, String) throws -> Void
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
        requestResolveBatch: @escaping ([String], ScloudRequestIpType, String) throws -> Void,
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
        self.requestResolveBatch = requestResolveBatch
        self.requestResolve = requestResolve
        self.triggerResolveInBackground = triggerResolveInBackground
        self.log = log
    }

    func getHttpDnsResultForHostSync(_ hostList: [String], requestIpType: ScloudRequestIpType) -> [ScloudHTTPDNSResult] {
        let normalizedHosts = hostList.compactMap { normalizeHost($0) }
        if normalizedHosts.isEmpty { return [] }

        let bypassHosts = Set(normalizedHosts.filter { shouldBypassHttpDns($0) })
        for host in bypassHosts {
            log("host=\(host) is filtered by notUseHttpDnsFilter")
        }

        let targets = Array(Set(normalizedHosts.filter { !bypassHosts.contains($0) }))
        if targets.isEmpty {
            return normalizedHosts.map { fallbackResult($0) }
        }

        let now = nowMillis()
        var resultMap: [String: ScloudHTTPDNSResult] = [:]
        var pendingHosts: [String] = []

        for host in targets {
            if let cached = cache.get(host: host, type: requestIpType), (!cached.isExpired(nowMillis: now) || getConfig().enableExpiredIp) {
                if cached.isExpired(nowMillis: now) {
                    log("source=sync cache hit expired host=\(host) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
                    log("source=sync cache refresh in background host=\(host) type=\(requestIpType.rawValue)")
                    triggerResolveInBackground(host, requestIpType, "sync-expired")
                } else {
                    log("source=sync cache hit host=\(host) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
                }
                resultMap[host] = toPublicResult(cached.item, cached.isExpired(nowMillis: now))
            } else {
                log("source=sync cache miss host=\(host) type=\(requestIpType.rawValue)")
                pendingHosts.append(host)
            }
        }

        if !pendingHosts.isEmpty {
            do {
                if pendingHosts.count == 1, let host = pendingHosts.first {
                    resultMap[host] = try requestResolve(host, requestIpType, "sync")
                } else {
                    try requestResolveBatch(pendingHosts, requestIpType, "sync-batch")
                    let updatedNow = nowMillis()
                    for host in pendingHosts {
                        if let cached = cache.get(host: host, type: requestIpType) {
                            resultMap[host] = toPublicResult(cached.item, cached.isExpired(nowMillis: updatedNow))
                        }
                    }
                }
            } catch {
                log("sync batch resolve failed hosts=\(pendingHosts) type=\(requestIpType.rawValue): \(error.localizedDescription)")
            }
        }

        return normalizedHosts.map { host in
            if bypassHosts.contains(host) {
                return fallbackResult(host)
            }
            return resultMap[host] ?? fallbackResult(host)
        }
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

    func getHttpDnsResultForHostAsync(
        _ hostList: [String],
        requestIpType: ScloudRequestIpType,
        callback: @escaping ([ScloudHTTPDNSResult]) -> Void
    ) {
        queue.async {
            let results = self.getHttpDnsResultForHostSync(hostList, requestIpType: requestIpType)
            callback(results)
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

    func getHttpDnsResultForHostSyncNonBlocking(_ hostList: [String], requestIpType: ScloudRequestIpType) -> [ScloudHTTPDNSResult] {
        let normalizedHosts = hostList.compactMap { normalizeHost($0) }
        if normalizedHosts.isEmpty { return [] }

        let bypassHosts = Set(normalizedHosts.filter { shouldBypassHttpDns($0) })
        let targets = Array(Set(normalizedHosts.filter { !bypassHosts.contains($0) }))
        if targets.isEmpty {
            return normalizedHosts.map { fallbackResult($0) }
        }

        let now = nowMillis()
        var resultMap: [String: ScloudHTTPDNSResult] = [:]
        var refreshHosts: [String] = []

        for host in targets {
            if let cached = cache.get(host: host, type: requestIpType), (!cached.isExpired(nowMillis: now) || getConfig().enableExpiredIp) {
                if cached.isExpired(nowMillis: now) {
                    log("source=nonblocking cache hit expired host=\(host) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
                    refreshHosts.append(host)
                } else {
                    log("source=nonblocking cache hit host=\(host) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
                }
                resultMap[host] = toPublicResult(cached.item, cached.isExpired(nowMillis: now))
            } else {
                log("source=nonblocking cache miss host=\(host) type=\(requestIpType.rawValue)")
                refreshHosts.append(host)
                resultMap[host] = fallbackResult(host)
            }
        }

        if !refreshHosts.isEmpty {
            if refreshHosts.count == 1, let host = refreshHosts.first {
                log("source=nonblocking cache refresh in background host=\(host) type=\(requestIpType.rawValue)")
                triggerResolveInBackground(host, requestIpType, "nonblocking")
            } else {
                log("source=nonblocking schedule batch hosts=\(refreshHosts) type=\(requestIpType.rawValue)")
                queue.async {
                    do {
                        try self.requestResolveBatch(refreshHosts, requestIpType, "nonblocking")
                    } catch {
                        self.log("source=nonblocking batch failed hosts=\(refreshHosts) type=\(requestIpType.rawValue): \(error.localizedDescription)")
                    }
                }
            }
        }

        return normalizedHosts.map { host in
            if bypassHosts.contains(host) {
                return fallbackResult(host)
            }
            return resultMap[host] ?? fallbackResult(host)
        }
    }

    func setPreResolveHosts(_ hostList: [String], requestIpType: ScloudRequestIpType) {
        let now = nowMillis()
        let normalized = Array(Set(hostList.compactMap { normalizeHost($0) }.filter { !shouldBypassHttpDns($0) }))
        let pending = normalized.filter { host in
            let cached = cache.get(host: host, type: requestIpType)
            if cached == nil || cached?.isExpired(nowMillis: now) == true {
                return true
            }
            if let cached {
                log("source=preResolve skip cache-hit host=\(host) type=\(requestIpType.rawValue) ttl=\(cached.item.ttl)")
            }
            return false
        }
        if pending.isEmpty {
            return
        }

        if pending.count == 1, let host = pending.first {
            log("source=preResolve schedule host=\(host) type=\(requestIpType.rawValue)")
            triggerResolveInBackground(host, requestIpType, "preResolve")
            return
        }

        log("source=preResolve schedule batch hosts=\(pending) type=\(requestIpType.rawValue)")
        queue.async {
            do {
                try self.requestResolveBatch(pending, requestIpType, "preResolve")
            } catch {
                self.log("source=preResolve batch failed hosts=\(pending) type=\(requestIpType.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
