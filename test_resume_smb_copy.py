import hashlib
import os
import tempfile
import unittest
from pathlib import Path

import resume_smb_copy


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            b = f.read(1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


class ResumableCopyTests(unittest.TestCase):
    def test_resume_from_partial(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            src = base / "src.bin"
            dest_dir = base / "dest"
            dest_dir.mkdir()

            payload = os.urandom(5 * 1024 * 1024 + 123)
            src.write_bytes(payload)

            final_path = dest_dir / src.name
            part_path = dest_dir / (final_path.name + ".part")
            meta_path = dest_dir / (final_path.name + ".resume.json")

            cut = 2 * 1024 * 1024 + 7
            part_path.write_bytes(payload[:cut])
            meta_path.write_text(
                '{"src_size": %d, "src_mtime_ns": %d}'
                % (src.stat().st_size, src.stat().st_mtime_ns),
                encoding="utf-8",
            )

            out = resume_smb_copy.resumable_copy(
                src=src,
                dest=dest_dir,
                chunk_size=512 * 1024,
                overwrite=False,
                force=False,
                verify=True,
                quiet=True,
            )

            self.assertEqual(out, final_path)
            self.assertTrue(final_path.exists())
            self.assertFalse(part_path.exists())
            self.assertFalse(meta_path.exists())
            self.assertEqual(_sha256(src), _sha256(final_path))

    def test_skip_when_same_size(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            src = base / "a.bin"
            dest_dir = base / "dest"
            dest_dir.mkdir()

            payload = os.urandom(1024 * 1024 + 3)
            src.write_bytes(payload)

            final_path = dest_dir / src.name
            final_path.write_bytes(payload)

            out = resume_smb_copy.resumable_copy(
                src=src,
                dest=dest_dir,
                chunk_size=256 * 1024,
                overwrite=False,
                force=False,
                verify=False,
                quiet=True,
            )
            self.assertEqual(out, final_path)
            self.assertEqual(_sha256(src), _sha256(final_path))

