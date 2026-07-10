import Foundation
import Darwin
import Testing

@testable import ResumeSMBCopyCore

func makeTempDir() throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func randomData(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in bytes.indices {
        bytes[i] = UInt8.random(in: 0 ... 255)
    }
    return Data(bytes)
}

final class CancellationFlag: @unchecked Sendable {
    var isCancelled = false
}

@Test
func resumeFromPartial() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("src.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 2 * 1024 * 1024 + 123)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("src.bin", isDirectory: false)
    let part = destDir.appendingPathComponent("src.bin.part", isDirectory: false)
    let meta = destDir.appendingPathComponent("src.bin.resume.json", isDirectory: false)

    let cut = 1 * 1024 * 1024 + 7
    try payload.prefix(cut).write(to: part)

    let stSize = payload.count
    let stMTimeNs: Int64 = try {
        var st = stat()
        let rc = src.path.withCString { lstat($0, &st) }
        if rc != 0 { throw CopyError.io(String(cString: strerror(errno))) }
        return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }()

    let metaObj: [String: Any] = [
        "srcSize": UInt64(stSize),
        "srcMTimeNs": stMTimeNs
    ]
    let metaData = try JSONSerialization.data(withJSONObject: metaObj, options: [])
    try metaData.write(to: meta)

    let out = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(chunkBytes: 256 * 1024, force: false, verify: true, quiet: true)
    )

    #expect(out.path == final.path)
    #expect(FileManager.default.fileExists(atPath: final.path))
    #expect(!FileManager.default.fileExists(atPath: part.path))
    #expect(!FileManager.default.fileExists(atPath: meta.path))
    #expect(try Data(contentsOf: final) == payload)
}

@Test
func skipWhenSameSize() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("a.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 1024 * 1024 + 3)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("a.bin", isDirectory: false)
    try payload.write(to: final)

    let out = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(quiet: true)
    )

    #expect(out.path == final.path)
    #expect(try Data(contentsOf: out) == payload)
}

@Test
func resolveSMBMountedPathPrefersMostSpecificMountedSubpath() throws {
    let mountOutput = """
    //debian@192.168.2.110/share on /Volumes/share (smbfs, nodev, nosuid, mounted by hunt)
    //debian@192.168.2.110/share/tem on /Volumes/tem (smbfs, nodev, nosuid, mounted by hunt)
    """

    let entries = SMBResolver.parseSMBMountEntries(from: mountOutput)
    let resolved = try SMBResolver.resolveMountedPath(
        fromSMBURL: "smb://192.168.2.110/share/tem/win10.iso",
        mountEntries: entries,
        fallbackMountedShareDirectory: nil
    )

    #expect(resolved.mountedPath.path == "/Volumes/tem/win10.iso")
    #expect(resolved.shareName == "share")
}

@Test
func resumeFromPartialWithoutMetaFile() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("b.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 3 * 1024 * 1024 + 17)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("b.bin", isDirectory: false)
    let part = destDir.appendingPathComponent("b.bin.part", isDirectory: false)
    let meta = destDir.appendingPathComponent("b.bin.resume.json", isDirectory: false)

    let cut = 1024 * 1024 + 5
    try payload.prefix(cut).write(to: part)
    #expect(!FileManager.default.fileExists(atPath: meta.path))

    let out = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(chunkBytes: 128 * 1024, force: false, verify: true, quiet: true)
    )

    #expect(out.path == final.path)
    #expect(!FileManager.default.fileExists(atPath: part.path))
    #expect(!FileManager.default.fileExists(atPath: meta.path))
    #expect(try Data(contentsOf: final) == payload)
}

@Test
func destinationExistsDifferentSizeWithoutOverwrite() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("c.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 1024 * 1024 + 1)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("c.bin", isDirectory: false)
    try randomData(count: 123).write(to: final)

    do {
        _ = try ResumableCopy().run(
            source: src,
            destination: destDir,
            options: ResumableCopyOptions(chunkBytes: 64 * 1024, overwrite: false, quiet: true)
        )
        #expect(false)
    } catch let e as CopyError {
        #expect(e == .destinationExists(final.path))
    }
}

@Test
func overwriteExistingDestination() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("d.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 1024 * 1024 + 9)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("d.bin", isDirectory: false)
    try randomData(count: 555).write(to: final)

    let out = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(chunkBytes: 64 * 1024, overwrite: true, verify: true, quiet: true)
    )

    #expect(out.path == final.path)
    #expect(try Data(contentsOf: final) == payload)
}

@Test
func sourceChangedBlocksResumeUnlessForce() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("e.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload1 = randomData(count: 1024 * 1024 + 77)
    try payload1.write(to: src)

    let final = destDir.appendingPathComponent("e.bin", isDirectory: false)
    let part = destDir.appendingPathComponent("e.bin.part", isDirectory: false)
    let meta = destDir.appendingPathComponent("e.bin.resume.json", isDirectory: false)

    try payload1.prefix(512 * 1024).write(to: part)

    let stMTimeNs: Int64 = try {
        var st = stat()
        let rc = src.path.withCString { lstat($0, &st) }
        if rc != 0 { throw CopyError.io(String(cString: strerror(errno))) }
        return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }()

    let metaObj: [String: Any] = [
        "srcSize": UInt64(payload1.count),
        "srcMTimeNs": stMTimeNs
    ]
    let metaData = try JSONSerialization.data(withJSONObject: metaObj, options: [])
    try metaData.write(to: meta)

    let payload2 = randomData(count: 1024 * 1024 + 78)
    try payload2.write(to: src)

    do {
        _ = try ResumableCopy().run(
            source: src,
            destination: destDir,
            options: ResumableCopyOptions(chunkBytes: 64 * 1024, force: false, quiet: true)
        )
        #expect(false)
    } catch let e as CopyError {
        #expect(e == .sourceChanged)
    }

    let out = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(chunkBytes: 64 * 1024, force: true, verify: true, quiet: true)
    )

    #expect(out.path == final.path)
    #expect(try Data(contentsOf: final) == payload2)
}

@Test
func partialLargerThanSourceRequiresForce() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("f.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 1024 * 1024 + 12)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("f.bin", isDirectory: false)
    let part = destDir.appendingPathComponent("f.bin.part", isDirectory: false)

    try randomData(count: payload.count + 1).write(to: part)

    do {
        _ = try ResumableCopy().run(
            source: src,
            destination: destDir,
            options: ResumableCopyOptions(chunkBytes: 64 * 1024, force: false, quiet: true)
        )
        #expect(false)
    } catch let e as CopyError {
        #expect(e == .partialLargerThanSource)
    }

    let out = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(chunkBytes: 64 * 1024, force: true, verify: true, quiet: true)
    )

    #expect(out.path == final.path)
    #expect(try Data(contentsOf: final) == payload)
}

@Test
func cancellationKeepsPartAndMetaForResume() async throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let src = base.appendingPathComponent("g.bin", isDirectory: false)
    let destDir = base.appendingPathComponent("dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

    let payload = randomData(count: 3 * 1024 * 1024 + 33)
    try payload.write(to: src)

    let final = destDir.appendingPathComponent("g.bin", isDirectory: false)
    let part = destDir.appendingPathComponent("g.bin.part", isDirectory: false)
    let meta = destDir.appendingPathComponent("g.bin.resume.json", isDirectory: false)
    let flag = CancellationFlag()

    do {
        _ = try ResumableCopy().run(
            source: src,
            destination: destDir,
            options: ResumableCopyOptions(
                chunkBytes: 256 * 1024,
                quiet: true,
                isCancelled: { flag.isCancelled }
            ),
            progress: { copied, _, _ in
                if copied >= 512 * 1024 {
                    flag.isCancelled = true
                }
            }
        )
        #expect(false)
    } catch let e as CopyError {
        #expect(e == .cancelled)
    }

    #expect(FileManager.default.fileExists(atPath: part.path))
    #expect(FileManager.default.fileExists(atPath: meta.path))
    let partSizeAfterCancel = try Data(contentsOf: part).count
    #expect(partSizeAfterCancel > 0)
    #expect(!FileManager.default.fileExists(atPath: final.path))

    let resumed = try ResumableCopy().run(
        source: src,
        destination: destDir,
        options: ResumableCopyOptions(chunkBytes: 256 * 1024, verify: true, quiet: true)
    )

    #expect(resumed.path == final.path)
    #expect(!FileManager.default.fileExists(atPath: part.path))
    #expect(!FileManager.default.fileExists(atPath: meta.path))
    #expect(try Data(contentsOf: final) == payload)
}
