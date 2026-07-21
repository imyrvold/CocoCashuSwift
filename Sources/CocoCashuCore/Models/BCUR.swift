import Foundation
import CryptoKit

// BC-UR (Uniform Resources) decoding — BCR-2020-005 / BCR-2024-001 (MUR).
//
// Cashu wallets (cashu.me/Cashu app) display large tokens as ANIMATED QR codes:
// a stream of `ur:bytes/<seqNum>-<seqLen>/<bytewords>` frames, fountain-coded so
// the scanner can start mid-stream and still reassemble. One frame alone is NOT
// a token — which is why a pasted single frame can never be claimed.
//
// Ported faithfully from the reference implementation (BlockchainCommons URKit,
// BSD-2-Clause-Patent, © 2020 Blockchain Commons LLC): the Xoshiro256** RNG,
// Walker-Vose alias sampler, fragment chooser, and bytewords table must match
// bit-for-bit or mixed parts reassemble into garbage. Pinned by test vectors:
// Xoshiro("Wolf") stream, crc32("Wolf"), the MUR part-CBOR vector, the
// BCR-2020-012 bytewords vector, and a real Cashu-app frame.

public enum BCURError: Error, LocalizedError {
    case notAUR
    case invalidBytewords
    case invalidChecksum
    case invalidPart
    case inconsistentPart
    case unsupportedType(String)
    case singleFrameOfMultipart(seqNum: Int, seqLen: Int)

    public var errorDescription: String? {
        switch self {
        case .notAUR: return "Not a UR string."
        case .invalidBytewords: return "Invalid UR encoding."
        case .invalidChecksum: return "UR checksum mismatch."
        case .invalidPart: return "Malformed UR part."
        case .inconsistentPart: return "UR part belongs to a different message."
        case .unsupportedType(let t): return "Unsupported UR type '\(t)'."
        case .singleFrameOfMultipart(let n, let len):
            return "This is frame \(n) of a \(len)-part animated QR — one frame alone can't be decoded. Use Scan QR and hold the camera on the animation instead."
        }
    }
}

// MARK: - CRC-32 (IEEE, reflected 0xEDB88320)

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}

@inline(__always) private func bigEndianBytes(_ v: UInt32) -> Data {
    withUnsafeBytes(of: v.bigEndian) { Data($0) }
}

// MARK: - Bytewords (minimal style) — BCR-2020-012

enum Bytewords {
    // 256 four-letter words, concatenated. Verbatim from the reference.
    private static let wordString =
        "ableacidalsoapexaquaarchatomauntawayaxisbackbaldbarnbeltbetabias" +
        "bluebodybragbrewbulbbuzzcalmcashcatschefcityclawcodecolacookcost" +
        "cruxcurlcuspcyandarkdatadaysdelidicedietdoordowndrawdropdrumdull" +
        "dutyeacheasyechoedgeepicevenexamexiteyesfactfairfernfigsfilmfish" +
        "fizzflapflewfluxfoxyfreefrogfuelfundgalagamegeargemsgiftgirlglow" +
        "goodgraygrimgurugushgyrohalfhanghardhawkheathelphighhillholyhope" +
        "hornhutsicedideaidleinchinkyintoirisironitemjadejazzjoinjoltjowl" +
        "judojugsjumpjunkjurykeepkenokeptkeyskickkilnkingkitekiwiknoblamb" +
        "lavalazyleaflegsliarlimplionlistlogoloudloveluaulucklungmainmany" +
        "mathmazememomenumeowmildmintmissmonknailnavyneednewsnextnoonnote" +
        "numbobeyoboeomitonyxopenovalowlspaidpartpeckplaypluspoempoolpose" +
        "puffpumapurrquadquizraceramprealredorichroadrockroofrubyruinruns" +
        "rustsafesagascarsetssilkskewslotsoapsolosongstubsurfswantacotask" +
        "taxitenttiedtimetinytoiltombtoystriptunatwinuglyundouniturgeuser" +
        "vastveryvetovialvibeviewvisavoidvowswallwandwarmwaspwavewaxywebs" +
        "whatwhenwhizwolfworkyankyawnyellyogayurtzapszerozestzinczonezoom"

    /// byte value -> two-letter minimal word (first + last letter of the word).
    static let minimalForByte: [String] = {
        let chars = Array(wordString)
        return (0..<256).map { i in
            String([chars[i * 4], chars[i * 4 + 3]])
        }
    }()

    static let byteForMinimal: [String: UInt8] = {
        var map: [String: UInt8] = [:]
        for (i, pair) in minimalForByte.enumerated() { map[pair] = UInt8(i) }
        return map
    }()

    /// Decode minimal bytewords, verifying and stripping the trailing 4-byte CRC-32.
    static func decodeMinimal(_ string: String) throws -> Data {
        let chars = Array(string)
        guard chars.count % 2 == 0, chars.count >= 10 else { throw BCURError.invalidBytewords }
        var bytes = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            let pair = String([chars[i], chars[i + 1]])
            guard let value = byteForMinimal[pair] else { throw BCURError.invalidBytewords }
            bytes.append(value)
            i += 2
        }
        let body = bytes.prefix(bytes.count - 4)
        let expected = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard CRC32.checksum(Data(body)) == expected else { throw BCURError.invalidChecksum }
        return Data(body)
    }

    /// Encode minimal bytewords, appending the 4-byte CRC-32.
    static func encodeMinimal(_ data: Data) -> String {
        let full = data + bigEndianBytes(CRC32.checksum(data))
        return full.map { minimalForByte[Int($0)] }.joined()
    }
}

// MARK: - Xoshiro256** (reference port; MUST match URKit output exactly)

final class Xoshiro256 {
    private var state: [UInt64]

    init(seed: Data) {
        let digest = SHA256.hash(data: seed)
        var s = [UInt64](repeating: 0, count: 4)
        let bytes = Array(digest)
        for i in 0..<4 {
            var v: UInt64 = 0
            for n in 0..<8 {
                v = (v << 8) | UInt64(bytes[i * 8 + n])
            }
            s[i] = v
        }
        self.state = s
    }

    convenience init(string: String) { self.init(seed: Data(string.utf8)) }

    func next() -> UInt64 {
        func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }
        let result = rotl(state[1] &* 5, 7) &* 9
        let t = state[1] << 17
        state[2] ^= state[0]
        state[3] ^= state[1]
        state[1] ^= state[2]
        state[0] ^= state[3]
        state[2] ^= t
        state[3] = rotl(state[3], 45)
        return result
    }

    func nextDouble() -> Double { Double(next()) / (Double(UInt64.max) + 1) }

    func nextInt(in range: Range<Int>) -> Int {
        Int(nextDouble() * Double(range.count)) + range.lowerBound
    }

    func nextByte() -> UInt8 { UInt8(nextInt(in: 0..<256)) }
    func nextData(count: Int) -> Data { Data((0..<count).map { _ in nextByte() }) }
}

// MARK: - Walker-Vose alias sampler (reference port)

final class RandomSampler {
    private let probs: [Double]
    private let aliases: [Int]

    init(_ inputProbs: [Double]) {
        let sum = inputProbs.reduce(0, +)
        let n = inputProbs.count
        var P = inputProbs.map { $0 * Double(n) / sum }

        var S: [Int] = []
        var L: [Int] = []
        for i in (0...(n - 1)).reversed() {
            if P[i] < 1 { S.append(i) } else { L.append(i) }
        }

        var probs = [Double](repeating: 0, count: n)
        var aliases = [Int](repeating: 0, count: n)
        while !S.isEmpty && !L.isEmpty {
            let a = S.removeLast()
            let g = L.removeLast()
            probs[a] = P[a]
            aliases[a] = g
            P[g] += P[a] - 1
            if P[g] < 1 { S.append(g) } else { L.append(g) }
        }
        while !L.isEmpty { probs[L.removeLast()] = 1 }
        while !S.isEmpty { probs[S.removeLast()] = 1 }

        self.probs = probs
        self.aliases = aliases
    }

    func next(_ rng: () -> Double) -> Int {
        let r1 = rng()
        let r2 = rng()
        let i = Int(Double(probs.count) * r1)
        return r2 < probs[i] ? i : aliases[i]
    }
}

// MARK: - Fragment choosing (MUR §fragment selection)

enum FountainMath {
    /// Which fragment indexes are XOR-mixed into part `seqNum`.
    static func chooseFragments(seqNum: UInt32, seqLen: Int, checksum: UInt32) -> Set<Int> {
        if seqNum <= UInt32(seqLen) {
            return [Int(seqNum) - 1]
        }
        let seed = bigEndianBytes(seqNum) + bigEndianBytes(checksum)
        let rng = Xoshiro256(seed: seed)
        let sampler = RandomSampler((1...seqLen).map { 1 / Double($0) })
        let degree = sampler.next(rng.nextDouble) + 1
        // Partial Fisher-Yates using the same RNG.
        var remaining = Array(0..<seqLen)
        var chosen: [Int] = []
        while chosen.count != degree {
            let index = rng.nextInt(in: 0..<remaining.count)
            chosen.append(remaining.remove(at: index))
        }
        return Set(chosen)
    }

    static func nominalFragmentLength(messageLen: Int, minFragmentLen: Int = 10, maxFragmentLen: Int = 100) -> Int {
        let maxCount = max(messageLen / minFragmentLen, 1)
        for count in 1...maxCount {
            let fragmentLen = Int(ceil(Double(messageLen) / Double(count)))
            if fragmentLen <= maxFragmentLen { return fragmentLen }
        }
        return maxFragmentLen
    }

    static func partition(_ message: Data, fragmentLen: Int) -> [Data] {
        var fragments: [Data] = []
        var start = message.startIndex
        while start < message.endIndex {
            let end = message.index(start, offsetBy: fragmentLen, limitedBy: message.endIndex) ?? message.endIndex
            var fragment = Data(message[start..<end])
            if fragment.count < fragmentLen {
                fragment.append(Data(repeating: 0, count: fragmentLen - fragment.count))
            }
            fragments.append(fragment)
            start = end
        }
        return fragments
    }
}

// MARK: - UR part (one frame)

struct URPart {
    let type: String
    let seqNum: UInt32
    let seqLen: Int
    let messageLen: Int
    let checksum: UInt32
    let data: Data

    /// Parse `ur:<type>/<seqNum>-<seqLen>/<bytewords>`. Returns nil for a
    /// single-part UR (no seq component).
    static func parse(_ string: String) throws -> URPart? {
        let lower = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("ur:") else { throw BCURError.notAUR }
        let components = lower.dropFirst(3).split(separator: "/")
        guard components.count >= 2 else { throw BCURError.invalidPart }
        let type = String(components[0])

        if components.count == 2 {
            return nil // single-part
        }
        guard components.count == 3 else { throw BCURError.invalidPart }

        let seq = components[1].split(separator: "-")
        guard seq.count == 2, let seqNum = UInt32(seq[0]), let seqLen = Int(seq[1]),
              seqNum >= 1, seqLen >= 1, seqLen <= 4096 else {
            throw BCURError.invalidPart
        }

        let body = try Bytewords.decodeMinimal(String(components[2]))
        guard case .array(let fields) = try? CBORDecoder.decode(body),
              fields.count == 5,
              case .unsigned(let cborSeqNum) = fields[0],
              case .unsigned(let cborSeqLen) = fields[1],
              case .unsigned(let cborMessageLen) = fields[2],
              case .unsigned(let cborChecksum) = fields[3],
              case .bytes(let data) = fields[4],
              cborSeqNum == UInt64(seqNum),
              cborSeqLen == UInt64(seqLen),
              cborMessageLen <= 10_000_000,
              cborChecksum <= UInt64(UInt32.max) else {
            throw BCURError.invalidPart
        }

        return URPart(type: type, seqNum: seqNum, seqLen: Int(cborSeqLen),
                      messageLen: Int(cborMessageLen), checksum: UInt32(cborChecksum), data: data)
    }
}

// MARK: - URDecoder (fountain reassembly)

/// Feed QR frames (`receivePart`) until `result` is non-nil. Also decodes
/// single-part URs in one call. Only `ur:bytes` payloads are interpreted (the
/// message CBOR must be a byte string — for Cashu that's the UTF-8 token).
public final class URDecoder {
    public private(set) var expectedPartCount: Int?
    public private(set) var result: Data?
    private var receivedIndexes: Set<Int> = []

    private var simpleParts: [Int: Data] = [:]
    private var mixedParts: [Set<Int>: Data] = [:]
    private var expectedChecksum: UInt32?
    private var expectedMessageLen: Int?
    private var seenFrames: Set<String> = []

    public init() {}

    public var isComplete: Bool { result != nil }

    /// Fraction of fragments recovered (0…1) for progress display.
    public var progress: Double {
        guard let expected = expectedPartCount, expected > 0 else { return 0 }
        return Double(simpleParts.count) / Double(expected)
    }

    public static func isUR(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ur:")
    }

    /// Decode a complete single-part UR (`ur:bytes/<bytewords>`) in one call.
    /// Throws `singleFrameOfMultipart` if handed one frame of an animation —
    /// callers surface that as "use the scanner" guidance.
    public static func decodeSinglePart(_ string: String) throws -> Data {
        if let part = try URPart.parse(string) {
            throw BCURError.singleFrameOfMultipart(seqNum: Int(part.seqNum), seqLen: part.seqLen)
        }
        let lower = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("ur:") else { throw BCURError.notAUR }
        let components = lower.dropFirst(3).split(separator: "/")
        guard components.count == 2 else { throw BCURError.invalidPart }
        let type = String(components[0])
        guard type == "bytes" else { throw BCURError.unsupportedType(type) }
        let body = try Bytewords.decodeMinimal(String(components[1]))
        guard case .bytes(let payload) = try? CBORDecoder.decode(body) else {
            throw BCURError.invalidPart
        }
        return payload
    }

    /// Feed one scanned frame. Returns true when the frame advanced the decode
    /// (new information). Sets `result` when the message completes.
    @discardableResult
    public func receivePart(_ string: String) throws -> Bool {
        guard result == nil else { return false }

        guard let part = try URPart.parse(string) else {
            // A single-part UR completes immediately.
            result = try Self.decodeSinglePart(string)
            expectedPartCount = 1
            return true
        }
        guard part.type == "bytes" else { throw BCURError.unsupportedType(part.type) }

        // Consistency: every part must describe the same message.
        if let checksum = expectedChecksum {
            guard part.checksum == checksum, part.seqLen == expectedPartCount,
                  part.messageLen == expectedMessageLen else {
                throw BCURError.inconsistentPart
            }
        } else {
            expectedChecksum = part.checksum
            expectedPartCount = part.seqLen
            expectedMessageLen = part.messageLen
        }

        // Skip frames we've literally already processed (animation loops).
        let frameKey = "\(part.seqNum)"
        guard !seenFrames.contains(frameKey) else { return false }
        seenFrames.insert(frameKey)

        let indexes = FountainMath.chooseFragments(seqNum: part.seqNum, seqLen: part.seqLen, checksum: part.checksum)
        reduceAndStore(indexes: indexes, data: part.data)
        try assembleIfComplete()
        return true
    }

    private func reduceAndStore(indexes initialIndexes: Set<Int>, data initialData: Data) {
        var queue: [(Set<Int>, Data)] = [(initialIndexes, initialData)]

        while let (rawIndexes, rawData) = queue.popLast() {
            var indexes = rawIndexes
            var data = rawData

            // Reduce by every known simple fragment.
            for i in indexes.intersection(simpleParts.keys) {
                guard let simple = simpleParts[i], simple.count == data.count else { continue }
                data = Data(zip(data, simple).map { $0 ^ $1 })
                indexes.remove(i)
            }

            if indexes.isEmpty { continue }

            if indexes.count == 1, let index = indexes.first {
                guard simpleParts[index] == nil else { continue }
                simpleParts[index] = data
                receivedIndexes.insert(index)
                // A new simple fragment may unlock stored mixed parts.
                let affected = mixedParts.filter { $0.key.contains(index) }
                for (key, value) in affected {
                    mixedParts.removeValue(forKey: key)
                    queue.append((key, value))
                }
            } else if mixedParts[indexes] == nil {
                // Try reducing against existing mixed parts that are strict subsets.
                for (key, value) in mixedParts where key.isStrictSubset(of: indexes) && value.count == data.count {
                    data = Data(zip(data, value).map { $0 ^ $1 })
                    indexes.subtract(key)
                }
                if indexes.count == 1 {
                    queue.append((indexes, data))
                } else {
                    mixedParts[indexes] = data
                }
            }
        }
    }

    private func assembleIfComplete() throws {
        guard let seqLen = expectedPartCount, let messageLen = expectedMessageLen,
              let checksum = expectedChecksum, simpleParts.count == seqLen else { return }

        var message = Data()
        for i in 0..<seqLen {
            guard let fragment = simpleParts[i] else { return }
            message.append(fragment)
        }
        message = message.prefix(messageLen)
        guard CRC32.checksum(message) == checksum else { throw BCURError.invalidChecksum }

        guard case .bytes(let payload) = try? CBORDecoder.decode(message) else {
            throw BCURError.invalidPart
        }
        result = payload
    }
}

// MARK: - UREncoder (for tests and future animated-QR sending)

final class UREncoder {
    private let fragments: [Data]
    private let messageLen: Int
    private let checksum: UInt32
    private var seqNum: UInt32 = 0

    init(message: Data, maxFragmentLen: Int = 100) {
        let fragmentLen = FountainMath.nominalFragmentLength(messageLen: message.count, maxFragmentLen: maxFragmentLen)
        self.fragments = FountainMath.partition(message, fragmentLen: fragmentLen)
        self.messageLen = message.count
        self.checksum = CRC32.checksum(message)
    }

    var seqLen: Int { fragments.count }

    /// Wrap a payload in the `ur:bytes` message CBOR (a byte string).
    static func makeMessage(payload: Data) -> Data {
        var enc = CBOREncoder()
        enc.appendBytes(payload)
        return enc.data
    }

    func nextPart() -> String {
        seqNum &+= 1
        let indexes = FountainMath.chooseFragments(seqNum: seqNum, seqLen: seqLen, checksum: checksum)
        var mixed = Data(repeating: 0, count: fragments[0].count)
        for i in indexes {
            mixed = Data(zip(mixed, fragments[i]).map { $0 ^ $1 })
        }
        var enc = CBOREncoder()
        enc.appendArrayHeader(count: 5)
        enc.appendUnsigned(UInt64(seqNum))
        enc.appendUnsigned(UInt64(seqLen))
        enc.appendUnsigned(UInt64(messageLen))
        enc.appendUnsigned(UInt64(checksum))
        enc.appendBytes(mixed)
        return "ur:bytes/\(seqNum)-\(seqLen)/\(Bytewords.encodeMinimal(enc.data))"
    }
}
