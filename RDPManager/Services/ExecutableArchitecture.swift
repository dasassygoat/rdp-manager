import Foundation

/// Which CPU architectures a Mach-O file was built for, and whether this Mac can run it.
///
/// `FileManager.isExecutableFile` reports only the permission bits. The FreeRDP we bundle
/// is whatever architecture the packaging Mac's Homebrew had — arm64 in practice — so on an
/// Intel Mac it passes that check and then fails to spawn with "Bad CPU type in executable".
/// Reading the header instead lets a client that cannot run here be left out of the picker,
/// so the app can point at Windows App rather than report a spawn failure.
enum ExecutableArchitecture {
    /// Written out rather than taken from `<mach-o/loader.h>`: the C headers are awkward to
    /// use across the 32- and 64-bit layouts, and five constants is the whole requirement.
    /// Fat headers are big-endian on disk; thin Mach-O headers are in host order.
    private static let fatMagic: UInt32 = 0xcafe_babe
    private static let fatMagic64: UInt32 = 0xcafe_babf
    private static let machOMagic32: UInt32 = 0xfeed_face
    private static let machOMagic64: UInt32 = 0xfeed_facf

    static let cpuARM64: UInt32 = 0x0100_000c
    static let cpuX86_64: UInt32 = 0x0100_0007

    /// The `cpu_type_t` values present in the file, or an empty set if it is not Mach-O.
    static func architectures(ofFileAt url: URL) -> Set<UInt32> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return [] }
        let bytes = [UInt8](header)

        let magic = bigEndian(bytes, 0)
        if magic == fatMagic || magic == fatMagic64 {
            let count = Int(bigEndian(bytes, 4))
            // A truncated or hostile file can claim any number of slices; no real universal
            // binary comes close to 64, and the bound keeps the read small.
            guard count > 0, count <= 64 else { return [] }
            // fat_arch is 20 bytes, fat_arch_64 is 32; cputype is the first field of both.
            let stride = magic == fatMagic64 ? 32 : 20
            guard let table = try? handle.read(upToCount: count * stride),
                  table.count == count * stride else { return [] }
            let entries = [UInt8](table)
            return Set((0..<count).map { bigEndian(entries, $0 * stride) })
        }

        let hostMagic = littleEndian(bytes, 0)
        if hostMagic == machOMagic64 || hostMagic == machOMagic32 {
            return [littleEndian(bytes, 4)]
        }
        return []
    }

    /// The architectures a child process started from here can be. Under Rosetta this
    /// process is x86_64 while the Mac itself still runs arm64 binaries, so both count.
    static var runnable: Set<UInt32> {
        #if arch(arm64)
        return [cpuARM64]
        #elseif arch(x86_64)
        return isTranslated ? [cpuX86_64, cpuARM64] : [cpuX86_64]
        #else
        return []
        #endif
    }

    /// How the architectures read out of a file should be described to someone reading an
    /// alert. Anything unrecognised is listed by its raw `cpu_type_t` rather than hidden.
    static func describe(_ types: Set<UInt32>) -> String {
        let names = types.sorted().map { type -> String in
            switch type {
            case cpuARM64: return "Apple Silicon"
            case cpuX86_64: return "Intel"
            default: return "cpu type \(type)"
            }
        }
        return names.isEmpty ? "an unknown architecture" : names.joined(separator: " and ")
    }

    static func canRun(fileAt url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let found = architectures(ofFileAt: url)
        // Anything without a Mach-O header gets the benefit of the doubt: a shell wrapper
        // with a shebang is executable and has no architecture of its own, and a Homebrew
        // FreeRDP is allowed to be one.
        guard !found.isEmpty else { return true }
        return !found.isDisjoint(with: runnable)
    }

    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset + 3]) << 24 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
    }
}
