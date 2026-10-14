//
//  Base58Check.swift
//  ColdVault
//
//  Standard Bitcoin Base58 and Base58Check encoding and decoding.
//

import Foundation
import CryptoKit

public enum Base58Check {
    
    private static let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private static let alphabetBytes = Array(alphabet.utf8)
    private static let alphabetMap: [UInt8: Int] = {
        var map = [UInt8: Int]()
        for (index, char) in alphabetBytes.enumerated() {
            map[char] = index
        }
        return map
    }()
    
    // MARK: - Raw Base58
    public static func encode(_ data: Data) -> String {
        var zeroesCount = 0
        while zeroesCount < data.count && data[zeroesCount] == 0 {
            zeroesCount += 1
        }
        
        var bytes = Array(data[zeroesCount...])
        var encoded = [UInt8]()
        
        while !bytes.isEmpty {
            var remainder = 0
            var newBytes = [UInt8]()
            for byte in bytes {
                let temp = remainder * 256 + Int(byte)
                let div = temp / 58
                remainder = temp % 58
                if !newBytes.isEmpty || div != 0 {
                    newBytes.append(UInt8(div))
                }
            }
            bytes = newBytes
            encoded.append(alphabetBytes[remainder])
        }
        
        for _ in 0..<zeroesCount {
            encoded.append(alphabetBytes[0])
        }
        
        return String(bytes: encoded.reversed(), encoding: .utf8) ?? ""
    }
    
    public static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }
        let stringBytes = Array(string.utf8)
        
        var zeroesCount = 0
        while zeroesCount < stringBytes.count && stringBytes[zeroesCount] == alphabetBytes[0] {
            zeroesCount += 1
        }
        
        var bytes = [UInt8]()
        for char in stringBytes {
            guard let val = alphabetMap[char] else { return nil }
            var carry = val
            for i in 0..<bytes.count {
                let temp = Int(bytes[i]) * 58 + carry
                bytes[i] = UInt8(temp & 0xFF)
                carry = temp >> 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry = carry >> 8
            }
        }
        
        for _ in 0..<zeroesCount {
            bytes.append(0)
        }
        
        return Data(bytes.reversed())
    }
    
    // MARK: - Double SHA256 Checksum
    public static func doubleSHA256(_ data: Data) -> Data {
        let first = SHA256.hash(data: data)
        let second = SHA256.hash(data: Data(first))
        return Data(second)
    }
    
    // MARK: - Base58Check Encode & Decode
    public static func encodeCheck(_ data: Data) -> String {
        let checksum = doubleSHA256(data).prefix(4)
        var full = data
        full.append(checksum)
        return encode(full)
    }
    
    public static func decodeCheck(_ string: String) -> Data? {
        guard let decoded = decode(string), decoded.count >= 4 else { return nil }
        let payload = decoded.dropLast(4)
        let checksum = decoded.suffix(4)
        let expectedChecksum = doubleSHA256(payload).prefix(4)
        guard checksum == expectedChecksum else { return nil }
        return payload
    }
}
