import Foundation
import Compression

/// A minimal ZIP reader, enough to unpack an `.ipa`.
///
/// iOS ships no `unzip` binary and `Foundation.Process` is macOS-only, so an
/// IPA has to be taken apart by hand. IPAs use only two storage methods —
/// stored (0) and deflate (8) — and both are handled here by walking the
/// central directory and inflating each entry with the Compression framework.
enum ZipArchive {
    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
        /// bit 0 of the external attributes' unix mode == executable.
        let unixMode: UInt16
    }

    enum ZipError: LocalizedError {
        case notAZip
        case truncated
        case unsupportedMethod(UInt16)
        case inflateFailed
        case unsafePath(String)
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .notAZip: "The selected file is not a ZIP archive."
            case .truncated: "The archive is incomplete or damaged."
            case .unsupportedMethod(let method): "The archive uses unsupported compression method \(method)."
            case .inflateFailed: "The archive could not be decompressed."
            case .unsafePath: "The archive contains an unsafe file path."
            case .archiveTooLarge: "The archive is too large to import safely."
            }
        }
    }

    /// Extracts the whole archive under `destination`, returning the executable
    /// bits so the unpacker can restore them (an IPA's main binary must stay
    /// executable to be dlopen'd).
    @discardableResult
    static func extract(
        _ archiveURL: URL,
        to destination: URL,
        maximumUncompressedBytes: Int? = nil,
        maximumEntries: Int? = nil
    ) throws -> [String: UInt16] {
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let entries = try readCentralDirectory(data)

        if let maximumEntries, entries.count > maximumEntries {
            throw ZipError.archiveTooLarge
        }
        if let maximumUncompressedBytes {
            var total = 0
            for entry in entries {
                guard entry.uncompressedSize <= maximumUncompressedBytes - total else {
                    throw ZipError.archiveTooLarge
                }
                total += entry.uncompressedSize
            }
        }

        let manager = FileManager.default
        var modes: [String: UInt16] = [:]

        let root = destination.standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in entries {
            // Some repackaged IPAs accidentally contain the private marker
            // MobileContainerManager places at the root of an application's
            // data container.  The sandbox deliberately rejects attempts to
            // create that system-owned filename, and it is never part of an
            // application bundle's runnable payload.  Ignore it anywhere in
            // an imported archive instead of aborting an otherwise valid app
            // install with a misleading permission error.
            if isMobileContainerManagerMetadata(entry.path) { continue }

            let outURL = try safeOutputURL(for: entry.path, under: root)
            if entry.isDirectory {
                try? manager.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }
            try? manager.createDirectory(at: outURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

            let payload = try inflate(entry, from: data)
            try payload.write(to: outURL)
            if entry.unixMode != 0 { modes[entry.path] = entry.unixMode }
        }
        return modes
    }

    private static func isMobileContainerManagerMetadata(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).last
            == ".com.apple.mobile_container_manager.metadata.plist"
    }

    /// ZIP paths are attacker-controlled. Keep every entry beneath the chosen
    /// extraction directory so a crafted IPA or Tendies file cannot write into
    /// the app container with `../` or an absolute path.
    private static func safeOutputURL(for path: String, under root: URL) throws -> URL {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ZipError.unsafePath(path)
        }

        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
            throw ZipError.unsafePath(path)
        }
        return candidate
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // Locate the End Of Central Directory record, scanning back from the
        // tail (there may be a comment after it).
        let eocdSignature: UInt32 = 0x0605_4b50
        guard data.count > 22 else { throw ZipError.truncated }

        var eocd = -1
        let lowerBound = max(0, data.count - 22 - 0xFFFF)
        var index = data.count - 22
        while index >= lowerBound {
            if data.u32(index) == eocdSignature { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let entryCount = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))     // start of central directory

        let cdSignature: UInt32 = 0x0201_4b50
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, data.u32(offset) == cdSignature else {
                throw ZipError.truncated
            }
            let method = data.u16(offset + 10)
            let compressed = Int(data.u32(offset + 20))
            let uncompressed = Int(data.u32(offset + 24))
            let nameLen = Int(data.u16(offset + 28))
            let extraLen = Int(data.u16(offset + 30))
            let commentLen = Int(data.u16(offset + 32))
            let localHeader = Int(data.u32(offset + 42))
            let externalAttrs = data.u32(offset + 38)
            let unixMode = UInt16((externalAttrs >> 16) & 0xFFFF)

            let nameStart = offset + 46
            guard nameStart <= data.count,
                  nameLen <= data.count - nameStart,
                  extraLen <= data.count - nameStart - nameLen,
                  commentLen <= data.count - nameStart - nameLen - extraLen else {
                throw ZipError.truncated
            }
            let name = String(decoding: data[nameStart..<nameStart + nameLen], as: UTF8.self)

            entries.append(Entry(
                path: name,
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localHeader,
                isDirectory: name.hasSuffix("/"),
                unixMode: unixMode
            ))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    // MARK: - Inflate

    private static func inflate(_ entry: Entry, from data: Data) throws -> Data {
        // The local header repeats the name/extra lengths; the payload starts
        // after them, not at a fixed offset from the central-directory record.
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count, data.u32(local) == 0x0403_4b50 else {
            throw ZipError.truncated
        }
        let nameLen = Int(data.u16(local + 26))
        let extraLen = Int(data.u16(local + 28))
        let dataStart = local + 30 + nameLen + extraLen
        guard dataStart >= 0,
              entry.compressedSize >= 0,
              dataStart <= data.count,
              entry.compressedSize <= data.count - dataStart else {
            throw ZipError.truncated
        }
        let compressed = data.subdata(in: dataStart..<dataStart + entry.compressedSize)

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try rawInflate(compressed, expected: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedMethod(entry.compressionMethod)
        }
    }

    /// Apple's `COMPRESSION_ZLIB` codec is raw DEFLATE (RFC 1951), which is
    /// exactly what ZIP method 8 stores — no zlib wrapper to strip.
    private static func rawInflate(_ input: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var output = Data(count: expected)

        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expected else { throw ZipError.inflateFailed }
        return output
    }
}

// MARK: - Little-endian readers

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
