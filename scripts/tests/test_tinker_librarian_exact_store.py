# pyright: strict
"""Tests for scripts/tinker/librarian/exact_store.py: the E-real snapshot.

Synthetic records only, written into temporary folders.
"""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import exact_store as E


def record(digest: str, *, declaration: str = E.DECLARATION, status: str = "answered") -> bytes:
    request: dict[str, object] = {"output": E.OUTPUT, "schema": {"type": "object"},
                                  "messages": [{"role": "user", "text": f"prompt of {digest}"}]}
    final: dict[str, object] = {"status": status, "output": {"judgments": []}, "slot": "glm-coding.glm-5.3-flash"}
    return json.dumps({"declaration_id": declaration, "digest": digest, "request": request,
                       "final": final}).encode()


def write(base: Path, scope: str, name: str, raw: bytes) -> Path:
    path = E.store_dir(base) / scope / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)
    return path


class SnapshotTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.live, self.base = root / "live", root / "snapshot"
        self.answered = {"d1": record("d1"), "d2": record("d2")}
        write(self.live, "scope-a", "r1.json", self.answered["d1"])
        write(self.live, "scope-a", "r2.json", record("d3", status="refused"))
        write(self.live, "scope-b", "r3.json", record("d4", declaration="another-declaration"))
        write(self.live, "scope-b", "r4.json", self.answered["d2"])

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def live_files(self) -> dict[str, bytes]:
        store = E.store_dir(self.live)
        return {str(p.relative_to(store)): p.read_bytes() for p in sorted(store.glob("*/*.json"))}

    def test_copies_each_answered_admission_byte_for_byte_and_nothing_else(self) -> None:
        records = E.snapshot(self.live, self.base)
        self.assertEqual([r.digest for r in records], ["d1", "d2"])
        store = E.store_dir(self.base)
        copies = {str(p.relative_to(store)): p.read_bytes() for p in sorted(store.glob("*/*.json"))}
        self.assertEqual(copies, {"scope-a/r1.json": self.answered["d1"], "scope-b/r4.json": self.answered["d2"]})
        manifest = E.manifest_of(records, "2026-11-10T00:00:00Z")
        self.assertEqual(manifest["items"], [{"digest": d, "sha256": hashlib.sha256(self.answered[d]).hexdigest()}
                                             for d in ("d1", "d2")])

    def test_leaves_the_live_store_as_it_was(self) -> None:
        before = self.live_files()
        E.snapshot(self.live, self.base)
        self.assertEqual(self.live_files(), before)

    def test_is_readable_by_its_owner_alone_even_when_the_folder_existed(self) -> None:
        self.base.mkdir()
        self.base.chmod(0o755)
        E.snapshot(self.live, self.base)
        self.assertEqual(self.base.stat().st_mode & 0o077, 0)

    def test_refuses_a_store_that_already_holds_records(self) -> None:
        write(self.base, "scope-a", "old.json", record("d0"))
        with self.assertRaises(SystemExit):
            E.snapshot(self.live, self.base)
        self.assertEqual([r.digest for r in E.answered_admissions(self.base)], ["d0"])


if __name__ == "__main__":
    unittest.main()
