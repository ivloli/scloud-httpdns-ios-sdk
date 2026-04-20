import Foundation
import Darwin

final class DispatchService {
    private static let minDispatchTimeoutMillis = 10_000

    private let accountId: String
    private let bootstrap: BootstrapConfig
    private let getConfig: () -> ScloudInitConfig
    private let transport: HTTPTransport
    private let log: (String) -> Void

    private let lock = NSLock()
    private var resolveHost: String
    private var resolveEndpoints: [ResolveEndpoint]
    private var resolveEndpointCursor: Int = 0
    private var nextDispatchRefreshAtMillis: Int64 = 0
    private let schedulerQueue = DispatchQueue(label: "scloud.httpdns.dispatch.scheduler")
    private var schedulerTimer: DispatchSourceTimer?

    init(
        accountId: String,
        bootstrap: BootstrapConfig,
        getConfig: @escaping () -> ScloudInitConfig,
        transport: HTTPTransport,
        log: @escaping (String) -> Void
    ) {
        self.accountId = accountId
        self.bootstrap = bootstrap
        self.getConfig = getConfig
        self.transport = transport
        self.log = log
        self.resolveHost = ""
        self.resolveEndpoints = []
    }

    func initialize() {
        let config = getConfig()
        if let overrideHost = config.resolveHostOverride, !overrideHost.isEmpty {
            replaceResolveEndpoints(buildOverrideEndpoints(host: overrideHost, connectIp: config.resolveConnectIpOverride, includeDnsFallback: false))
            updateNextDispatchRefreshAt(ttlSeconds: nil)
        } else {
            _ = refresh(forceExpandOverride: false)
        }
        scheduleHealthRefresh()
    }

    @discardableResult
    func refresh(forceExpandOverride: Bool) -> Bool {
        let config = getConfig()
        if let overrideHost = config.resolveHostOverride, !overrideHost.isEmpty {
            replaceResolveEndpoints(buildOverrideEndpoints(host: overrideHost, connectIp: config.resolveConnectIpOverride, includeDnsFallback: forceExpandOverride))
            updateNextDispatchRefreshAt(ttlSeconds: nil)
            return true
        }

        guard let aesBytes = try? config.aesSecretKeyBytesForDispatch() else {
            return false
        }

        let exp = Int64(Date().timeIntervalSince1970) + 600
        guard let query = try? RequestAdapter.buildDispatchPath(
            accountId: accountId,
            aesSecretKeyBytes: aesBytes,
            regionValue: config.region.serverValue,
            expEpochSeconds: exp
        ) else {
            return false
        }

        let candidates: [(host: String, ip: String?)] = [(bootstrap.domain, nil)]

        for candidate in candidates {
            do {
                log("dispatch attempt host=\(candidate.host) ip=\(candidate.ip ?? "<dns>")")
                let responseBody = try transport.request(
                    host: candidate.host,
                    pathWithQuery: query,
                    connectIp: candidate.ip,
                    portOverride: nil,
                    timeoutMillis: max(config.timeoutMillis, Self.minDispatchTimeoutMillis),
                    enableHttps: config.enableHttps
                )
                let decrypted = try ResponseAdapter.decryptDispatchPayload(aesSecretKeyBytes: aesBytes, rawResponseBody: responseBody)
                let parsed = try ResponseAdapter.parseDispatchPayload(decrypted)
                let endpoints = buildResolveEndpoints(dispatchResult: parsed)
                if !endpoints.isEmpty {
                    replaceResolveEndpoints(endpoints)
                    log("dispatch success host=\(candidate.host) ip=\(candidate.ip ?? "<dns>") endpoints=\(endpoints.count)")
                    updateNextDispatchRefreshAt(ttlSeconds: parsed.ttlSeconds)
                    return true
                }
            } catch {
                log("dispatch failed host=\(candidate.host) ip=\(candidate.ip ?? "<dns>"): \(error.localizedDescription)")
            }
        }

        updateNextDispatchRefreshAt(ttlSeconds: nil)
        return false
    }

    func orderedResolveEndpointsSnapshot() -> [ResolveEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        let endpoints = resolveEndpoints
        guard !endpoints.isEmpty else { return [] }
        let start = resolveEndpointCursor % endpoints.count
        return (0..<endpoints.count).map { endpoints[(start + $0) % endpoints.count] }
    }

    func markEndpointSucceeded(_ endpoint: ResolveEndpoint) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = resolveEndpoints.firstIndex(of: endpoint) else { return }
        resolveEndpointCursor = index
        resolveHost = endpoint.host
    }

    private func buildResolveEndpoints(dispatchResult: DispatchResult) -> [ResolveEndpoint] {
        var out: [ResolveEndpoint] = []
        var seen: Set<String> = []
        let domains = dispatchResult.domains.filter { !$0.isEmpty }
        let ips = dispatchResult.ips.filter { !$0.isEmpty }

        for domain in domains {
            appendUnique(ResolveEndpoint(host: domain, connectIp: nil), out: &out, seen: &seen)
        }
        let hostForIp = domains.first ?? resolveHost
        for ip in ips {
            appendUnique(ResolveEndpoint(host: hostForIp, connectIp: ip), out: &out, seen: &seen)
        }
        return out
    }

    private func buildOverrideEndpoints(host: String, connectIp: String?, includeDnsFallback: Bool) -> [ResolveEndpoint] {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            return [ResolveEndpoint(host: bootstrap.domain, connectIp: nil)]
        }

        if let connectIp, !connectIp.isEmpty {
            return [ResolveEndpoint(host: cleanHost, connectIp: connectIp)]
        }

        var out: [ResolveEndpoint] = []
        var seen: Set<String> = []
        appendUnique(ResolveEndpoint(host: cleanHost, connectIp: nil), out: &out, seen: &seen)
        if includeDnsFallback {
            do {
                let addresses = try resolveIPs(host: cleanHost)
                for ip in addresses {
                    appendUnique(ResolveEndpoint(host: cleanHost, connectIp: ip), out: &out, seen: &seen)
                }
            } catch {
                log("resolve override host dns lookup failed host=\(cleanHost): \(error.localizedDescription)")
            }
        }
        return out
    }

    private func appendUnique(_ endpoint: ResolveEndpoint, out: inout [ResolveEndpoint], seen: inout Set<String>) {
        let key = "\(endpoint.host)|\(endpoint.connectIp ?? "")"
        if seen.insert(key).inserted {
            out.append(endpoint)
        }
    }

    private func resolveIPs(host: String) throws -> [String] {
        let cfHost = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
        CFHostStartInfoResolution(cfHost, .addresses, nil)
        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(cfHost, &success)?.takeUnretainedValue() as? [Data], success.boolValue else {
            return []
        }
        var result: [String] = []
        for data in addresses {
            let ip = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                    return String(cString: buffer)
                }
                if family == sa_family_t(AF_INET6) {
                    var addr6 = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    guard inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
                    return String(cString: buffer)
                }
                return nil
            }
            if let ip, !ip.isEmpty {
                result.append(ip)
            }
        }
        return result
    }

    private func replaceResolveEndpoints(_ endpoints: [ResolveEndpoint]) {
        lock.lock()
        defer { lock.unlock() }
        resolveEndpoints = endpoints
        resolveEndpointCursor = 0
        resolveHost = endpoints.first?.host ?? ""
    }

    private func scheduleHealthRefresh() {
        schedulerQueue.sync {
            guard schedulerTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: schedulerQueue)
            timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.nowMillis() >= self.nextDispatchRefreshAtMillis {
                    _ = self.refresh(forceExpandOverride: false)
                }
            }
            schedulerTimer = timer
            timer.resume()
        }
    }

    private func updateNextDispatchRefreshAt(ttlSeconds: Int?) {
        let now = nowMillis()
        if let ttlSeconds, ttlSeconds > 0 {
            let ttlMillis = Int64(ttlSeconds) * 1000
            let refreshMillis = max(5000, ttlMillis - 30_000)
            nextDispatchRefreshAtMillis = now + refreshMillis
        } else {
            nextDispatchRefreshAtMillis = now + 5 * 60 * 1000
        }
    }

    private func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
