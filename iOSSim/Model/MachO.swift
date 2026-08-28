import Foundation

/// A small read-only Mach-O inspector used for LiveContainer preflight UI.
/// Executable conversion is deliberately delegated to upstream LCMachOUtils;
/// iOSSim does not rewrite the guest's platform load command.
enum MachO {
    static let magic64: UInt32 = 0xFEED_FACF
    static let magic32: UInt32 = 0xFEED_FACE
    static let fatMagic: UInt32 = 0xCAFE_BABE     // big-endian on disk
    static let fatMagicSwapped: UInt32 = 0xBEBA_FECA

    static let LC_BUILD_VERSION: UInt32 = 0x32
    static let LC_VERSION_MIN_IPHONEOS: UInt32 = 0x25

    private static let LC_ENCRYPTION_INFO: UInt32 = 0x21
    private static let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C

    private static let MH_DYLIB: UInt32 = 0x6

    enum Platform: UInt32 {
        case macOS = 1
        case iOS = 2
        case tvOS = 3
        case watchOS = 4
        case iOSSimulator = 7
        case tvOSSimulator = 8
        case watchOSSimulator = 9

        var label: String {
            switch self {
            case .macOS: "macOS"
            case .iOS: "iOS (device)"
            case .tvOS: "tvOS"
            case .watchOS: "watchOS"
            case .iOSSimulator: "iOS Simulator"
            case .tvOSSimulator: "tvOS Simulator"
            case .watchOSSimulator: "watchOS Simulator"
            }
        }
    }

    struct Info {
        var arch: String
        var platform: Platform?
        var isLoadableDylib: Bool
        var isEncrypted: Bool
        /// Only LC_VERSION_MIN_IPHONEOS, with no LC_BUILD_VERSION.
        var legacyVersionMinOnly: Bool
    }

    // MARK: - Inspect

    static func inspect(_ url: URL) -> Info? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 8 else {
            return nil
        }
        // Fat binaries: read the first (usually only) arm64 slice.
        if data.beU32(0) == fatMagic {
            let count = Int(data.beU32(4))
            for index in 0..<count {
                let entry = 8 + index * 20
                guard entry + 20 <= data.count else { break }
                let offset = Int(data.beU32(entry + 8))
                if let slice = inspectThin(data, at: offset) { return slice }
            }
            return nil
        }
        return inspectThin(data, at: 0)
    }

    private static func inspectThin(_ data: Data, at base: Int) -> Info? {
        guard base + 16 <= data.count else { return nil }
        let magic = data.leU32(base)
        guard magic == magic64 || magic == magic32 else { return nil }

        let cpuType = data.leU32(base + 4)
        // The 64-bit types carry CPU_ARCH_ABI64 in the top byte; 0x7 on its own
        // is 32-bit i386, not x86_64.
        let arch = switch cpuType {
        case 0x0100_000C: "arm64"
        case 0x0000_000C: "arm"
        case 0x0100_0007: "x86_64"
        case 0x0000_0007: "i386"
        default: "0x\(String(cpuType, radix: 16))"
        }
        let ncmds = Int(data.leU32(base + 16))
        let headerSize = magic == magic64 ? 32 : 28

        let fileType = data.leU32(base + 12)
        var platform: Platform?
        var legacyMin = false
        var encrypted = false
        var offset = base + headerSize

        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = data.leU32(offset)
            let size = Int(data.leU32(offset + 4))
            if cmd == LC_BUILD_VERSION, offset + 12 <= data.count {
                platform = Platform(rawValue: data.leU32(offset + 8))
            } else if cmd == LC_VERSION_MIN_IPHONEOS {
                legacyMin = true
            } else if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64),
                      offset + 20 <= data.count {
                encrypted = data.leU32(offset + 16) != 0
            }
            offset += size
            if size == 0 { break }
        }
        return Info(arch: arch, platform: platform,
                    isLoadableDylib: fileType == MH_DYLIB,
                    isEncrypted: encrypted,
                    legacyVersionMinOnly: platform == nil && legacyMin)
    }

}

// MARK: - Endian readers

private extension Data {
    func leU32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
    func beU32(_ offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }
}
