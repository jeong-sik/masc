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


class EarlierManifestTest(unittest.TestCase):
    """A lost snapshot taken again from a store that still holds some of its manifest's records."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.live, self.base, self.manifest = root / "live", root / "snapshot", root / "manifest.json"
        self.kept, self.later = record("d1"), record("d5")
        write(self.live, "scope-a", "r1.json", self.kept)
        write(self.live, "scope-a", "r5.json", self.later)

    def earlier(self, pins: dict[str, bytes]) -> E.EarlierManifest:
        """The manifest of an earlier snapshot that held the records `pins`, written to a file and read back."""
        items = [{"digest": d, "sha256": hashlib.sha256(raw).hexdigest()} for d, raw in sorted(pins.items())]
        self.manifest.write_text(json.dumps({"schema": E.MANIFEST_SCHEMA, "items": items}), encoding="utf-8")
        return E.earlier_manifest(self.manifest)

    def copies(self) -> list[str]:
        return [r.digest for r in E.answered_admissions(self.base)]

    def test_takes_the_listed_records_the_store_still_holds_and_names_the_ones_gone(self) -> None:
        earlier = self.earlier({"d1": self.kept, "d0": record("d0"), "d9": record("d9")})
        records = E.snapshot(self.live, self.base, earlier)
        self.assertEqual(([r.digest for r in records], self.copies()), (["d1"], ["d1"]))
        manifest = E.manifest_of(records, "2026-11-11T00:00:00Z", earlier)
        self.assertEqual(manifest["of"], {"manifest_sha256": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
                                          "items": 3, "gone": ["d0", "d9"]})
        self.assertEqual(manifest["items"], [{"digest": "d1", "sha256": hashlib.sha256(self.kept).hexdigest()}])
        self.assertEqual(manifest["selection"], E.SELECTION_OF_EARLIER)

    def test_the_new_manifest_reads_back_as_the_records_left(self) -> None:
        earlier = self.earlier({"d1": self.kept, "d9": record("d9")})
        manifest = E.manifest_of(E.snapshot(self.live, self.base, earlier), "2026-11-11T00:00:00Z", earlier)
        self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        self.assertEqual([r.digest for r in E.records_for(self.manifest, self.base)], ["d1"])

    def test_a_listed_record_with_other_bytes_stops_it_before_anything_is_written(self) -> None:
        # r1.json is read first and matches, so a snapshot that copied as it read would leave d1 behind.
        earlier = self.earlier({"d1": self.kept, "d5": self.later + b" "})
        with self.assertRaises(SystemExit):
            E.snapshot(self.live, self.base, earlier)
        self.assertEqual(self.copies(), [])

    def test_a_manifest_without_an_earlier_one_names_none(self) -> None:
        manifest = E.manifest_of(E.snapshot(self.live, self.base), "2026-11-11T00:00:00Z")
        self.assertNotIn("of", manifest)
        self.assertEqual((manifest["selection"], self.copies()), (E.SELECTION_ANSWERED, ["d1", "d5"]))

    def test_a_file_that_is_not_a_manifest_is_refused(self) -> None:
        bodies: list[dict[str, object]] = [{"schema": "another", "items": []},
                                           {"schema": E.MANIFEST_SCHEMA, "items": [{"digest": "d1"}]}]
        for body in bodies:
            with self.subTest(body=body):
                self.manifest.write_text(json.dumps(body), encoding="utf-8")
                with self.assertRaises(SystemExit):
                    E.earlier_manifest(self.manifest)


if __name__ == "__main__":
    unittest.main()
