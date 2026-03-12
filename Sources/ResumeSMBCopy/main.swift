import Foundation
import ResumeSMBCopyCore

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

func parseArgs(_ argv: [String]) -> Args? {
    var positional: [String] = []
    var args = Args(src: "", dest: "")

    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a == "--chunk-mib" {
            guard i + 1 < argv.count, let n = Int(argv[i + 1]) else { return nil }
            args.chunkMiB = n
            i += 2
            continue
        }
        if a == "--mount-timeout" {
            guard i + 1 < argv.count, let n = Int(argv[i + 1]) else { return nil }
            args.mountTimeout = n
            i += 2
            continue
        }
        if a == "--overwrite" { args.overwrite = true; i += 1; continue }
        if a == "--force" { args.force = true; i += 1; continue }
        if a == "--verify" { args.verify = true; i += 1; continue }
        if a == "--quiet" { args.quiet = true; i += 1; continue }
        if a == "-h" || a == "--help" { return nil }

        positional.append(a)
        i += 1
    }

    guard positional.count == 2 else { return nil }
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

func main() -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let a = parseArgs(argv) else {
        printUsage()
        return 2
    }

    let srcURL = URL(fileURLWithPath: a.src).standardizedFileURL

    let destURL: URL
    if a.dest.lowercased().hasPrefix("smb://") {
        do {
            destURL = try SMBResolver.resolveMountedPath(fromSMBURL: a.dest).mountedPath
        } catch {
            do {
                destURL = try SMBResolver.waitForMount(smbURLString: a.dest, timeoutSeconds: a.mountTimeout)
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                return 2
            }
        }
    } else {
        destURL = URL(fileURLWithPath: a.dest).standardizedFileURL
    }

    let options = ResumableCopyOptions(
        chunkBytes: max(1, a.chunkMiB) * 1024 * 1024,
        overwrite: a.overwrite,
        force: a.force,
        verify: a.verify,
        quiet: a.quiet
    )

    do {
        let copier = ResumableCopy()
        let out = try copier.run(source: srcURL, destination: destURL, options: options) { copied, total, bps in
            let pct = total > 0 ? (Double(copied) / Double(total) * 100.0) : 100.0
            let line = String(
                format: "%6.2f%%  %@ / %@  %@/s\n",
                pct,
                readableBytes(Double(copied)),
                readableBytes(Double(total)),
                readableBytes(bps)
            )
            fputs(line, stderr)
        }
        if !a.quiet {
            print("Done: \(out.path)")
        }
        return 0
    } catch let e as CopyError {
        fputs("Error: \(e.localizedDescription)\n", stderr)
        return 2
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return 2
    }
}

exit(main())
