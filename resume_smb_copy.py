#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlparse


class CopyError(Exception):
    pass


class DestinationNotMounted(CopyError):
    pass


@dataclasses.dataclass(frozen=True)
class SourceInfo:
    path: Path
    size: int
    mtime_ns: int


def _now_monotonic() -> float:
    return time.monotonic()


def _readable_bytes(n: float) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(n)
    for unit in units:
        if size < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)} {unit}"
            return f"{size:.2f} {unit}"
        size /= 1024.0
    return f"{size:.2f} TiB"


def _sha256_file(path: Path, chunk_size: int) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def get_source_info(src: Path) -> SourceInfo:
    st = src.stat()
    return SourceInfo(path=src, size=st.st_size, mtime_ns=st.st_mtime_ns)


def resolve_destination(dest: str) -> Path:
    if dest.startswith("smb://"):
        return resolve_smb_url_to_path(dest)
    return Path(dest).expanduser().resolve()


def resolve_smb_url_to_path(url: str) -> Path:
    parsed = urlparse(url)
    if parsed.scheme.lower() != "smb":
        raise ValueError(f"Not an smb URL: {url}")

    host = parsed.hostname
    if not host:
        raise ValueError(f"Missing host in smb URL: {url}")

    path = unquote(parsed.path or "").lstrip("/")
    if not path:
        raise ValueError(f"Missing share name in smb URL: {url}")

    parts = [p for p in path.split("/") if p]
    share = parts[0]
    remainder = parts[1:]
    mount_base = Path("/Volumes") / share
    if not mount_base.exists():
        raise DestinationNotMounted(
            f"SMB share not mounted. Expected mount point: {mount_base}"
        )
    return (mount_base.joinpath(*remainder)).resolve()


def mount_smb_interactive(url: str, timeout_seconds: int) -> Path:
    subprocess.run(["open", url], check=False)
    deadline = _now_monotonic() + timeout_seconds
    last_error: Optional[Exception] = None
    while _now_monotonic() < deadline:
        try:
            return resolve_smb_url_to_path(url)
        except DestinationNotMounted as e:
            last_error = e
            time.sleep(0.5)
    raise DestinationNotMounted(str(last_error) if last_error else "SMB mount timeout")


def _load_resume_meta(meta_path: Path) -> dict:
    if not meta_path.exists():
        return {}
    try:
        return json.loads(meta_path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _write_resume_meta(meta_path: Path, meta: dict) -> None:
    tmp = meta_path.with_name(meta_path.name + ".tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, meta_path)


def resumable_copy(
    *,
    src: Path,
    dest: Path,
    chunk_size: int,
    overwrite: bool,
    force: bool,
    verify: bool,
    quiet: bool,
) -> Path:
    src = src.expanduser().resolve()
    if not src.exists() or not src.is_file():
        raise CopyError(f"Source file not found: {src}")

    src_info = get_source_info(src)

    if dest.exists() and dest.is_dir():
        final_path = dest / src.name
    else:
        final_path = dest
        if str(dest).endswith(os.sep):
            final_path = dest / src.name

    final_dir = final_path.parent
    final_dir.mkdir(parents=True, exist_ok=True)

    part_path = final_dir / (final_path.name + ".part")
    meta_path = final_dir / (final_path.name + ".resume.json")

    if final_path.exists():
        if overwrite:
            final_path.unlink()
        else:
            if final_path.stat().st_size == src_info.size:
                if not quiet:
                    print(f"Already exists (same size), skipping: {final_path}")
                return final_path
            raise CopyError(
                f"Destination exists. Use --overwrite or choose another name: {final_path}"
            )

    meta = _load_resume_meta(meta_path)
    expected_size = meta.get("src_size")
    expected_mtime_ns = meta.get("src_mtime_ns")
    if meta and not force:
        if expected_size not in (None, src_info.size) or expected_mtime_ns not in (
            None,
            src_info.mtime_ns,
        ):
            raise CopyError(
                "Source file changed since last attempt. Use --force to resume anyway."
            )

    resume_offset = part_path.stat().st_size if part_path.exists() else 0
    if resume_offset > src_info.size:
        if not force:
            raise CopyError(
                "Partial file larger than source. Use --force to overwrite partial."
            )
        part_path.unlink(missing_ok=True)
        resume_offset = 0

    if not quiet:
        if resume_offset:
            print(
                f"Resuming from {_readable_bytes(resume_offset)} / {_readable_bytes(src_info.size)}"
            )
        else:
            print(f"Starting upload: {_readable_bytes(src_info.size)}")

    _write_resume_meta(
        meta_path,
        {
            "src_path": str(src),
            "src_size": src_info.size,
            "src_mtime_ns": src_info.mtime_ns,
            "final_path": str(final_path),
            "created_at": time.time(),
        },
    )

    bytes_copied = resume_offset
    last_print_t = _now_monotonic()
    last_print_bytes = bytes_copied

    with src.open("rb") as fsrc:
        fsrc.seek(resume_offset)
        with part_path.open("ab") as fdst:
            while True:
                chunk = fsrc.read(chunk_size)
                if not chunk:
                    break
                fdst.write(chunk)
                bytes_copied += len(chunk)

                if not quiet:
                    now = _now_monotonic()
                    if now - last_print_t >= 1.0:
                        delta_b = bytes_copied - last_print_bytes
                        speed = delta_b / (now - last_print_t) if now > last_print_t else 0.0
                        pct = (bytes_copied / src_info.size * 100.0) if src_info.size else 100.0
                        print(
                            f"{pct:6.2f}%  {_readable_bytes(bytes_copied)} / {_readable_bytes(src_info.size)}"
                            f"  {_readable_bytes(speed)}/s",
                            file=sys.stderr,
                        )
                        last_print_t = now
                        last_print_bytes = bytes_copied

            fdst.flush()
            os.fsync(fdst.fileno())

    if part_path.stat().st_size != src_info.size:
        raise CopyError(
            f"Incomplete transfer: got {part_path.stat().st_size}, expected {src_info.size}"
        )

    if verify:
        if not quiet:
            print("Verifying sha256...", file=sys.stderr)
        src_hash = _sha256_file(src, chunk_size=chunk_size)
        dst_hash = _sha256_file(part_path, chunk_size=chunk_size)
        if src_hash != dst_hash:
            raise CopyError("Verification failed (sha256 mismatch).")

    if final_path.exists() and overwrite:
        final_path.unlink()
    os.replace(part_path, final_path)
    meta_path.unlink(missing_ok=True)

    if not quiet:
        print(f"Done: {final_path}")
    return final_path


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="resume_smb_copy",
        description="Resumable large-file copy to an SMB share (macOS -> Windows/Linux).",
    )
    p.add_argument("src", help="Source file path on macOS")
    p.add_argument(
        "dest",
        help="Destination directory/file path, or smb://HOST/SHARE[/subdir]",
    )
    p.add_argument(
        "--chunk-mib",
        type=int,
        default=8,
        help="Read/write chunk size in MiB (default: 8)",
    )
    p.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite destination if final file exists",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Force resume even if source changed or partial seems inconsistent",
    )
    p.add_argument(
        "--verify",
        action="store_true",
        help="Verify sha256 after transfer (slower)",
    )
    p.add_argument(
        "--quiet",
        action="store_true",
        help="Reduce output",
    )
    p.add_argument(
        "--mount-timeout",
        type=int,
        default=60,
        help="When dest is smb://, wait up to N seconds for Finder mount (default: 60)",
    )
    return p


def main(argv: list[str]) -> int:
    args = build_arg_parser().parse_args(argv)
    src = Path(args.src)

    dest_str: str = args.dest
    try:
        dest = resolve_destination(dest_str)
    except DestinationNotMounted:
        if dest_str.startswith("smb://"):
            dest = mount_smb_interactive(dest_str, timeout_seconds=args.mount_timeout)
        else:
            raise

    try:
        resumable_copy(
            src=src,
            dest=dest,
            chunk_size=max(1, args.chunk_mib) * 1024 * 1024,
            overwrite=args.overwrite,
            force=args.force,
            verify=args.verify,
            quiet=args.quiet,
        )
        return 0
    except CopyError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
