//
//  Bech32.swift
//  ColdVault
//
//  BIP-173 (Bech32) and BIP-350 (Bech32m) implementation in pure Swift.
//  Used for Bitcoin Native SegWit (P2WPKH: bc1q...) and Taproot (P2TR: bc1p...).
//

import Foundation

public enum Bech32 {
    
    public enum EncodingType {
        case bech32
        case bech32m
        
        var checksumConstant: UInt32 {
            switch self {
            case .bech32:  return 1
            case .bech32m: return 0x2bc830a3
            }
        }
    }
    
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private static let charsetBytes = Array(charset.utf8)
    private static let charsetMap: [UInt8: UInt8] = {
        var map = [UInt8: UInt8]()
        for (i, c) in charsetBytes.enumerated() {
            map[c] = UInt8(i)
        }
        return map
    }()
    
    private static let generator: [UInt32] = [
        0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3
    ]
    
    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for val in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(val)
            for i in 0..<5 {
                if ((b >> i) & 1) == 1 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }
    
    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var ret = [UInt8]()
        for c in hrp.utf8 {
            ret.append(c >> 5)
        }
        ret.append(0)
        for c in hrp.utf8 {
            ret.append(c & 31)
        }
        return ret
    }
    
    public static func encode(hrp: String, values: [UInt8], type: EncodingType = .bech32) -> String {
        var combined = hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]
        let pm = polymod(combined) ^ type.checksumConstant
        var checksum = [UInt8]()
        for i in 0..<6 {
            checksum.append(UInt8((pm >> (5 * (5 - i))) & 31))
        }
        
        var result = hrp.lowercased() + "1"
        for v in values + checksum {
            result.append(Character(UnicodeScalar(charsetBytes[Int(v)])))
        }
        return result
    }
    
    public static func decode(_ str: String) -> (hrp: String, data: [UInt8], type: EncodingType)? {
        guard str.count >= 8 && str.count <= 90 else { return nil }
        
        let lower = str.lowercased()
        let upper = str.uppercased()
        guard str == lower || str == upper else { return nil } // Reject mixed case
        
        let s = lower
        guard let pos = s.lastIndex(of: "1") else { return nil }
        let hrp = String(s[..<pos])
        guard hrp.count >= 1 else { return nil }
        
        let dataPart = s[s.index(after: pos)...]
        guard dataPart.count >= 6 else { return nil }
        
        var values = [UInt8]()
        for c in dataPart.utf8 {
            guard let val = charsetMap[c] else { return nil }
            values.append(val)
        }
        
        let expanded = hrpExpand(hrp) + values
        let pm = polymod(expanded)
        
        let type: EncodingType
        if pm == EncodingType.bech32.checksumConstant {
            type = .bech32
        } else if pm == EncodingType.bech32m.checksumConstant {
            type = .bech32m
        } else {
            return nil
        }
        
        let data = Array(values.dropLast(6))
        return (hrp, data, type)
    }
    
    // MARK: - Convert bit widths (e.g. 8-bit bytes to 5-bit words)
    public static func convertBits(from: Int, to: Int, pad: Bool, data: Data) -> [UInt8]? {
        var acc: Int = 0
        var bits: Int = 0
        var ret = [UInt8]()
        let maxv = (1 << to) - 1
        let maxAcc = (1 << (from + to - 1)) - 1
        
        for val in data {
            acc = ((acc << from) | Int(val)) & maxAcc
            bits += from
            while bits >= to {
                bits -= to
                ret.append(UInt8((acc >> bits) & maxv))
            }
        }
        
        if pad {
            if bits > 0 {
                ret.append(UInt8((acc << (to - bits)) & maxv))
            }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        
        return ret
    }
    
    public static func convertBitsFrom5to8(data: [UInt8]) -> Data? {
        var acc: Int = 0
        var bits: Int = 0
        var ret = [UInt8]()
        let maxv = 255
        
        for val in data {
            if val >> 5 != 0 { return nil }
            acc = (acc << 5) | Int(val)
            bits += 5
            while bits >= 8 {
                bits -= 8
                ret.append(UInt8((acc >> bits) & maxv))
            }
        }
        
        if bits >= 5 || ((acc << (8 - bits)) & maxv) != 0 {
            return nil
        }
        
        return Data(ret)
    }
}
