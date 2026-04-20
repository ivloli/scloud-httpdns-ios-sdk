import Foundation

final class CacheStore {
    private var map: [String: CachedResult] = [:]
    private let lock = NSLock()

    func get(host: String, type: ScloudRequestIpType) -> CachedResult? {
        lock.lock()
        defer { lock.unlock() }
        return map[key(host: host, type: type)]
    }

    func put(host: String, type: ScloudRequestIpType, item: ResolveItem, nowMillis: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let ttlMillis = Int64(max(1, item.ttl) * 1000)
        map[key(host: host, type: type)] = CachedResult(item: item, expiredAtMillis: nowMillis + ttlMillis)
    }

    func clearHosts(_ hosts: [String]) {
        guard !hosts.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let hostSet = Set(hosts)
        map.keys.filter { key in
            hostSet.contains { key.hasPrefix($0 + ":") }
        }.forEach { map.removeValue(forKey: $0) }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
    }

    private func key(host: String, type: ScloudRequestIpType) -> String {
        return "\(host):\(type.rawValue)"
    }
}
