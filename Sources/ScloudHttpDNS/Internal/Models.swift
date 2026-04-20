import Foundation

enum ScloudError: Error {
    case invalidConfig(String)
    case invalidResponse
    case network(String)
}

struct DispatchResult {
    let domains: [String]
    let ips: [String]
    let ttlSeconds: Int?
}

struct ResolveItem {
    let host: String
    let ipsV4: [String]
    let ipsV6: [String]
    let ttl: Int
    let extras: [String: String]
}

struct CachedResult {
    let item: ResolveItem
    let expiredAtMillis: Int64

    func isExpired(nowMillis: Int64) -> Bool {
        return nowMillis >= expiredAtMillis
    }
}

struct ResolveEndpoint: Hashable {
    let host: String
    let connectIp: String?
}

struct BootstrapConfig {
    let domain: String
    let allIps: [String]
    let regionIps: [ScloudRegion: [String]]

    static let `default` = BootstrapConfig(
        domain: "r.pp.fgnlo.com",
        allIps: ["8.163.21.3", "8.156.93.88", "39.107.70.15", "47.103.212.241"],
        regionIps: [
            .cn: ["8.163.21.3", "39.107.70.15"],
            .os: ["8.156.93.88", "47.103.212.241"],
            .global: ["8.163.21.3", "8.156.93.88", "39.107.70.15", "47.103.212.241"],
            .default: ["8.163.21.3", "8.156.93.88", "39.107.70.15", "47.103.212.241"]
        ]
    )
}
