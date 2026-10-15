//
//  UniformResource.swift
//  ColdVault
//
//  Blockchain Commons Uniform Resources (BCR-2020-005) with multi-part fountain
//  codes (BCR-2020-006) and Bytewords (BCR-2020-012): the "animated QR" format
//  Sparrow, Keystone, Passport, BlueWallet and others use for PSBTs that do not
//  fit in a single QR code (`ur:crypto-psbt/...`).
//
//  Ported from the reference implementation (github.com/BlockchainCommons/bc-ur)
//  and checked against its test vectors (see URTests).
//

import Foundation
import CryptoKit

public enum URError: LocalizedError, Equatable {
    case invalidScheme
    case invalidType
    case invalidBytewords
    case invalidChecksum
    case invalidCBOR
    case invalidSequence
    case unexpectedType(String)

    public var errorDescription: String? {
        switch self {
        case .invalidScheme: return "No es un código UR (falta 'ur:')."
        case .invalidType: return "Tipo de UR inválido."
        case .invalidBytewords: return "Código UR dañado (Bytewords inválidas)."
        case .invalidChecksum: return "Código UR dañado (checksum incorrecto)."
        case .invalidCBOR: return "Contenido UR mal formado."
        case .invalidSequence: return "Fragmento de QR animado inválido."
        case .unexpectedType(let type): return "Este QR contiene '\(type)', no un PSBT."
        }
    }
}

// MARK: - CRC-32 (IEEE 802.3, as zlib)
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

// MARK: - Bytewords (minimal style: first + last letter of each word)
enum Bytewords {
    private static let words = Array("ableacidalsoapexaquaarchatomauntawayaxisbackbaldbarnbeltbetabiasbluebodybragbrewbulbbuzzcalmcashcatschefcityclawcodecolacookcostcruxcurlcuspcyandarkdatadaysdelidicedietdoordowndrawdropdrumdulldutyeacheasyechoedgeepicevenexamexiteyesfactfairfernfigsfilmfishfizzflapflewfluxfoxyfreefrogfuelfundgalagamegeargemsgiftgirlglowgoodgraygrimgurugushgyrohalfhanghardhawkheathelphighhillholyhopehornhutsicedideaidleinchinkyintoirisironitemjadejazzjoinjoltjowljudojugsjumpjunkjurykeepkenokeptkeyskickkilnkingkitekiwiknoblamblavalazyleaflegsliarlimplionlistlogoloudloveluaulucklungmainmanymathmazememomenumeowmildmintmissmonknailnavyneednewsnextnoonnotenumbobeyoboeomitonyxopenovalowlspaidpartpeckplaypluspoempoolposepuffpumapurrquadquizraceramprealredorichroadrockroofrubyruinrunsrustsafesagascarsetssilkskewslotsoapsolosongstubsurfswantacotasktaxitenttiedtimetinytoiltombtoystriptunatwinuglyundouniturgeuservastveryvetovialvibeviewvisavoidvowswallwandwarmwaspwavewaxywebswhatwhenwhizwolfworkyankyawnyellyogayurtzapszerozestzinczonezoom".utf8)

    /// (first letter, last letter) → byte value; -1 for unused pairs.
    private static let minimalLookup: [Int16] = {
        var table = [Int16](repeating: -1, count: 26 * 26)
        for i in 0..<256 {
            let x = Int(words[i * 4]) - 97
            let y = Int(words[i * 4 + 3]) - 97
            table[y * 26 + x] = Int16(i)
        }
        return table
    }()

    static func encodeMinimal(_ bytes: [UInt8]) -> String {
        let withCRC = bytes + CRC32.bigEndianBytes(CRC32.checksum(bytes))
        var out = [UInt8]()
        out.reserveCapacity(withCRC.count * 2)
        for b in withCRC {
            out.append(words[Int(b) * 4])
            out.append(words[Int(b) * 4 + 3])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decodeMinimal(_ text: String) throws -> [UInt8] {
        let chars = Array(text.lowercased().utf8)
        guard chars.count % 2 == 0 else { throw URError.invalidBytewords }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            let x = Int(chars[i]) - 97
            let y = Int(chars[i + 1]) - 97
            guard (0..<26).contains(x), (0..<26).contains(y) else { throw URError.invalidBytewords }
            let value = minimalLookup[y * 26 + x]
            guard value >= 0 else { throw URError.invalidBytewords }
            bytes.append(UInt8(value))
            i += 2
        }
        guard bytes.count >= 5 else { throw URError.invalidBytewords }
        let body = Array(bytes[0..<(bytes.count - 4)])
        guard Array(bytes[(bytes.count - 4)...]) == CRC32.bigEndianBytes(CRC32.checksum(body)) else {
            throw URError.invalidChecksum
        }
        return body
    }
}

// MARK: - Xoshiro256** PRNG (seeded with SHA-256), random sampler, shuffle
struct Xoshiro256 {
    private var s: [UInt64]

    init(seed: [UInt8]) {
        let digest = [UInt8](SHA256.hash(data: Data(seed)))
        s = (0..<4).map { i in
            var v: UInt64 = 0
            for n in 0..<8 { v = v << 8 | UInt64(digest[i * 8 + n]) }
            return v
        }
    }

    init(string: String) { self.init(seed: Array(string.utf8)) }

    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }

    mutating func next() -> UInt64 {
        let result = Xoshiro256.rotl(s[1] &* 5, 7) &* 9
        let t = s[1] << 17
        s[2] ^= s[0]
        s[3] ^= s[1]
        s[1] ^= s[2]
        s[0] ^= s[3]
        s[2] ^= t
        s[3] = Xoshiro256.rotl(s[3], 45)
        return result
    }

    mutating func nextDouble() -> Double {
        return Double(next()) / 18_446_744_073_709_551_616.0   // 2^64
    }

    mutating func nextInt(_ low: UInt64, _ high: UInt64) -> UInt64 {
        return UInt64(nextDouble() * Double(high - low + 1)) + low
    }

    mutating func nextData(_ count: Int) -> [UInt8] {
        return (0..<count).map { _ in UInt8(nextInt(0, 255)) }
    }
}

/// Walker/Vose alias sampler, matching the reference index ordering exactly.
struct RandomSampler {
    private let probs: [Double]
    private let aliases: [Int]

    init(_ weights: [Double]) {
        let n = weights.count
        let sum = weights.reduce(0, +)
        var p = weights.map { $0 * Double(n) / sum }
        var small = [Int]()
        var large = [Int]()
        for i in stride(from: n - 1, through: 0, by: -1) {
            if p[i] < 1 { small.append(i) } else { large.append(i) }
        }
        var probs = [Double](repeating: 0, count: n)
        var aliases = [Int](repeating: 0, count: n)
        while let a = small.last, let g = large.last {
            small.removeLast()
            large.removeLast()
            probs[a] = p[a]
            aliases[a] = g
            p[g] += p[a] - 1
            if p[g] < 1 { small.append(g) } else { large.append(g) }
        }
        while let g = large.popLast() { probs[g] = 1 }
        while let a = small.popLast() { probs[a] = 1 }
        self.probs = probs
        self.aliases = aliases
    }

    func next(_ rng: inout Xoshiro256) -> Int {
        let r1 = rng.nextDouble()
        let r2 = rng.nextDouble()
        let i = Int(Double(probs.count) * r1)
        return r2 < probs[i] ? i : aliases[i]
    }
}

enum Fountain {
    static func shuffled<T>(_ items: [T], _ rng: inout Xoshiro256) -> [T] {
        var remaining = items
        var result = [T]()
        result.reserveCapacity(items.count)
        while !remaining.isEmpty {
            let index = Int(rng.nextInt(0, UInt64(remaining.count - 1)))
            result.append(remaining.remove(at: index))
        }
        return result
    }

    static func chooseDegree(_ seqLen: Int, _ rng: inout Xoshiro256) -> Int {
        let sampler = RandomSampler((1...seqLen).map { 1.0 / Double($0) })
        return sampler.next(&rng) + 1
    }

    /// Fragment indexes mixed into part `seqNum`. The first `seqLen` parts are the
    /// plain fragments; later ones are pseudo-random XOR combinations.
    static func chooseFragments(seqNum: UInt32, seqLen: Int, checksum: UInt32) -> Set<Int> {
        if seqNum <= UInt32(seqLen) { return [Int(seqNum) - 1] }
        var rng = Xoshiro256(seed: CRC32.bigEndianBytes(seqNum) + CRC32.bigEndianBytes(checksum))
        let degree = chooseDegree(seqLen, &rng)
        return Set(shuffled(Array(0..<seqLen), &rng).prefix(degree))
    }

    static func nominalFragmentLength(messageLength: Int, minFragmentLength: Int, maxFragmentLength: Int) -> Int {
        let maxCount = max(1, messageLength / minFragmentLength)
        var length = messageLength
        for count in 1...maxCount {
            length = (messageLength + count - 1) / count
            if length <= maxFragmentLength { break }
        }
        return length
    }

    static func partition(_ message: [UInt8], fragmentLength: Int) -> [[UInt8]] {
        var fragments = [[UInt8]]()
        var start = 0
        while start < message.count {
            var fragment = Array(message[start..<min(start + fragmentLength, message.count)])
            fragment += [UInt8](repeating: 0, count: fragmentLength - fragment.count)
            fragments.append(fragment)
            start += fragmentLength
        }
        return fragments
    }

    static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        return zip(a, b).map { $0 ^ $1 }
    }
}

// MARK: - Minimal CBOR (only what UR needs)
enum CBOR {
    static func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
        let m = major << 5
        switch value {
        case 0..<24: return [m | UInt8(value)]
        case 24..<256: return [m | 24, UInt8(value)]
        case 256..<65_536: return [m | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
        case 65_536..<4_294_967_296: return [m | 26] + CRC32.bigEndianBytes(UInt32(value))
        default: return [m | 27] + (0..<8).map { UInt8(value >> (56 - 8 * UInt64($0)) & 0xFF) }
        }
    }

    static func bytes(_ data: [UInt8]) -> [UInt8] { head(2, UInt64(data.count)) + data }

    struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { position == bytes.count }

        mutating func readHead() throws -> (major: UInt8, value: UInt64) {
            guard position < bytes.count else { throw URError.invalidCBOR }
            let initial = bytes[position]
            position += 1
            let major = initial >> 5
            let info = initial & 0x1F
            let length: Int
            switch info {
            case 0..<24: return (major, UInt64(info))
            case 24: length = 1
            case 25: length = 2
            case 26: length = 4
            case 27: length = 8
            default: throw URError.invalidCBOR   // indefinite lengths are not used by UR
            }
            guard position + length <= bytes.count else { throw URError.invalidCBOR }
            var value: UInt64 = 0
            for _ in 0..<length {
                value = value << 8 | UInt64(bytes[position])
                position += 1
            }
            return (major, value)
        }

        mutating func readUnsigned() throws -> UInt64 {
            let (major, value) = try readHead()
            guard major == 0 else { throw URError.invalidCBOR }
            return value
        }

        mutating func readBytes() throws -> [UInt8] {
            let (major, value) = try readHead()
            guard major == 2, value <= UInt64(bytes.count - position) else { throw URError.invalidCBOR }
            let result = Array(bytes[position..<(position + Int(value))])
            position += Int(value)
            return result
        }
    }
}

// MARK: - Fountain parts, encoder and decoder
struct FountainPart: Equatable {
    let seqNum: UInt32
    let seqLen: Int
    let messageLen: Int
    let checksum: UInt32
    let data: [UInt8]

    var cbor: [UInt8] {
        CBOR.head(4, 5) + CBOR.head(0, UInt64(seqNum)) + CBOR.head(0, UInt64(seqLen)) +
            CBOR.head(0, UInt64(messageLen)) + CBOR.head(0, UInt64(checksum)) + CBOR.bytes(data)
    }

    init(seqNum: UInt32, seqLen: Int, messageLen: Int, checksum: UInt32, data: [UInt8]) {
        self.seqNum = seqNum
        self.seqLen = seqLen
        self.messageLen = messageLen
        self.checksum = checksum
        self.data = data
    }

    init(cbor: [UInt8]) throws {
        var reader = CBOR.Reader(cbor)
        let (major, count) = try reader.readHead()
        guard major == 4, count == 5 else { throw URError.invalidCBOR }
        let seqNum = try reader.readUnsigned()
        let seqLen = try reader.readUnsigned()
        let messageLen = try reader.readUnsigned()
        let checksum = try reader.readUnsigned()
        let data = try reader.readBytes()
        guard reader.isAtEnd, seqNum <= UInt32.max, seqNum >= 1, checksum <= UInt32.max,
              seqLen >= 1, seqLen <= 100_000, messageLen >= 1, messageLen <= 10_000_000, !data.isEmpty,
              UInt64(data.count) * seqLen >= messageLen else { throw URError.invalidCBOR }
        self.init(seqNum: UInt32(seqNum), seqLen: Int(seqLen), messageLen: Int(messageLen),
                  checksum: UInt32(checksum), data: data)
    }
}

struct FountainEncoder {
    let messageLen: Int
    let checksum: UInt32
    let fragmentLen: Int
    let fragments: [[UInt8]]
    private(set) var seqNum: UInt32

    init(message: [UInt8], maxFragmentLen: Int, firstSeqNum: UInt32 = 0, minFragmentLen: Int = 10) {
        messageLen = message.count
        checksum = CRC32.checksum(message)
        fragmentLen = Fountain.nominalFragmentLength(messageLength: message.count,
                                                     minFragmentLength: minFragmentLen,
                                                     maxFragmentLength: maxFragmentLen)
        fragments = Fountain.partition(message, fragmentLength: fragmentLen)
        seqNum = firstSeqNum
    }

    var seqLen: Int { fragments.count }

    mutating func nextPart() -> FountainPart {
        seqNum &+= 1
        let indexes = Fountain.chooseFragments(seqNum: seqNum, seqLen: seqLen, checksum: checksum)
        var mixed = [UInt8](repeating: 0, count: fragmentLen)
        for index in indexes { mixed = Fountain.xor(mixed, fragments[index]) }
        return FountainPart(seqNum: seqNum, seqLen: seqLen, messageLen: messageLen, checksum: checksum, data: mixed)
    }
}

struct FountainDecoder {
    private struct Part {
        var indexes: Set<Int>
        var data: [UInt8]
        var isSimple: Bool { indexes.count == 1 }
    }

    private var expectedIndexes: Set<Int>?
    private var expectedMessageLen = 0
    private var expectedChecksum: UInt32 = 0
    private var expectedFragmentLen = 0
    private var received = Set<Int>()
    private var simpleParts = [Int: [UInt8]]()
    private var mixedParts = [Set<Int>: Part]()
    private var queue = [Part]()
    private(set) var processedCount = 0
    private(set) var result: Result<[UInt8], URError>?

    var expectedPartCount: Int? { expectedIndexes?.count }
    var receivedCount: Int { received.count }

    var progress: Double {
        guard result == nil else { return 1 }
        guard let expected = expectedIndexes?.count, expected > 0 else { return 0 }
        return min(0.99, Double(received.count) / Double(expected))
    }

    mutating func receive(_ part: FountainPart) -> Bool {
        guard result == nil else { return false }
        if let _ = expectedIndexes {
            guard part.seqLen == expectedIndexes?.count, part.messageLen == expectedMessageLen,
                  part.checksum == expectedChecksum, part.data.count == expectedFragmentLen else { return false }
        } else {
            expectedIndexes = Set(0..<part.seqLen)
            expectedMessageLen = part.messageLen
            expectedChecksum = part.checksum
            expectedFragmentLen = part.data.count
        }
        let indexes = Fountain.chooseFragments(seqNum: part.seqNum, seqLen: part.seqLen, checksum: part.checksum)
        queue.append(Part(indexes: indexes, data: part.data))
        while result == nil, !queue.isEmpty {
            let next = queue.removeFirst()
            if next.isSimple { processSimple(next) } else { processMixed(next) }
        }
        processedCount += 1
        return true
    }

    private func reduce(_ a: Part, by b: Part) -> Part {
        guard b.indexes.isStrictSubset(of: a.indexes) else { return a }
        return Part(indexes: a.indexes.subtracting(b.indexes), data: Fountain.xor(a.data, b.data))
    }

    private mutating func reduceMixed(by part: Part) {
        var remaining = [Set<Int>: Part]()
        for (_, mixed) in mixedParts {
            let reduced = reduce(mixed, by: part)
            if reduced.isSimple { queue.append(reduced) } else { remaining[reduced.indexes] = reduced }
        }
        mixedParts = remaining
    }

    private mutating func processSimple(_ part: Part) {
        guard let index = part.indexes.first, !received.contains(index) else { return }
        simpleParts[index] = part.data
        received.insert(index)
        if received == expectedIndexes {
            var message = [UInt8]()
            for i in 0..<received.count { message += simpleParts[i] ?? [] }
            message = Array(message.prefix(expectedMessageLen))
            result = CRC32.checksum(message) == expectedChecksum ? .success(message) : .failure(.invalidChecksum)
        } else {
            reduceMixed(by: part)
        }
    }

    private mutating func processMixed(_ part: Part) {
        guard mixedParts[part.indexes] == nil else { return }
        var reduced = part
        for (index, data) in simpleParts { reduced = reduce(reduced, by: Part(indexes: [index], data: data)) }
        for (_, mixed) in mixedParts { reduced = reduce(reduced, by: mixed) }
        if reduced.isSimple {
            queue.append(reduced)
        } else {
            reduceMixed(by: reduced)
            mixedParts[reduced.indexes] = reduced
        }
    }
}

// MARK: - UR encoder / decoder
public struct UniformResource: Equatable {
    public let type: String
    public let cbor: [UInt8]

    static func isValidType(_ type: String) -> Bool {
        !type.isEmpty && type.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    /// Single-part UR string, e.g. `ur:crypto-psbt/...`.
    public var singlePartString: String { "ur:\(type)/\(Bytewords.encodeMinimal(cbor))" }
}

/// Produces an endless stream of QR frames: first the plain fragments, then fountain
/// parts, so a scanner that missed frames still completes quickly.
public struct UREncoder {
    public let resource: UniformResource
    private var fountain: FountainEncoder

    public init(_ resource: UniformResource, maxFragmentLen: Int, firstSeqNum: UInt32 = 0, minFragmentLen: Int = 10) {
        self.resource = resource
        self.fountain = FountainEncoder(message: resource.cbor, maxFragmentLen: maxFragmentLen,
                                        firstSeqNum: firstSeqNum, minFragmentLen: minFragmentLen)
    }

    public var isSinglePart: Bool { fountain.seqLen == 1 }
    public var partCount: Int { fountain.seqLen }

    public mutating func nextPart() -> String {
        let part = fountain.nextPart()
        if isSinglePart { return resource.singlePartString }
        return "ur:\(resource.type)/\(part.seqNum)-\(part.seqLen)/\(Bytewords.encodeMinimal(part.cbor))"
    }
}

public struct URDecoder {
    private var expectedType: String?
    private var fountain = FountainDecoder()
    public private(set) var result: Result<UniformResource, URError>?

    public init() {}

    public var progress: Double { result != nil ? 1 : fountain.progress }
    public var expectedPartCount: Int? { fountain.expectedPartCount }
    public var receivedPartCount: Int { fountain.receivedCount }

    /// Decodes a complete single-part UR.
    public static func decode(_ text: String) throws -> UniformResource {
        let (type, components) = try parse(text)
        guard components.count == 1 else { throw URError.invalidSequence }
        return UniformResource(type: type, cbor: try Bytewords.decodeMinimal(components[0]))
    }

    static func parse(_ text: String) throws -> (String, [String]) {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.hasPrefix("ur:") else { throw URError.invalidScheme }
        let components = lowered.dropFirst(3).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2 else { throw URError.invalidSequence }
        guard UniformResource.isValidType(components[0]) else { throw URError.invalidType }
        return (components[0], Array(components.dropFirst()))
    }

    /// Feeds one scanned QR. Returns true when the part was accepted.
    @discardableResult
    public mutating func receivePart(_ text: String) -> Bool {
        guard result == nil, let parsed = try? URDecoder.parse(text) else { return false }
        let (type, components) = parsed
        if let expected = expectedType {
            guard type == expected else { return false }
        }
        if components.count == 1 {
            guard let cbor = try? Bytewords.decodeMinimal(components[0]) else { return false }
            expectedType = type
            result = .success(UniformResource(type: type, cbor: cbor))
            return true
        }
        guard components.count == 2 else { return false }
        let sequence = components[0].split(separator: "-")
        guard sequence.count == 2, let seqNum = UInt32(sequence[0]), let seqLen = Int(sequence[1]),
              seqNum >= 1, seqLen >= 1,
              let cbor = try? Bytewords.decodeMinimal(components[1]),
              let part = try? FountainPart(cbor: cbor),
              part.seqNum == seqNum, part.seqLen == seqLen else { return false }
        expectedType = type
        guard fountain.receive(part) else { return false }
        switch fountain.result {
        case .success(let message): result = .success(UniformResource(type: type, cbor: message))
        case .failure(let error): result = .failure(error)
        case nil: break
        }
        return true
    }
}

// MARK: - PSBTs as UR (`crypto-psbt`, BCR-2020-006 registry; `psbt` in newer wallets)
public enum URPSBT {
    public static let type = "crypto-psbt"

    public static func resource(for psbt: Data) -> UniformResource {
        UniformResource(type: type, cbor: CBOR.bytes([UInt8](psbt)))
    }

    /// Raw PSBT bytes from a decoded UR (`crypto-psbt`, `psbt` or `bytes`).
    public static func psbtData(from resource: UniformResource) throws -> Data {
        guard ["crypto-psbt", "psbt", "bytes"].contains(resource.type) else {
            throw URError.unexpectedType(resource.type)
        }
        var reader = CBOR.Reader(resource.cbor)
        let bytes = try reader.readBytes()
        guard reader.isAtEnd else { throw URError.invalidCBOR }
        return Data(bytes)
    }

    public static func isUR(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ur:")
    }
}
