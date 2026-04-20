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

    func requestResolve(host: String, requestIpType: ScloudRequestIpType) throws -> ScloudHTTPDNSResult {
        let config = getConfig()
        let aesBytes = try config.aesSecretKeyBytesForResolve()
        let query = try RequestAdapter.buildResolvePath(
            accountId: accountId,
            aesSecretKeyBytes: aesBytes,
            host: host,
            requestIpType: requestIpType,
            expEpochSeconds: Int64(Date().timeIntervalSince1970) + 600
        )

        let endpointsRound1 = dispatchService.orderedResolveEndpointsSnapshot()
        if let result = try resolveWithEndpoints(
            host: host,
            requestIpType: requestIpType,
            query: query,
            aesBytes: aesBytes,
            endpoints: endpointsRound1,
            logPrefix: "resolve"
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
            logPrefix: "resolve retry"
        ) {
            return result
        }

        throw ScloudError.network("resolve failed for all endpoints")
    }

    private func resolveWithEndpoints(
        host: String,
        requestIpType: ScloudRequestIpType,
        query: String,
        aesBytes: Data,
        endpoints: [ResolveEndpoint],
        logPrefix: String
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
                return toPublicResult(item, false)
            } catch {
                log("\(logPrefix) failed host=\(endpoint.host) ip=\(endpoint.connectIp ?? "<dns>"): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
