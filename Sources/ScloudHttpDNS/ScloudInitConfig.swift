import Foundation

protocol ScloudCacheTtlChanger: AnyObject {
    func changeCacheTtl(host: String, requestIpType: ScloudRequestIpType, ttl: Int) -> Int
}

protocol ScloudNotUseHttpDnsFilter: AnyObject {
    func notUseHttpDns(host: String) -> Bool
}

protocol ScloudLogger: AnyObject {
    func log(_ message: String)
}

struct ScloudInitConfig {
    var aesSecretKey: String
    var region: ScloudRegion
    var enableCacheIp: Bool
    var cacheExpiredThresholdMillis: Int64
    var enableExpiredIp: Bool
    var timeoutMillis: Int
    var enableHttps: Bool
    var resolveHostOverride: String?
    var resolveConnectIpOverride: String?
    var resolvePortOverride: Int?
    weak var cacheTtlChanger: ScloudCacheTtlChanger?
    weak var notUseHttpDnsFilter: ScloudNotUseHttpDnsFilter?
    weak var logger: ScloudLogger?

    init(
        aesSecretKey: String,
        region: ScloudRegion = .default,
        enableCacheIp: Bool = true,
        cacheExpiredThresholdMillis: Int64 = 24 * 60 * 60 * 1000,
        enableExpiredIp: Bool = true,
        timeoutMillis: Int = 2000,
        enableHttps: Bool = true,
        resolveHostOverride: String? = nil,
        resolveConnectIpOverride: String? = nil,
        resolvePortOverride: Int? = nil,
        cacheTtlChanger: ScloudCacheTtlChanger? = nil,
        notUseHttpDnsFilter: ScloudNotUseHttpDnsFilter? = nil,
        logger: ScloudLogger? = nil
    ) {
        let normalizedHostOverride = resolveHostOverride?.trimmedNilIfEmpty
        let normalizedConnectIpOverride = resolveConnectIpOverride?.trimmedNilIfEmpty
        if normalizedConnectIpOverride != nil {
            precondition(normalizedHostOverride != nil, "resolveHostOverride is required when resolveConnectIpOverride is set")
        }
        if let resolvePortOverride {
            precondition((1...65535).contains(resolvePortOverride), "resolvePortOverride must be between 1 and 65535")
        }

        self.aesSecretKey = aesSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.enableCacheIp = enableCacheIp
        self.cacheExpiredThresholdMillis = cacheExpiredThresholdMillis
        self.enableExpiredIp = enableExpiredIp
        self.timeoutMillis = max(100, min(timeoutMillis, 5000))
        self.enableHttps = enableHttps
        self.resolveHostOverride = normalizedHostOverride
        self.resolveConnectIpOverride = normalizedConnectIpOverride
        self.resolvePortOverride = resolvePortOverride
        self.cacheTtlChanger = cacheTtlChanger
        self.notUseHttpDnsFilter = notUseHttpDnsFilter
        self.logger = logger
    }

    func aesSecretKeyBytesForDispatch() throws -> Data {
        let raw = aesSecretKey
        if let plain = raw.data(using: .utf8), [16, 24, 32].contains(plain.count) {
            return plain
        }
        if raw.range(of: "^[0-9a-fA-F]{32}$|^[0-9a-fA-F]{48}$|^[0-9a-fA-F]{64}$", options: .regularExpression) != nil {
            return try Data(hex: raw)
        }
        throw ScloudError.invalidConfig("aesSecretKey must be utf8 length in [16,24,32] or hex length in [32,48,64]")
    }

    func aesSecretKeyBytesForResolve() throws -> Data {
        let raw = aesSecretKey
        if raw.range(of: "^[0-9a-fA-F]{32}$|^[0-9a-fA-F]{48}$|^[0-9a-fA-F]{64}$", options: .regularExpression) != nil {
            return try Data(hex: raw)
        }
        if let plain = raw.data(using: .utf8), [16, 24, 32].contains(plain.count) {
            return plain
        }
        throw ScloudError.invalidConfig("aesSecretKey must be utf8 length in [16,24,32] or hex length in [32,48,64]")
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
