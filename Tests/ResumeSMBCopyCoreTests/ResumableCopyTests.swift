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
