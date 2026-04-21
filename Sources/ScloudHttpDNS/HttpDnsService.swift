import Foundation

@objc public enum AlicloudHttpDNS_IPType: Int {
    case v4 = 0
    case v6 = 1
    case v64 = 2
}

@objc public enum HttpdnsQueryIPType: Int {
    case auto = 0
    case ipv4 = 1
    case ipv6 = 2
    case both = 3
}

@objc public protocol HttpdnsLogger: AnyObject {
    func log(_ message: String)
}

private final class HttpdnsLoggerAdapter: ScloudLogger {
    weak var logger: HttpdnsLogger?

    init(logger: HttpdnsLogger?) {
        self.logger = logger
    }

    func log(_ message: String) {
        logger?.log(message)
    }
}

@objcMembers
public final class HttpdnsRequest: NSObject {
    public var host: String
    public var resolveTimeoutInSecond: Double
    public var queryIpType: HttpdnsQueryIPType
    public var sdnsParams: [String: String]?
    public var cacheKey: String?
    public var accountId: String?

    public init(host: String, queryIpType: HttpdnsQueryIPType = .auto) {
        self.host = host
        self.queryIpType = queryIpType
        self.resolveTimeoutInSecond = 2.0
    }

    public init(
        host: String,
        queryIpType: HttpdnsQueryIPType,
        sdnsParams: [String: String]?,
        cacheKey: String?
    ) {
        self.host = host
        self.queryIpType = queryIpType
        self.sdnsParams = sdnsParams
        self.cacheKey = cacheKey
        self.resolveTimeoutInSecond = 2.0
    }
}

@objcMembers
public final class HttpdnsResult: NSObject {
    public let host: String
    public let ips: [String]
    public let ipv6s: [String]
    public let ttl: Int
    public let expired: Bool
    public let extras: [String: String]

    init(_ value: ScloudHTTPDNSResult) {
        self.host = value.host
        self.ips = value.ips
        self.ipv6s = value.ipv6s
        self.ttl = value.ttl
        self.expired = value.expired
        self.extras = value.extras
    }

    public func hasIpv4Address() -> Bool {
        return !ips.isEmpty
    }

    public func hasIpv6Address() -> Bool {
        return !ipv6s.isEmpty
    }

    public func firstIpv4Address() -> String? {
        return ips.first
    }

    public func firstIpv6Address() -> String? {
        return ipv6s.first
    }
}

@objcMembers
public final class HttpDnsService: NSObject {
    private static let lock = NSLock()
    private static var instances: [String: HttpDnsService] = [:]

    public let accountID: String
    private var config: ScloudInitConfig
    private var loggerAdapter: HttpdnsLoggerAdapter?

    @discardableResult
    public init(accountID: String, aesSecretKey: String, logger: HttpdnsLogger? = nil) {
        self.accountID = accountID
        self.config = ScloudInitConfig(aesSecretKey: aesSecretKey)
        if let logger {
            let adapter = HttpdnsLoggerAdapter(logger: logger)
            self.loggerAdapter = adapter
            self.config.logger = adapter
        }
        super.init()
        ScloudHttpDns.initialize(accountId: accountID, config: config)
        HttpDnsService.lock.lock()
        HttpDnsService.instances[accountID] = self
        HttpDnsService.lock.unlock()
    }

    @discardableResult
    @objc(initWithAccountID:aesSecretKey:)
    public static func initWithAccountID(_ accountID: String, aesSecretKey: String) -> HttpDnsService {
        return initWithAccountID(accountID, aesSecretKey: aesSecretKey, logger: nil)
    }

    @discardableResult
    public static func initWithAccountID(_ accountID: String, aesSecretKey: String, logger: HttpdnsLogger?) -> HttpDnsService {
        lock.lock()
        if let existing = instances[accountID] {
            existing.config.aesSecretKey = aesSecretKey
            if let logger {
                let adapter = HttpdnsLoggerAdapter(logger: logger)
                existing.loggerAdapter = adapter
                existing.config.logger = adapter
            }
            ScloudHttpDns.initialize(accountId: accountID, config: existing.config)
            lock.unlock()
            return existing
        }
        lock.unlock()
        return HttpDnsService(accountID: accountID, aesSecretKey: aesSecretKey, logger: logger)
    }

    @objc(getInstanceByAccountId:)
    public static func getInstanceByAccountId(_ accountID: String) -> HttpDnsService? {
        lock.lock()
        defer { lock.unlock() }
        return instances[accountID]
    }

    @objc(sharedInstance)
    public static func sharedInstance() -> HttpDnsService {
        lock.lock()
        defer { lock.unlock() }
        if let first = instances.values.first {
            return first
        }
        fatalError("HttpDnsService is not initialized. Call initWithAccountID(_:aesSecretKey:) first.")
    }

    public func setRegion(_ region: String) {
        switch region.lowercased() {
        case "cn":
            config.region = .cn
        case "os", "oversea", "overseas":
            config.region = .os
        case "global":
            config.region = .global
        default:
            config.region = .default
        }
        reloadConfig()
    }

    public func setReuseExpiredIPEnabled(_ enable: Bool) {
        config.enableExpiredIp = enable
        reloadConfig()
    }

    public func setExpiredIPEnabled(_ enable: Bool) {
        setReuseExpiredIPEnabled(enable)
    }

    public func setHTTPSRequestEnabled(_ enable: Bool) {
        config.enableHttps = enable
        reloadConfig()
    }

    public func setNetworkingTimeoutInterval(_ timeoutInterval: TimeInterval) {
        let millis = Int(timeoutInterval * 1000)
        config.timeoutMillis = max(100, min(millis, 5000))
        reloadConfig()
    }

    public func setLogger(_ logger: HttpdnsLogger?) {
        if let logger {
            let adapter = HttpdnsLoggerAdapter(logger: logger)
            loggerAdapter = adapter
            config.logger = adapter
        } else {
            loggerAdapter = nil
            config.logger = nil
        }
        reloadConfig()
    }

    public func setPersistentCacheIPEnabled(_ enable: Bool) {
        config.enableCacheIp = enable
        reloadConfig()
    }

    public func setCachedIPEnabled(_ enable: Bool) {
        setPersistentCacheIPEnabled(enable)
    }

    public func setResolveEndpoint(host: String, connectIp: String? = nil, port: Int = 0) {
        config.resolveHostOverride = host.trimmingCharacters(in: .whitespacesAndNewlines)
        config.resolveConnectIpOverride = connectIp?.trimmingCharacters(in: .whitespacesAndNewlines)
        config.resolvePortOverride = (1...65535).contains(port) ? port : nil
        reloadConfig()
    }

    public func clearResolveEndpointOverride() {
        config.resolveHostOverride = nil
        config.resolveConnectIpOverride = nil
        config.resolvePortOverride = nil
        reloadConfig()
    }

    public func setPreResolveHosts(_ hosts: [String]) {
        service().setPreResolveHosts(hosts, requestIpType: .v4)
    }

    public func setPreResolveHosts(_ hosts: [String], byIPType ipType: HttpdnsQueryIPType) {
        service().setPreResolveHosts(hosts, requestIpType: ipType.toInternal())
    }

    @objc(setPreResolveHosts:queryIPType:)
    public func setPreResolveHosts(_ hosts: [String], queryIPType ipType: AlicloudHttpDNS_IPType) {
        service().setPreResolveHosts(hosts, requestIpType: ipType.toInternal())
    }

    public func getHttpDnsResultForHostSync(_ host: String) -> HttpdnsResult {
        return HttpdnsResult(service().getHttpDnsResultForHostSync(host, requestIpType: .v4))
    }

    public func getHttpDnsResultForHostSync(_ host: String, byIPType ipType: HttpdnsQueryIPType) -> HttpdnsResult {
        return HttpdnsResult(service().getHttpDnsResultForHostSync(host, requestIpType: ipType.toInternal()))
    }

    @objc(getHttpDnsResultForHostSync:queryIPType:)
    public func getHttpDnsResultForHostSync(_ host: String, queryIPType ipType: AlicloudHttpDNS_IPType) -> HttpdnsResult {
        return HttpdnsResult(service().getHttpDnsResultForHostSync(host, requestIpType: ipType.toInternal()))
    }

    @nonobjc
    public func getHttpDnsResultForHostSync(_ request: HttpdnsRequest) -> HttpdnsResult {
        let previous = config.timeoutMillis
        if request.resolveTimeoutInSecond > 0 {
            config.timeoutMillis = max(100, min(Int(request.resolveTimeoutInSecond * 1000), 5000))
            reloadConfig()
        }
        defer {
            if config.timeoutMillis != previous {
                config.timeoutMillis = previous
                reloadConfig()
            }
        }
        return HttpdnsResult(service().getHttpDnsResultForHostSync(request.host, requestIpType: request.queryIpType.toInternal()))
    }

    @objc(getHttpDnsResultForRequestSync:)
    public func getHttpDnsResultForRequestSync(_ request: HttpdnsRequest) -> HttpdnsResult {
        return getHttpDnsResultForHostSync(request)
    }

    public func getHttpDnsResultForHostAsync(_ host: String, completion: @escaping (HttpdnsResult) -> Void) {
        service().getHttpDnsResultForHostAsync(host, requestIpType: .v4) { result in
            completion(HttpdnsResult(result))
        }
    }

    public func getHttpDnsResultForHostAsync(_ host: String, byIPType ipType: HttpdnsQueryIPType, completion: @escaping (HttpdnsResult) -> Void) {
        service().getHttpDnsResultForHostAsync(host, requestIpType: ipType.toInternal()) { result in
            completion(HttpdnsResult(result))
        }
    }

    @objc(getHttpDnsResultForHostAsync:queryIPType:completion:)
    public func getHttpDnsResultForHostAsync(_ host: String, queryIPType ipType: AlicloudHttpDNS_IPType, completion: @escaping (HttpdnsResult) -> Void) {
        service().getHttpDnsResultForHostAsync(host, requestIpType: ipType.toInternal()) { result in
            completion(HttpdnsResult(result))
        }
    }

    public func getHttpDnsResultForHostSyncNonBlocking(_ host: String) -> HttpdnsResult {
        return HttpdnsResult(service().getHttpDnsResultForHostSyncNonBlocking(host, requestIpType: .v4))
    }

    public func getHttpDnsResultForHostSyncNonBlocking(_ host: String, byIPType ipType: HttpdnsQueryIPType) -> HttpdnsResult {
        return HttpdnsResult(service().getHttpDnsResultForHostSyncNonBlocking(host, requestIpType: ipType.toInternal()))
    }

    @objc(getHttpDnsResultForHostSyncNonBlocking:queryIPType:)
    public func getHttpDnsResultForHostSyncNonBlocking(_ host: String, queryIPType ipType: AlicloudHttpDNS_IPType) -> HttpdnsResult {
        return HttpdnsResult(service().getHttpDnsResultForHostSyncNonBlocking(host, requestIpType: ipType.toInternal()))
    }

    public func cleanHostCache(_ hosts: [String]?) {
        service().cleanHostCache(hosts)
    }

    private func service() -> ScloudHttpDnsService {
        return ScloudHttpDns.getService(accountId: accountID)
    }

    private func reloadConfig() {
        ScloudHttpDns.initialize(accountId: accountID, config: config)
    }
}

private extension HttpdnsQueryIPType {
    func toInternal() -> ScloudRequestIpType {
        switch self {
        case .auto:
            return .auto
        case .ipv4:
            return .v4
        case .ipv6:
            return .v6
        case .both:
            return .both
        }
    }
}

private extension AlicloudHttpDNS_IPType {
    func toInternal() -> ScloudRequestIpType {
        switch self {
        case .v4:
            return .v4
        case .v6:
            return .v6
        case .v64:
            return .both
        }
    }
}
