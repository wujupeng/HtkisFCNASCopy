import CryptoKit
import Darwin
import Foundation

enum CopyError: Error, LocalizedError {
    case usage
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

    var errorDescription: String? {
        switch self {
        case .usage:
            return nil
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

struct Args {
    var src: String
    var dest: String
    var chunkMiB: Int = 8
    var overwrite: Bool = false
    var force: Bool = false
    var verify: Bool = false
    var quiet: Bool = false
    var mountTimeout: Int = 60
}

func printUsage() {
    let s = """
    Usage:
      resume-smb-copy <src> <dest> [options]

    dest:
      /path/to/dir-or-file
      smb://HOST/SHARE[/subdir]

    Options:
      --chunk-mib N       Chunk size in MiB (default: 8)
      --overwrite         Overwrite if destination file exists
      --force             Force resume even if source changed / partial inconsistent
      --verify            Verify sha256 after transfer (slower)
      --quiet             Reduce output
      --mount-timeout N   Wait up to N seconds for Finder mount (default: 60)
    """
    print(s)
}

func parseArgs(_ argv: [String]) throws -> Args {
    var positional: [String] = []
    var args = Args(src: "", dest: "")

    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a == "--chunk-mib" {
            guard i + 1 < argv.count, let n = Int(argv[i + 1]) else { throw CopyError.usage }
            args.chunkMiB = n
            i += 2
            continue
        }
        if a == "--mount-timeout" {
            guard i + 1 < argv.count, let n = Int(argv[i + 1]) else { throw CopyError.usage }
            args.mountTimeout = n
            i += 2
            continue
        }
        if a == "--overwrite" { args.overwrite = true; i += 1; continue }
        if a == "--force" { args.force = true; i += 1; continue }
        if a == "--verify" { args.verify = true; i += 1; continue }
        if a == "--quiet" { args.quiet = true; i += 1; continue }
        if a == "-h" || a == "--help" { throw CopyError.usage }

        positional.append(a)
        i += 1
    }

    guard positional.count == 2 else { throw CopyError.usage }
    args.src = positional[0]
    args.dest = positional[1]
    return args
}

func readableBytes(_ n: Double) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var size = n
    for u in units {
        if size < 1024 || u == units.last {
            if u == "B" { return "\(Int(size)) \(u)" }
            return String(format: "%.2f %@", size, u)
        }
        size /= 1024
    }
    return String(format: "%.2f TiB", size)
}

func fileSize(path: String) throws -> UInt64 {
    var st = stat()
    if lstat(path, &st) != 0 {
        throw CopyError.io(String(cString: strerror(errno)))
    }
    return UInt64(st.st_size)
}

func fileMTimeNs(path: String) throws -> Int64 {
    var st = stat()
    if lstat(path, &st) != 0 {
        throw CopyError.io(String(cString: strerror(errno)))
    }
    return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
}

struct ResumeMeta: Codable {
    var srcSize: UInt64?
    var srcMTimeNs: Int64?
    var finalPath: String?
    var createdAt: Double?
}

func readMeta(_ url: URL) throws -> ResumeMeta {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ResumeMeta.self, from: data)
}

func writeMeta(_ url: URL, meta: ResumeMeta) throws {
    let data = try JSONEncoder().encode(meta)
    let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp", isDirectory: false)
    try data.write(to: tmp, options: .atomic)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
}

func sha256(path: String, chunkBytes: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: max(1, chunkBytes)), !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func isMountPoint(_ url: URL) -> Bool {
    var st = stat()
    var pst = stat()
    let parent = url.deletingLastPathComponent()
    if lstat(url.path, &st) != 0 { return false }
    if lstat(parent.path, &pst) != 0 { return false }
    return st.st_dev != pst.st_dev
}

func findMountedShareDirectory(caseInsensitive share: String) -> URL? {
    let vols = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    guard let items = try? FileManager.default.contentsOfDirectory(at: vols, includingPropertiesForKeys: nil) else {
        return nil
    }
    let target = share.lowercased()
    for u in items {
        if u.lastPathComponent.lowercased() == target, isMountPoint(u) {
            return u
        }
    }
    return nil
}

func resolveSMBMountedPath(from smbURLString: String) throws -> URL {
    guard let u = URL(string: smbURLString), u.scheme?.lowercased() == "smb" else {
        throw CopyError.smbURLInvalid(smbURLString)
    }
    let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let parts = path.split(separator: "/").map(String.init)
    guard let share = parts.first, !share.isEmpty else {
        throw CopyError.smbURLInvalid(smbURLString)
    }
    let remainder = parts.dropFirst()
    var mountBase = URL(fileURLWithPath: "/Volumes").appendingPathComponent(share, isDirectory: true)
    if FileManager.default.fileExists(atPath: mountBase.path) {
        if !isMountPoint(mountBase), let mounted = findMountedShareDirectory(caseInsensitive: share) {
            mountBase = mounted
        }
    } else if let mounted = findMountedShareDirectory(caseInsensitive: share) {
        mountBase = mounted
    }
    if !FileManager.default.fileExists(atPath: mountBase.path) || !isMountPoint(mountBase) {
        throw CopyError.smbNotMounted(expectedMountPoint: mountBase.path)
    }
    var dest = mountBase
    for p in remainder { dest.appendPathComponent(p, isDirectory: true) }
    return dest
}

func openFinderMount(_ smbURLString: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [smbURLString]
    try? p.run()
}

func waitForSMBMount(_ smbURLString: String, timeoutSeconds: Int) throws -> URL {
    openFinderMount(smbURLString)
    let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
    while Date() < deadline {
        do {
            return try resolveSMBMountedPath(from: smbURLString)
        } catch {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
    throw CopyError.smbMountTimeout
}

func resumableCopy(
    src: URL,
    dest: URL,
    chunkBytes: Int,
    overwrite: Bool,
    force: Bool,
    verify: Bool,
    quiet: Bool,
    progressIntervalSeconds: Double = 1.0
) throws -> URL {
    let srcPath = src.path
    guard FileManager.default.fileExists(atPath: srcPath) else {
        throw CopyError.sourceNotFound(srcPath)
    }

    let srcSize = try fileSize(path: srcPath)
    let srcMTimeNs = try fileMTimeNs(path: srcPath)

    var finalPath = dest
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
        finalPath = dest.appendingPathComponent(src.lastPathComponent, isDirectory: false)
    }

    try FileManager.default.createDirectory(at: finalPath.deletingLastPathComponent(), withIntermediateDirectories: true)

    let partPath = finalPath.deletingLastPathComponent().appendingPathComponent(finalPath.lastPathComponent + ".part", isDirectory: false)
    let metaPath = finalPath.deletingLastPathComponent().appendingPathComponent(finalPath.lastPathComponent + ".resume.json", isDirectory: false)

    if FileManager.default.fileExists(atPath: finalPath.path) {
        if overwrite {
            try FileManager.default.removeItem(at: finalPath)
        } else {
            let dstSize = try fileSize(path: finalPath.path)
            if dstSize == srcSize {
                if !quiet { print("Already exists (same size), skipping: \(finalPath.path)") }
                return finalPath
            }
            throw CopyError.destinationExists(finalPath.path)
        }
    }

    if FileManager.default.fileExists(atPath: metaPath.path), !force {
        if let meta = try? readMeta(metaPath) {
            if let expectedSize = meta.srcSize, expectedSize != srcSize { throw CopyError.sourceChanged }
            if let expectedMTimeNs = meta.srcMTimeNs, expectedMTimeNs != srcMTimeNs { throw CopyError.sourceChanged }
        }
    }

    var resumeOffset: UInt64 = 0
    if FileManager.default.fileExists(atPath: partPath.path) {
        resumeOffset = try fileSize(path: partPath.path)
    }

    if resumeOffset > srcSize {
        if !force { throw CopyError.partialLargerThanSource }
        try? FileManager.default.removeItem(at: partPath)
        resumeOffset = 0
    }

    try writeMeta(
        metaPath,
        meta: ResumeMeta(srcSize: srcSize, srcMTimeNs: srcMTimeNs, finalPath: finalPath.path, createdAt: Date().timeIntervalSince1970)
    )

    if !quiet {
        if resumeOffset > 0 {
            print("Resuming from \(resumeOffset) / \(srcSize)")
        } else {
            print("Starting upload: \(srcSize)")
        }
    }

    var bytesCopied = resumeOffset
    var lastTick = CFAbsoluteTimeGetCurrent()
    var lastBytes = bytesCopied

    let srcHandle = try FileHandle(forReadingFrom: src)
    defer { try? srcHandle.close() }
    if resumeOffset > 0 { try srcHandle.seek(toOffset: resumeOffset) }

    if !FileManager.default.fileExists(atPath: partPath.path) {
        FileManager.default.createFile(atPath: partPath.path, contents: nil)
    }

    let dstHandle = try FileHandle(forWritingTo: partPath)
    defer { try? dstHandle.close() }
    try dstHandle.seekToEnd()

    while true {
        guard let chunk = try srcHandle.read(upToCount: max(1, chunkBytes)), !chunk.isEmpty else { break }
        try dstHandle.write(contentsOf: chunk)
        bytesCopied += UInt64(chunk.count)

        if !quiet {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastTick >= progressIntervalSeconds {
                let deltaBytes = bytesCopied - lastBytes
                let deltaTime = now - lastTick
                let bps = deltaTime > 0 ? Double(deltaBytes) / deltaTime : 0
                let pct = srcSize > 0 ? (Double(bytesCopied) / Double(srcSize) * 100.0) : 100.0
                let line = String(
                    format: "%6.2f%%  %@ / %@  %@/s\n",
                    pct,
                    readableBytes(Double(bytesCopied)),
                    readableBytes(Double(srcSize)),
                    readableBytes(bps)
                )
                fputs(line, stderr)
                lastTick = now
                lastBytes = bytesCopied
            }
        }
    }

    dstHandle.synchronizeFile()

    let partSize = try fileSize(path: partPath.path)
    if partSize != srcSize {
        throw CopyError.incompleteTransfer(got: partSize, expected: srcSize)
    }

    if verify {
        let srcHash = try sha256(path: srcPath, chunkBytes: chunkBytes)
        let dstHash = try sha256(path: partPath.path, chunkBytes: chunkBytes)
        if srcHash != dstHash { throw CopyError.verificationFailed }
    }

    if FileManager.default.fileExists(atPath: finalPath.path), overwrite {
        try FileManager.default.removeItem(at: finalPath)
    }

    if FileManager.default.fileExists(atPath: finalPath.path) {
        throw CopyError.destinationExists(finalPath.path)
    }

    try FileManager.default.moveItem(at: partPath, to: finalPath)
    try? FileManager.default.removeItem(at: metaPath)
    return finalPath
}

do {
    let a = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    let src = URL(fileURLWithPath: a.src).standardizedFileURL

    let dest: URL
    if a.dest.lowercased().hasPrefix("smb://") {
        do {
            dest = try resolveSMBMountedPath(from: a.dest)
        } catch {
            dest = try waitForSMBMount(a.dest, timeoutSeconds: a.mountTimeout)
        }
    } else {
        dest = URL(fileURLWithPath: a.dest).standardizedFileURL
    }

    let out = try resumableCopy(
        src: src,
        dest: dest,
        chunkBytes: max(1, a.chunkMiB) * 1024 * 1024,
        overwrite: a.overwrite,
        force: a.force,
        verify: a.verify,
        quiet: a.quiet
    )
    if !a.quiet { print("Done: \(out.path)") }
    exit(0)
} catch let e as CopyError {
    if case .usage = e {
        printUsage()
        exit(2)
    }
    fputs("Error: \(e.localizedDescription)\n", stderr)
    exit(2)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
