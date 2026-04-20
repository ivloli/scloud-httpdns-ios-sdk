import CryptoKit
import Foundation

enum Crypto {
    static func encryptToHex(aesKey: Data, plaintext: String) throws -> String {
        return try encryptToHex(aesKey: aesKey, plaintext: Data(plaintext.utf8))
    }

    static func encryptToHex(aesKey: Data, plaintext: Data) throws -> String {
        let key = SymmetricKey(data: aesKey)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw ScloudError.invalidResponse
        }
        return combined.hexString
    }

    static func decryptFromHex(aesKey: Data, hex: String) throws -> String {
        let key = SymmetricKey(data: aesKey)
        let combined = try Data(hex: hex)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: key)
        guard let output = String(data: plain, encoding: .utf8) else {
            throw ScloudError.invalidResponse
        }
        return output
    }
}

extension Data {
    init(hex: String) throws {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count % 2 == 0 else {
            throw ScloudError.invalidConfig("hex length must be even")
        }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            let bytes = value[index..<next]
            guard let num = UInt8(bytes, radix: 16) else {
                throw ScloudError.invalidConfig("invalid hex")
            }
            data.append(num)
            index = next
        }
        self = data
    }

    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
