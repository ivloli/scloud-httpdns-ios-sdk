import Foundation

enum ResponseAdapter {
    static func decryptResolvePayload(aesSecretKeyBytes: Data, rawResponseBody: String) throws -> String {
        return try decryptDataField(aesSecretKeyBytes: aesSecretKeyBytes, rawResponseBody: rawResponseBody)
    }

    static func decryptDispatchPayload(aesSecretKeyBytes: Data, rawResponseBody: String) throws -> String {
        return try decryptDataField(aesSecretKeyBytes: aesSecretKeyBytes, rawResponseBody: rawResponseBody)
    }

    static func parseDispatchPayload(_ payload: String) throws -> DispatchResult {
        guard let root = try parseJSONObject(payload),
              let list = root["list"] as? [[String: Any]],
              let first = list.first else {
            return DispatchResult(domains: [], ips: [], ttlSeconds: nil)
        }

        let domains = (first["domains"] as? [String] ?? []).filter { !$0.isEmpty }
        let ips = (first["ips"] as? [String] ?? []).filter { !$0.isEmpty }
        let ttl = first["ttl"] as? Int
        return DispatchResult(domains: domains, ips: ips, ttlSeconds: ttl)
    }

    static func parseResolvePayload(
        requestHost: String,
        requestIpType: ScloudRequestIpType,
        payload: String,
        ttlMapper: ((String, ScloudRequestIpType, Int) -> Int)?
    ) throws -> ResolveItem {
        let batch = try parseResolvePayloadBatch(requestIpType: requestIpType, payload: payload, ttlMapper: ttlMapper)
        if let matched = batch.first(where: { $0.host.caseInsensitiveCompare(requestHost) == .orderedSame }) {
            return matched
        }
        if let first = batch.first {
            return first
        }

        let ttl = max(1, ttlMapper?(requestHost, requestIpType, 60) ?? 60)
        return ResolveItem(host: requestHost, ipsV4: [], ipsV6: [], ttl: ttl, extras: [:])
    }

    static func parseResolvePayloadBatch(
        requestIpType: ScloudRequestIpType,
        payload: String,
        ttlMapper: ((String, ScloudRequestIpType, Int) -> Int)?
    ) throws -> [ResolveItem] {
        guard let root = try parseJSONObject(payload) else {
            throw ScloudError.invalidResponse
        }
        guard let answers = root["answers"] as? [[String: Any]], !answers.isEmpty else {
            return []
        }

        var items: [ResolveItem] = []
        items.reserveCapacity(answers.count)

        for answer in answers {
            let host = ((answer["dn"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap {
                $0.isEmpty ? nil : $0
            }
            guard let host else { continue }

            let v4Obj = answer["v4"] as? [String: Any]
            let v6Obj = answer["v6"] as? [String: Any]
            let rawTtl = answer["ttl"] as? Int ?? 60
            let ttl = max(1, ttlMapper?(host, requestIpType, rawTtl) ?? rawTtl)

            var extras: [String: String] = [:]
            putIfNotBlank("v4_extra", value: v4Obj?["extra"] as? String, into: &extras)
            putIfNotBlank("v4_no_ip_code", value: v4Obj?["no_ip_code"] as? String, into: &extras)
            putIfNotBlank("v6_extra", value: v6Obj?["extra"] as? String, into: &extras)
            putIfNotBlank("v6_no_ip_code", value: v6Obj?["no_ip_code"] as? String, into: &extras)
            putIfNotBlank("cip", value: root["cip"] as? String, into: &extras)
            if let latency = root["latency"] {
                extras["latency"] = String(describing: latency)
            }

            collectUnknownPrimitiveExtras(root, excludeKeys: ["answers", "cip", "latency"], prefix: "", into: &extras)
            collectUnknownPrimitiveExtras(answer, excludeKeys: ["dn", "v4", "v6", "ttl"], prefix: "answer_", into: &extras)
            collectUnknownPrimitiveExtras(v4Obj, excludeKeys: ["ips", "extra", "ttl", "no_ip_code"], prefix: "v4_", into: &extras)
            collectUnknownPrimitiveExtras(v6Obj, excludeKeys: ["ips", "extra", "ttl", "no_ip_code"], prefix: "v6_", into: &extras)

            let ipsV4 = (v4Obj?["ips"] as? [String] ?? []).filter { !$0.isEmpty }
            let ipsV6 = (v6Obj?["ips"] as? [String] ?? []).filter { !$0.isEmpty }
            items.append(ResolveItem(host: host, ipsV4: ipsV4, ipsV6: ipsV6, ttl: ttl, extras: extras))
        }

        return items
    }

    private static func decryptDataField(aesSecretKeyBytes: Data, rawResponseBody: String) throws -> String {
        guard let root = try parseJSONObject(rawResponseBody),
              let data = root["data"] as? String,
              !data.isEmpty else {
            throw ScloudError.invalidResponse
        }
        return try Crypto.decryptFromHex(aesKey: aesSecretKeyBytes, hex: data)
    }

    private static func parseJSONObject(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            throw ScloudError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func putIfNotBlank(_ key: String, value: String?, into extras: inout [String: String]) {
        guard let value, !value.isEmpty else { return }
        extras[key] = value
    }

    private static func collectUnknownPrimitiveExtras(
        _ object: [String: Any]?,
        excludeKeys: Set<String>,
        prefix: String,
        into extras: inout [String: String]
    ) {
        guard let object else { return }
        for (key, value) in object where !excludeKeys.contains(key) {
            let targetKey = prefix + key
            if extras[targetKey] != nil {
                continue
            }
            switch value {
            case let text as String where !text.isEmpty:
                extras[targetKey] = text
            case let number as NSNumber:
                extras[targetKey] = number.stringValue
            case let boolean as Bool:
                extras[targetKey] = boolean ? "true" : "false"
            default:
                continue
            }
        }
    }
}
