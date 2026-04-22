import Foundation

final class ResolveRequestExecutor {
    private let accountId: String
    private let getConfig: () -> ScloudInitConfig
    private let cache: CacheStore
    private let dispatchService: DispatchService
    private let transport: HTTPTransport
    private let toPublicResult: (ResolveItem, Bool) -> ScloudHTTPDNSResult
    private let log: (String) -> Void

    init(
        accountId: String,
        getConfig: @escaping () -> ScloudInitConfig,
        cache: CacheStore,
        dispatchService: DispatchService,
        transport: HTTPTransport,
        toPublicResult: @escaping (ResolveItem, Bool) -> ScloudHTTPDNSResult,
        log: @escaping (String) -> Void
    ) {
        self.accountId = accountId
        self.getConfig = getConfig
        self.cache = cache
        self.dispatchService = dispatchService
        self.transport = transport
        self.toPublicResult = toPublicResult
        self.log = log
    }

    func requestResolve(host: String, requestIpType: ScloudRequestIpType, source: String) throws -> ScloudHTTPDNSResult {
        let config = getConfig()
        let aesBytes = try config.aesSecretKeyBytesForResolve()
        let query = try RequestAdapter.buildResolvePath(
            accountId: accountId,
            aesSecretKeyBytes: aesBytes,
            host: host,
            requestIpType: requestIpType,
            expEpochSeconds: Int64(Date().timeIntervalSince1970) + 600,
            clientIp: config.clientIp
        )

        let endpointsRound1 = dispatchService.orderedResolveEndpointsSnapshot()
        if let result = try resolveWithEndpoints(
            host: host,
            requestIpType: requestIpType,
            query: query,
            aesBytes: aesBytes,
            endpoints: endpointsRound1,
            logPrefix: "resolve",
            source: source
        ) {
            return result
        }

        if endpointsRound1.isEmpty {
            log("no resolve endpoints available after initial dispatch, skip resolve")
            throw ScloudError.network("no resolve endpoints available")
        }

        _ = dispatchService.refresh(forceExpandOverride: true)
        let endpointsRound2 = dispatchService.orderedResolveEndpointsSnapshot()
        if endpointsRound2.isEmpty {
            log("no resolve endpoints available after dispatch refresh, skip resolve")
            throw ScloudError.network("no resolve endpoints available after refresh")
        }
        if let result = try resolveWithEndpoints(
            host: host,
            requestIpType: requestIpType,
            query: query,
            aesBytes: aesBytes,
            endpoints: endpointsRound2,
            logPrefix: "resolve retry",
            source: source
        ) {
            return result
        }

        throw ScloudError.network("resolve failed for all endpoints")
    }

    func requestResolveBatch(hosts: [String], requestIpType: ScloudRequestIpType, source: String) throws {
        let targetHosts = hosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if targetHosts.isEmpty { return }

        let config = getConfig()
        let aesBytes = try config.aesSecretKeyBytesForResolve()
        let dnValue = Array(Set(targetHosts)).joined(separator: ",")
        let query = try RequestAdapter.buildResolvePath(
            accountId: accountId,
            aesSecretKeyBytes: aesBytes,
            host: dnValue,
            requestIpType: requestIpType,
            expEpochSeconds: Int64(Date().timeIntervalSince1970) + 600,
            clientIp: config.clientIp
        )

        let endpointsRound1 = dispatchService.orderedResolveEndpointsSnapshot()
        if try resolveWithEndpointsBatch(
            requestIpType: requestIpType,
            query: query,
            aesBytes: aesBytes,
            endpoints: endpointsRound1,
            logPrefix: "resolve batch",
            source: source
        ) {
            return
        }

        if endpointsRound1.isEmpty {
            log("no resolve endpoints available after initial dispatch, skip resolve batch")
            throw ScloudError.network("no resolve endpoints available")
        }

        _ = dispatchService.refresh(forceExpandOverride: true)
        let endpointsRound2 = dispatchService.orderedResolveEndpointsSnapshot()
        if endpointsRound2.isEmpty {
            log("no resolve endpoints available after dispatch refresh, skip resolve batch")
            throw ScloudError.network("no resolve endpoints available after refresh")
        }

        if try resolveWithEndpointsBatch(
            requestIpType: requestIpType,
            query: query,
            aesBytes: aesBytes,
            endpoints: endpointsRound2,
            logPrefix: "resolve batch retry",
            source: source
        ) {
            return
        }

        throw ScloudError.network("resolve batch failed for all endpoints")
    }

    private func resolveWithEndpoints(
        host: String,
        requestIpType: ScloudRequestIpType,
        query: String,
        aesBytes: Data,
        endpoints: [ResolveEndpoint],
        logPrefix: String,
        source: String
    ) throws -> ScloudHTTPDNSResult? {
        let config = getConfig()
        for endpoint in endpoints {
            do {
                log("\(logPrefix) endpoint host=\(endpoint.host) ip=\(endpoint.connectIp ?? "<dns>")")
                let responseBody = try transport.request(
                    host: endpoint.host,
                    pathWithQuery: query,
                    connectIp: endpoint.connectIp,
                    portOverride: config.resolvePortOverride,
                    timeoutMillis: config.timeoutMillis,
                    enableHttps: config.enableHttps
                )
                let decrypted = try ResponseAdapter.decryptResolvePayload(aesSecretKeyBytes: aesBytes, rawResponseBody: responseBody)
                let item = try ResponseAdapter.parseResolvePayload(
                    requestHost: host,
                    requestIpType: requestIpType,
                    payload: decrypted,
                    ttlMapper: config.cacheTtlChanger?.changeCacheTtl
                )
                dispatchService.markEndpointSucceeded(endpoint)
                cache.put(host: host, type: requestIpType, item: item, nowMillis: nowMillis())
                log("source=\(source) cache write host=\(host) type=\(requestIpType.rawValue) ttl=\(item.ttl) v4=\(item.ipsV4.count) v6=\(item.ipsV6.count)")
                return toPublicResult(item, false)
            } catch {
                log("\(logPrefix) failed host=\(endpoint.host) ip=\(endpoint.connectIp ?? "<dns>"): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func resolveWithEndpointsBatch(
        requestIpType: ScloudRequestIpType,
        query: String,
        aesBytes: Data,
        endpoints: [ResolveEndpoint],
        logPrefix: String,
        source: String
    ) throws -> Bool {
        let config = getConfig()
        for endpoint in endpoints {
            do {
                log("\(logPrefix) endpoint host=\(endpoint.host) ip=\(endpoint.connectIp ?? "<dns>")")
                let responseBody = try transport.request(
                    host: endpoint.host,
                    pathWithQuery: query,
                    connectIp: endpoint.connectIp,
                    portOverride: config.resolvePortOverride,
                    timeoutMillis: config.timeoutMillis,
                    enableHttps: config.enableHttps
                )
                let decrypted = try ResponseAdapter.decryptResolvePayload(aesSecretKeyBytes: aesBytes, rawResponseBody: responseBody)
                let resolvedItems = try ResponseAdapter.parseResolvePayloadBatch(
                    requestIpType: requestIpType,
                    payload: decrypted,
                    ttlMapper: config.cacheTtlChanger?.changeCacheTtl
                )
                if resolvedItems.isEmpty {
                    continue
                }

                dispatchService.markEndpointSucceeded(endpoint)
                let now = nowMillis()
                for item in resolvedItems {
                    cache.put(host: item.host, type: requestIpType, item: item, nowMillis: now)
                    log("source=\(source) cache write host=\(item.host) type=\(requestIpType.rawValue) ttl=\(item.ttl) v4=\(item.ipsV4.count) v6=\(item.ipsV6.count)")
                }
                log("\(logPrefix) success endpoint host=\(endpoint.host) ip=\(endpoint.connectIp ?? "<dns>") answers=\(resolvedItems.count)")
                return true
            } catch {
                log("\(logPrefix) failed host=\(endpoint.host) ip=\(endpoint.connectIp ?? "<dns>"): \(error.localizedDescription)")
            }
        }
        return false
    }

    private func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
