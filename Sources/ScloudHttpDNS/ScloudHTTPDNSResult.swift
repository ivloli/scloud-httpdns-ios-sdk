import Foundation

final class ScloudHTTPDNSResult {
    let host: String
    let ips: [String]
    let ipv6s: [String]
    let extras: [String: String]
    let ttl: Int
    let expired: Bool

    init(
        host: String,
        ips: [String],
        ipv6s: [String],
        extras: [String: String],
        ttl: Int,
        expired: Bool
    ) {
        self.host = host
        self.ips = ips
        self.ipv6s = ipv6s
        self.extras = extras
        self.ttl = ttl
        self.expired = expired
    }
}
