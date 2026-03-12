import CryptoKit
import Darwin
import Foundation

public enum CopyError: Error, LocalizedError, Equatable {
    case sourceNotFound(String)
    case destinationExists(String)
    case sourceChanged
    case partialLargerThanSource
    case incompleteTransfer(got: UInt64, expected: UInt64)
    case verificationFailed
    case smbNotMounted(expectedMountPoint: String)
    case smbURLInvalid(String)
    case smbMountTimeout
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .sourceNotFound(s):
            return "Source file not found: \(s)"
        case let .destinationExists(s):
            return "Destination exists: \(s)"
        case .sourceChanged:
            return "Source file changed since last attempt. Use --force to resume anyway."
        case .partialLargerThanSource:
            return "Partial file larger than source. Use --force to overwrite partial."
        case let .incompleteTransfer(got, expected):
            return "Incomplete transfer: got \(got), expected \(expected)"
        case .verificationFailed:
            return "Verification failed (sha256 mismatch)."
        case let .smbNotMounted(expectedMountPoint):
            return "SMB share not mounted. Expected mount point: \(expectedMountPoint)"
        case let .smbURLInvalid(s):
            return "Invalid smb URL: \(s)"
        case .smbMountTimeout:
            return "SMB mount timeout"
        case let .io(s):
            return s
        }
    }
}

public struct ResumableCopyOptions: Sendable {
    public var chunkBytes: Int
    public var overwrite: Bool
    public var force: Bool
    public var verify: Bool
    public var quiet: Bool
    public var progressIntervalSeconds: Double

    public init(
        chunkBytes: Int = 8 * 1024 * 1024,
        overwrite: Bool = false,
        force: Bool = false,
        verify: Bool = false,
        quiet: Bool = false,
        progressIntervalSeconds: Double = 1.0
    ) {
        self.chunkBytes = max(1, chunkBytes)
        self.overwrite = overwrite
        self.force = force
        self.verify = verify
        self.quiet = quiet
        self.progressIntervalSeconds = max(0.1, progressIntervalSeconds)
    }
}

public struct SMBMountedPath {
    public var mountedPath: URL
    public var shareName: String
}

public enum SMBResolver {
    public static func resolveMountedPath(fromSMBURL smbURLString: String) throws -> SMBMountedPath {
        guard let u = URL(string: smbURLString), u.scheme?.lowercased() == "smb" else {
            throw CopyError.smbURLInvalid(smbURLString)
        }

        let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/").map(String.init)
        guard let share = parts.first, !share.isEmpty else {
            throw CopyError.smbURLInvalid(smbURLString)
        }

        let remainder = parts.dropFirst()
        let mountBase = URL(fileURLWithPath: "/Volumes").appendingPathComponent(share, isDirectory: true)
        if !FileManager.default.fileExists(atPath: mountBase.path) {
            throw CopyError.smbNotMounted(expectedMountPoint: mountBase.path)
        }

        var dest = mountBase
        for p in remainder {
            dest.appendPathComponent(p, isDirectory: true)
        }

        return SMBMountedPath(mountedPath: dest, shareName: share)
    }

    public static func openFinderMount(smbURLString: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [smbURLString]
        try? p.run()
    }

    public static func waitForMount(smbURLString: String, timeoutSeconds: Int) throws -> URL {
        openFinderMount(smbURLString: smbURLString)
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
        var last: Error?
        while Date() < deadline {
            do {
                return try resolveMountedPath(fromSMBURL: smbURLString).mountedPath
            } catch {
                last = error
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        if last != nil {
            throw CopyError.smbMountTimeout
        }
        throw CopyError.smbMountTimeout
    }
}

public struct ResumableCopy {
    public init() {}

    public func run(
        source: URL,
        destination: URL,
        options: ResumableCopyOptions,
        progress: (@Sendable (_ copied: UInt64, _ total: UInt64, _ bytesPerSecond: Double) -> Void)? = nil
    ) throws -> URL {
        let srcPath = source.path
        guard FileManager.default.fileExists(atPath: srcPath) else {
            throw CopyError.sourceNotFound(srcPath)
        }

        let srcSize = try fileSize(path: srcPath)
        let srcMTimeNs = try fileMTimeNs(path: srcPath)

        var finalPath = destination
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue {
            finalPath = destination.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        }

        try FileManager.default.createDirectory(
            at: finalPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let partPath = finalPath.deletingLastPathComponent().appendingPathComponent(finalPath.lastPathComponent + ".part", isDirectory: false)
        let metaPath = finalPath.deletingLastPathComponent().appendingPathComponent(finalPath.lastPathComponent + ".resume.json", isDirectory: false)

        if FileManager.default.fileExists(atPath: finalPath.path) {
            if options.overwrite {
                try FileManager.default.removeItem(at: finalPath)
            } else {
                let dstSize = try fileSize(path: finalPath.path)
                if dstSize == srcSize {
                    if !options.quiet {
                        print("Already exists (same size), skipping: \(finalPath.path)")
                    }
                    return finalPath
                }
                throw CopyError.destinationExists(finalPath.path)
            }
        }

        if FileManager.default.fileExists(atPath: metaPath.path), !options.force {
            if let meta = try? readMeta(metaPath: metaPath) {
                if let expectedSize = meta.srcSize, expectedSize != srcSize { throw CopyError.sourceChanged }
                if let expectedMTimeNs = meta.srcMTimeNs, expectedMTimeNs != srcMTimeNs { throw CopyError.sourceChanged }
            }
        }

        var resumeOffset: UInt64 = 0
        if FileManager.default.fileExists(atPath: partPath.path) {
            resumeOffset = try fileSize(path: partPath.path)
        }

        if resumeOffset > srcSize {
            if !options.force {
                throw CopyError.partialLargerThanSource
            }
            try? FileManager.default.removeItem(at: partPath)
            resumeOffset = 0
        }

        try writeMeta(metaPath: metaPath, srcSize: srcSize, srcMTimeNs: srcMTimeNs, finalPath: finalPath.path)

        if !options.quiet {
            if resumeOffset > 0 {
                print("Resuming from \(resumeOffset) / \(srcSize)")
            } else {
                print("Starting upload: \(srcSize)")
            }
        }

        var bytesCopied = resumeOffset
        var lastTick = CFAbsoluteTimeGetCurrent()
        var lastBytes = bytesCopied

        let srcHandle = try FileHandle(forReadingFrom: source)
        defer { try? srcHandle.close() }
        if resumeOffset > 0 { try srcHandle.seek(toOffset: resumeOffset) }

        if !FileManager.default.fileExists(atPath: partPath.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(at: partPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: partPath.path) {
            FileManager.default.createFile(atPath: partPath.path, contents: nil)
        }

        let dstHandle = try FileHandle(forWritingTo: partPath)
        defer { try? dstHandle.close() }
        try dstHandle.seekToEnd()

        while true {
            guard let chunk = try srcHandle.read(upToCount: options.chunkBytes), !chunk.isEmpty else { break }
            try dstHandle.write(contentsOf: chunk)
            bytesCopied += UInt64(chunk.count)

            let now = CFAbsoluteTimeGetCurrent()
            if let progress, !options.quiet, now - lastTick >= options.progressIntervalSeconds {
                let deltaBytes = bytesCopied - lastBytes
                let deltaTime = now - lastTick
                let bps = deltaTime > 0 ? Double(deltaBytes) / deltaTime : 0
                progress(bytesCopied, srcSize, bps)
                lastTick = now
                lastBytes = bytesCopied
            }
        }

        dstHandle.synchronizeFile()

        let partSize = try fileSize(path: partPath.path)
        if partSize != srcSize {
            throw CopyError.incompleteTransfer(got: partSize, expected: srcSize)
        }

        if options.verify {
            let srcHash = try sha256(path: srcPath, chunkBytes: options.chunkBytes)
            let dstHash = try sha256(path: partPath.path, chunkBytes: options.chunkBytes)
            if srcHash != dstHash {
                throw CopyError.verificationFailed
            }
        }

        if FileManager.default.fileExists(atPath: finalPath.path), options.overwrite {
            try FileManager.default.removeItem(at: finalPath)
        }

        if FileManager.default.fileExists(atPath: finalPath.path) {
            throw CopyError.destinationExists(finalPath.path)
        }

        try FileManager.default.moveItem(at: partPath, to: finalPath)
        try? FileManager.default.removeItem(at: metaPath)
        return finalPath
    }

    private func fileSize(path: String) throws -> UInt64 {
        var st = stat()
        if lstat(path, &st) != 0 {
            throw CopyError.io(String(cString: strerror(errno)))
        }
        return UInt64(st.st_size)
    }

    private func fileMTimeNs(path: String) throws -> Int64 {
        var st = stat()
        if lstat(path, &st) != 0 {
            throw CopyError.io(String(cString: strerror(errno)))
        }
        let sec = Int64(st.st_mtimespec.tv_sec)
        let nsec = Int64(st.st_mtimespec.tv_nsec)
        return sec * 1_000_000_000 + nsec
    }

    private struct ResumeMeta: Codable {
        var srcSize: UInt64?
        var srcMTimeNs: Int64?
        var finalPath: String?
        var createdAt: Double?
    }

    private func readMeta(metaPath: URL) throws -> ResumeMeta {
        let data = try Data(contentsOf: metaPath)
        return try JSONDecoder().decode(ResumeMeta.self, from: data)
    }

    private func writeMeta(metaPath: URL, srcSize: UInt64, srcMTimeNs: Int64, finalPath: String) throws {
        let meta = ResumeMeta(srcSize: srcSize, srcMTimeNs: srcMTimeNs, finalPath: finalPath, createdAt: Date().timeIntervalSince1970)
        let data = try JSONEncoder().encode(meta)
        let tmp = metaPath.deletingLastPathComponent().appendingPathComponent(metaPath.lastPathComponent + ".tmp", isDirectory: false)
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: metaPath)
        try FileManager.default.moveItem(at: tmp, to: metaPath)
    }

    private func sha256(path: String, chunkBytes: Int) throws -> String {
        let h = try sha256Digest(path: path, chunkBytes: chunkBytes)
        return h.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Digest(path: String, chunkBytes: Int) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: max(1, chunkBytes)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
