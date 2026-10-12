"""Executable offline-tool checks; separate from the unexecuted OCaml consumer suite."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/maintenance/recover-memory-admission.py"
spec = importlib.util.spec_from_file_location("recovery", SCRIPT)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


def encoded(value):
    return (json.dumps(value, indent=2) + "\n").encode()


class Recovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backup = self.root / "backup"
        self.current = self.root / "current"
        self.backup.mkdir(); self.current.mkdir()
        self.snapshot = {"revision": 1, "updated_at": 200.0,
                         "source": {"kind": "librarian", "trace_id": "synthetic"},
                         "facts": [], "change": {"added": [], "removed": [], "retained": 0, "invalidated": []}}
        self.snapshot_raw = encoded(self.snapshot)
        self.sha = hashlib.sha256(self.snapshot_raw).hexdigest()
        self.receipt = {"receipts": [{"state": "committed", "explicit_write_range_id": {
            "receipt_scope": "synthetic-generation", "after_sequence": 0,
            "through_sequence": 1, "input_sha256": "a" * 64},
            "snapshot_revision": 1, "snapshot_sha256": self.sha}]}
        self.queue = {"generation": "synthetic-generation", "acknowledged": 1, "pending": []}
        self.names = ["keeper" + suffix for suffix in recovery.SUFFIXES]
        for directory in (self.backup, self.current):
            for name, raw in zip(self.names, (self.snapshot_raw, encoded(self.receipt), encoded(self.queue))):
                (directory / name).write_bytes(raw)
            (directory / "keeper.memory-journal.jsonl").write_bytes(b'{"outcome":"committed","revision":1}\n')
            (directory / "untouched").write_bytes(b'other keeper data')
        self.queue["pending"] = [{"sequence": 2, "request_id": "pending-two", "fact": {"claim": "accepted tail"}}]
        (self.current / self.names[2]).write_bytes(encoded(self.queue))
        (self.current / self.names[1]).unlink()

    def prepare(self, format_name=recovery.FORMAT):
        before = recovery.inventory(self.current)
        saved = recovery.inventory(self.backup)
        manifest = recovery.prepare(self.current, self.backup, self.root / "out", "keeper", self.sha, format_name)
        self.assertEqual(before, recovery.inventory(self.current))
        self.assertEqual(saved, recovery.inventory(self.backup))
        repaired = recovery.inventory(self.root / "out/repaired")
        self.assertEqual(repaired[self.names[0]], self.snapshot_raw)
        self.assertEqual(repaired[self.names[1]], encoded(self.receipt))
        self.assertEqual(repaired[self.names[2]], before[self.names[2]])
        self.assertEqual(repaired["untouched"], before["untouched"])
        self.assertEqual(set(manifest["replacement_paths"]), set(self.names[:2]))
        return manifest

    def test_missing_receipt_recovers_without_replaying_or_changing_pending(self):
        self.prepare()

    def test_missing_snapshot_and_receipt_recovers_exact_bytes(self):
        (self.current / self.names[0]).unlink()
        self.prepare()

    def test_corrupt_snapshot_recovers_only_from_attested_exact_backup(self):
        (self.current / self.names[0]).write_bytes(b'{corruption')
        self.prepare()

    def test_new_commit_evidence_forbids_rollback(self):
        (self.current / "keeper.memory-journal.jsonl").write_bytes(b'{"outcome":"committed","revision":2}\n')
        with self.assertRaises(ValueError): self.prepare()

    def test_moved_acknowledgement_forbids_rollback(self):
        self.queue.update(acknowledged=2, pending=[])
        (self.current / self.names[2]).write_bytes(encoded(self.queue))
        with self.assertRaises(ValueError): self.prepare()

    def test_new_generation_forbids_rollback(self):
        self.queue["generation"] = "replacement-queue"
        (self.current / self.names[2]).write_bytes(encoded(self.queue))
        with self.assertRaises(ValueError): self.prepare()

    def test_other_json_snapshot_is_not_assumed_corrupt(self):
        (self.current / self.names[0]).write_bytes(encoded(dict(self.snapshot, revision=2)))
        with self.assertRaises(ValueError): self.prepare()

    def test_mismatched_receipt_snapshot_rejected(self):
        self.receipt["receipts"][0]["snapshot_sha256"] = "b" * 64
        (self.backup / self.names[1]).write_bytes(encoded(self.receipt))
        with self.assertRaises(ValueError): self.prepare()

    def test_unsettled_backup_receipt_rejected(self):
        self.receipt["receipts"][0]["state"] = "prepared"
        (self.backup / self.names[1]).write_bytes(encoded(self.receipt))
        with self.assertRaises(ValueError): self.prepare()

    def test_changed_pending_prefix_rejected(self):
        old = dict(self.queue, pending=[dict(self.queue["pending"][0], request_id="other")])
        (self.backup / self.names[2]).write_bytes(encoded(old))
        with self.assertRaises(ValueError): self.prepare()

    def test_sparse_successor_schema_refused(self):
        self.receipt["receipts"][0]["explicit_candidate_id"] = self.receipt["receipts"][0].pop("explicit_write_range_id")
        (self.backup / self.names[1]).write_bytes(encoded(self.receipt))
        with self.assertRaises(ValueError): self.prepare()

    def test_different_surviving_receipt_is_not_erased(self):
        (self.current / self.names[1]).write_bytes(encoded({"receipts": []}))
        with self.assertRaises(ValueError): self.prepare()

    def test_absent_journal_cannot_establish_a_recovery_cut(self):
        (self.current / "keeper.memory-journal.jsonl").unlink()
        (self.backup / "keeper.memory-journal.jsonl").unlink()
        with self.assertRaises(ValueError): self.prepare()

    def test_ambiguous_generation_receipts_refused(self):
        self.receipt["receipts"].append(self.receipt["receipts"][0])
        (self.backup / self.names[1]).write_bytes(encoded(self.receipt))
        with self.assertRaises(ValueError): self.prepare()

    def test_explicit_unknown_format_refused(self):
        with self.assertRaises(ValueError): self.prepare("future-format")

    def test_symlink_refused(self):
        (self.current / "unsafe").symlink_to(self.backup / self.names[0])
        with self.assertRaises(ValueError): self.prepare()

    def test_attestation_mismatch_refused(self):
        self.sha = "c" * 64
        with self.assertRaises(ValueError): self.prepare()


if __name__ == "__main__":
    unittest.main()
