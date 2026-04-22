import Foundation

enum RequestAdapter {
    static func buildResolvePath(
        accountId: String,
        aesSecretKeyBytes: Data,
        host: String,
        requestIpType: ScloudRequestIpType,
        expEpochSeconds: Int64,
        clientIp: String?
    ) throws -> String {
        var plain: [String: Any] = [
            "exp": expEpochSeconds,
            "dn": host,
            "q": requestIpType.queryValue
        ]
        if let clientIp, !clientIp.isEmpty {
            plain["cip"] = clientIp
        }
        let payload = try jsonString(plain)
        let enc = try Crypto.encryptToHex(aesKey: aesSecretKeyBytes, plaintext: payload)
        return "/v1/d?id=\(url(accountId))&enc=\(url(enc))"
    }

    static func buildDispatchPath(
        accountId: String,
        aesSecretKeyBytes: Data,
        regionValue: String,
        expEpochSeconds: Int64
    ) throws -> String {
        let payload = buildDispatchProtoPlain(region: regionValue, exp: expEpochSeconds)
        let enc = try Crypto.encryptToHex(aesKey: aesSecretKeyBytes, plaintext: payload)
        return "/dnps-apis/v1/httpdns/endpoints?account_id=\(url(accountId))&enc=\(url(enc))"
    }

    private static func buildDispatchProtoPlain(region: String, exp: Int64) -> Data {
        let regionBytes = Data(region.utf8)
        return encodeLengthDelimited(fieldNumber: 1, raw: regionBytes) + encodeVarintField(fieldNumber: 3, value: UInt64(exp))
    }

    private static func encodeVarintField(fieldNumber: UInt8, value: UInt64) -> Data {
        return Data([(fieldNumber << 3) | 0]) + encodeVarint(value)
    }

    private static func encodeLengthDelimited(fieldNumber: UInt8, raw: Data) -> Data {
        return Data([(fieldNumber << 3) | 2]) + encodeVarint(UInt64(raw.count)) + raw
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var number = value
        var out = Data()
        while true {
            let byte = UInt8(number & 0x7F)
            number >>= 7
            if number != 0 {
                out.append(byte | 0x80)
            } else {
                out.append(byte)
                return out
            }
        }
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let value = String(data: data, encoding: .utf8) else {
            throw ScloudError.invalidResponse
        }
        return value
    }

    private static func url(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
