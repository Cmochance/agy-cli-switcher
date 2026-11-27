import Foundation

enum ProtobufError: Error, Equatable {
    case invalidVarint
    case invalidField
    case truncated
    case unsupportedWireType(UInt64)
}

/// Zero-dependency wire reader for local Antigravity protobuf blobs. Unknown fields are skipped safely.
struct ProtobufMessage: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case varint(Int64)
        case bytes(Data)
        case fixed32(UInt32)
        case fixed64(UInt64)
    }

    private(set) var fields: [Int: [Value]]

    init(fields: [Int: [Value]] = [:]) {
        self.fields = fields
    }

    init(data: Data) throws {
        var parsed: [Int: [Value]] = [:]
        var offset = 0
        let count = data.count

        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < count, shift < 70 {
                let byte = data[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return value
                }
                shift += 7
            }
            throw ProtobufError.invalidVarint
        }

        while offset < count {
            let key = try readVarint()
            let fieldNumber = Int(key >> 3)
            let wireType = key & 0x07
            guard fieldNumber > 0 else {
                throw ProtobufError.invalidField
            }
            let value: Value
            switch wireType {
            case 0:
                let raw = try readVarint()
                value = .varint(Int64(bitPattern: raw))
            case 1:
                guard offset + 8 <= count else {
                    throw ProtobufError.truncated
                }
                var raw: UInt64 = 0
                for idx in 0 ..< 8 {
                    raw |= UInt64(data[offset + idx]) << (idx * 8)
                }
                offset += 8
                value = .fixed64(raw)
            case 2:
                let lengthU64 = try readVarint()
                guard lengthU64 <= UInt64(count - offset) else {
                    throw ProtobufError.truncated
                }
                let length = Int(lengthU64)
                let slice = data.subdata(in: offset ..< (offset + length))
                offset += length
                value = .bytes(slice)
            case 5:
                guard offset + 4 <= count else {
                    throw ProtobufError.truncated
                }
                var raw: UInt32 = 0
                for idx in 0 ..< 4 {
                    raw |= UInt32(data[offset + idx]) << (idx * 8)
                }
                offset += 4
                value = .fixed32(raw)
            default:
                throw ProtobufError.unsupportedWireType(wireType)
            }
            parsed[fieldNumber, default: []].append(value)
        }
        self.fields = parsed
    }

    var isEmpty: Bool {
        fields.isEmpty
    }

    func has(_ fieldNumber: Int) -> Bool {
        !(fields[fieldNumber]?.isEmpty ?? true)
    }

    func int(_ fieldNumber: Int, default fallback: Int64 = 0) -> Int64 {
        optionalInt(fieldNumber) ?? fallback
    }

    func optionalInt(_ fieldNumber: Int) -> Int64? {
        guard let values = fields[fieldNumber] else {
            return nil
        }
        for value in values {
            if case .varint(let number) = value {
                return number
            }
        }
        return nil
    }

    /// Reads both repeated varints and packed length-delimited varint chunks.
    func packedOrRepeatedInts(_ fieldNumber: Int) -> [Int] {
        guard let values = fields[fieldNumber] else {
            return []
        }
        var result: [Int] = []
        for value in values {
            switch value {
            case .varint(let number):
                if let exact = Int(exactly: number) {
                    result.append(exact)
                }
            case .bytes(let chunk):
                var offset = 0
                while offset < chunk.count {
                    var raw: UInt64 = 0
                    var shift: UInt64 = 0
                    var finished = false
                    while offset < chunk.count, shift < 70 {
                        let byte = chunk[offset]
                        offset += 1
                        raw |= UInt64(byte & 0x7F) << shift
                        if (byte & 0x80) == 0 {
                            finished = true
                            break
                        }
                        shift += 7
                    }
                    guard finished else {
                        break
                    }
                    let signed = Int64(bitPattern: raw)
                    if let exact = Int(exactly: signed) {
                        result.append(exact)
                    }
                }
            case .fixed32, .fixed64:
                continue
            }
        }
        return result
    }

    func data(_ fieldNumber: Int) -> Data? {
        guard let values = fields[fieldNumber] else {
            return nil
        }
        for value in values {
            if case .bytes(let slice) = value {
                return slice
            }
        }
        return nil
    }

    func datas(_ fieldNumber: Int) -> [Data] {
        guard let values = fields[fieldNumber] else {
            return []
        }
        return values.compactMap { value in
            if case .bytes(let slice) = value {
                return slice
            }
            return nil
        }
    }

    func nested(_ fieldNumber: Int) -> ProtobufMessage {
        guard let slice = data(fieldNumber), let decoded = try? ProtobufMessage(data: slice) else {
            return ProtobufMessage()
        }
        return decoded
    }

    func messages(_ fieldNumber: Int) -> [ProtobufMessage] {
        datas(fieldNumber).compactMap { try? ProtobufMessage(data: $0) }
    }

    func string(_ fieldNumber: Int) -> String {
        guard let slice = data(fieldNumber) else {
            return ""
        }
        return String(decoding: slice, as: UTF8.self)
    }

    /// Converts a google.protobuf.Timestamp or google.protobuf.Duration blob to milliseconds.
    static func milliseconds(_ data: Data?) -> Double? {
        guard let data, !data.isEmpty, let msg = try? ProtobufMessage(data: data) else {
            return nil
        }
        let seconds = Double(msg.int(1, default: 0))
        let nanos = Double(msg.int(2, default: 0))
        return seconds * 1000.0 + nanos / 1_000_000.0
    }
}
