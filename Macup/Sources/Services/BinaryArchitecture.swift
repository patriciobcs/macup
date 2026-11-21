import Foundation

/// Read Mach-O headers without launching an app or an incompatible runtime.
enum BinaryArchitecture {
    static func read(_ file: URL) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return [] }
        let bytes = [UInt8](data)
        func integer(_ offset: Int, little: Bool = false) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            let slice = Array(bytes[offset..<offset + 4])
            return (little ? Array(slice.reversed()) : slice).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func name(_ cpu: UInt32) -> String? {
            switch cpu {
            case 0x0100_000C: "arm64"
            case 0x0100_0007: "x86_64"
            default: nil
            }
        }
        switch integer(0) {
        case 0xFEED_FACE, 0xFEED_FACF: return Set(name(integer(4)).map { [$0] } ?? [])
        case 0xCEFA_EDFE, 0xCFFA_EDFE: return Set(name(integer(4, little: true)).map { [$0] } ?? [])
        case 0xCAFE_BABE, 0xCAFE_BABF, 0xBEBA_FECA, 0xBFBA_FECA:
            let little = [UInt32(0xBEBA_FECA), 0xBFBA_FECA].contains(integer(0))
            let stride = [UInt32(0xCAFE_BABF), 0xBFBA_FECA].contains(integer(0)) ? 32 : 20
            return Set(
                (0..<min(Int(integer(4, little: little)), 32)).compactMap {
                    name(integer(8 + $0 * stride, little: little))
                })
        default: return []
        }
    }
}
