"""Commit/failure boundaries for the actual PrivateStore, fixture secrets only."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
import oauth
from onepassword_store_fixture import MemoryRecords, active_raw, active_slot


class ProtectedStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "private"
        self.records = MemoryRecords(self.temporary.name)
        self.store = oauth.PrivateStore(self.directory, records=self.records, provision=True)
        self.original = {"phase": "disconnected", "configuration_id": "a" * 64}
        self.next = {"phase": "authorizing", "configuration_id": "a" * 64,
                     "connection_id": "0e250ad7-e876-4e74-9145-1a0d5aa3a15c",
                     "state": "STATE_MARKER", "verifier": "VERIFIER_MARKER"}

    def write(self, value):
        with self.store.locked() as root:
            self.store.write(root, value)

    def read(self):
        with self.store.locked() as root:
            return self.store.read(root)

    def test_restart_reads_protected_record_without_plaintext_on_disk(self):
        self.write(self.next)
        restart = oauth.PrivateStore(self.directory, records=self.records)
        with restart.locked() as root:
            self.assertEqual(restart.read(root), self.next)
        for path in self.directory.iterdir():
            self.assertNotIn(b"MARKER", path.read_bytes())
        self.assertFalse((self.directory / "connection.json").exists())

    def test_declined_callback_schema_is_closed_and_invalid_write_keeps_active_authority(self):
        self.write(self.next)
        before = active_raw(self.store)
        receipt = {"kind": "declined", "state": "STATE_MARKER",
                   "connection_id": self.next["connection_id"]}
        for changed in [{"kind": "captured"}, {"state": ""}, {"connection_id": "not-a-uuid"},
                        {"unknown": "extra"}, {"connection_id": None}]:
            with self.subTest(changed=changed):
                with self.assertRaises(oauth.ConnectionError):
                    self.write({**self.original, "declined_callback": {**receipt, **changed}})
                self.assertEqual(active_raw(self.store), before)
        with self.assertRaises(oauth.ConnectionError):
            self.write({**self.next, "declined_callback": receipt})
        self.assertEqual(active_raw(self.store), before)
        declined = {**self.original, "declined_callback": receipt}
        self.write(declined)
        self.assertEqual(self.read(), declined)

    def test_delete_then_failed_add_cannot_erase_active_slot(self):
        self.write(self.next)
        before = active_raw(self.store)
        active = active_slot(self.store)

        def fail(slot, value):
            self.assertNotEqual(slot, active)
            self.records.values.pop((self.records.identity, slot), None)
            raise oauth.ConnectionError("protected_store_unavailable")

        with patch.object(self.records, "write", side_effect=fail):
            with self.assertRaises(oauth.ConnectionError):
                self.write(self.original)
        self.assertEqual(active_slot(self.store), active)
        self.assertEqual(active_raw(self.store), before)
        self.assertEqual(self.read(), self.next)

    def test_readback_mismatch_and_pointer_publish_failure_preserve_active(self):
        self.write(self.next)
        active = active_slot(self.store)
        with patch.object(self.records, "write", return_value=None):
            with self.assertRaisesRegex(oauth.ConnectionError, "write_unconfirmed"):
                self.write(self.original)
        self.assertEqual(active_slot(self.store), active)
        with patch.object(oauth.os, "replace", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                self.write(self.original)
        self.assertEqual(self.read(), self.next)
        self.assertFalse(list(self.directory.glob(".connection-*")))

    def test_uncertain_parent_fsync_has_a_recoverable_committed_reference(self):
        self.write(self.next)
        real_fsync = os.fsync

        def fail_directory(fd):
            if os.fstat(fd).st_ino == self.directory.stat().st_ino:
                raise OSError("fixture_unknown_commit")
            return real_fsync(fd)

        with patch.object(oauth.os, "fsync", side_effect=fail_directory):
            with self.assertRaises(OSError):
                self.write(self.original)
        # Rename may have committed even though durability acknowledgement was
        # lost. Recovery follows the reference and never guesses/replays OAuth.
        self.assertEqual(self.read(), self.original)

    def test_unavailable_is_not_absent_and_missing_active_is_not_disconnected(self):
        with patch.object(self.records, "read", side_effect=oauth.ConnectionError("protected_store_unavailable")):
            with self.assertRaisesRegex(oauth.ConnectionError, "protected_store_unavailable"):
                self.read()
        self.assertIsNone(self.read())
        self.write(self.next)
        self.records.values.pop((self.records.identity, active_slot(self.store)))
        with self.assertRaisesRegex(oauth.ConnectionError, "protected_connection_missing"):
            self.read()

    def test_legacy_plaintext_is_preserved_and_refused(self):
        legacy = self.directory / "connection.json"
        legacy.write_text("OLD_TOKEN_MARKER")
        legacy.chmod(0o600)
        with self.assertRaisesRegex(oauth.ConnectionError, "plaintext_connection_reconciliation_required"):
            self.read()
        with self.assertRaises(oauth.ConnectionError):
            self.write(self.original)
        self.assertEqual(legacy.read_text(), "OLD_TOKEN_MARKER")
        self.assertFalse((self.directory / "connection.reference.json").exists())

    def test_reference_schema_refuses_duplicate_unknown_and_boolean_slots(self):
        reference = self.directory / "connection.reference.json"
        for raw in ['{"schema":"masc.1password.protected.v1","slot":0,"slot":1}',
                    '{"schema":"masc.1password.protected.v1","slot":true}',
                    '{"schema":"masc.1password.protected.v1","slot":0,"token":"secret"}']:
            reference.write_text(raw)
            reference.chmod(0o600)
            with self.assertRaises(oauth.ConnectionError):
                self.read()


if __name__ == "__main__":
    unittest.main()
