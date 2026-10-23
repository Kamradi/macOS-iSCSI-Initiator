import Foundation

enum RPCError: Error { case malformed }
struct XDRReader {
    let data: [UInt8]
    var cursor = 0
    init(_ data: [UInt8]) { self.data = data }
    mutating func word() throws -> UInt32 {
        guard cursor + 4 <= data.count else { throw RPCError.malformed }
        defer { cursor += 4 }
        return data[cursor..<(cursor + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func long() throws -> UInt64 { let high = try word(); return UInt64(high) << 32 | UInt64(try word()) }
    mutating func fixed(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= data.count - cursor else { throw RPCError.malformed }
        defer { cursor += count }
        return Array(data[cursor..<(cursor + count)])
    }
    mutating func opaque(max: Int = 1048576) throws -> [UInt8] {
        let count = Int(try word())
        guard count <= max else { throw RPCError.malformed }
        let bytes = try fixed(count)
        _ = try fixed((4 - count % 4) % 4)
        return bytes
    }
    mutating func string() throws -> String { String(decoding: try opaque(max: 4096), as: UTF8.self) }
}
struct XDRWriter {
    var bytes: [UInt8] = []
    mutating func word(_ value: UInt32) { bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
    mutating func long(_ value: UInt64) { word(UInt32(truncatingIfNeeded: value >> 32)); word(UInt32(truncatingIfNeeded: value)) }
    mutating func bool(_ value: Bool) { word(value ? 1 : 0) }
    mutating func opaque(_ data: [UInt8]) { word(UInt32(data.count)); bytes += data; bytes += [UInt8](repeating: 0, count: (4 - data.count % 4) % 4) }
    mutating func string(_ string: String) { opaque(Array(string.utf8)) }
}
