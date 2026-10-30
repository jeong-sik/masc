"""Actual connection/Journal edges with process-local credential records only."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
import oauth
from login import Journal
from onepassword_store_fixture import MemoryRecords


class StoreDomainTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "private"
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.connection = oauth.PrivateStore(self.directory, provision=True)
        self.journal = Journal(self.directory)
        self.connection_value = {"phase": "disconnected", "configuration_id": "a" * 64}
        self.journal_value = {"version": 2, "operations": []}

    def write(self, store, value):
        with store.locked() as root:
            store.write(root, value)

    def read(self, store):
        with store.locked() as root:
            return store.read(root)

    def test_same_directory_domains_have_independent_references_payloads_and_restart(self):
        self.assertNotEqual(self.connection.records.identity, self.journal.records.identity)
        self.write(self.connection, self.connection_value)
        self.write(self.journal, self.journal_value)
        self.assertEqual(self.read(oauth.PrivateStore(self.directory)), self.connection_value)
        self.assertEqual(self.read(Journal(self.directory)), self.journal_value)
        connection = json.loads((self.directory / "connection.reference.json").read_text())
        journal = json.loads((self.directory / "operations.reference.json").read_text())
        self.assertNotEqual(connection["schema"], journal["schema"])
        self.assertEqual(set(connection), {"schema", "slot"})
        self.assertEqual(set(journal), {"schema", "slot"})
        self.assertFalse((self.directory / "connection.json").exists())
        self.assertFalse((self.directory / "operations.json").exists())

    def test_each_domain_validates_its_own_payload_before_writing(self):
        for store, wrong in [(self.connection, self.journal_value), (self.journal, self.connection_value)]:
            with self.subTest(domain=store._reference_schema):
                with self.assertRaises(oauth.ConnectionError):
                    self.write(store, wrong)
                self.assertFalse((self.directory / store._reference_name).exists())

    def test_reference_domain_swap_is_refused_without_repair(self):
        self.write(self.connection, self.connection_value)
        self.write(self.journal, self.journal_value)
        path = self.directory / "operations.reference.json"
        wrong = (self.directory / "connection.reference.json").read_bytes()
        path.write_bytes(wrong)
        with self.assertRaisesRegex(oauth.ConnectionError, "invalid_connection_reference"):
            self.read(self.journal)
        self.assertEqual(path.read_bytes(), wrong)
        self.assertEqual(self.read(self.connection), self.connection_value)

    def test_existing_reference_with_a_changed_namespace_is_unavailable_not_empty(self):
        # The injected old service identity models a pre-domain deployment;
        # both writes/reads and the commit reference use production functions.
        old_identity = hashlib.sha256(json.dumps(
            [os.getuid(), str(self.directory.resolve()), *self.connection.identity],
            separators=(",", ":")).encode()).hexdigest()
        previous = oauth.PrivateStore(self.directory, records=MemoryRecords(old_identity))
        self.write(previous, self.connection_value)
        before_files = {path.name: path.read_bytes() for path in self.directory.iterdir()}
        before_records = dict(MemoryRecords.values)
        with self.assertRaisesRegex(oauth.ConnectionError, "protected_connection_missing"):
            self.read(oauth.PrivateStore(self.directory))
        self.assertEqual({path.name: path.read_bytes() for path in self.directory.iterdir()}, before_files)
        self.assertEqual(MemoryRecords.values, before_records)
        self.assertEqual(self.read(previous), self.connection_value)

    def test_legacy_journal_payload_is_preserved_and_not_reclassified_as_absent(self):
        path = self.directory / "operations.json"
        raw = json.dumps(self.journal_value)
        path.write_text(raw)
        path.chmod(0o600)
        with self.assertRaisesRegex(oauth.ConnectionError, "plaintext_connection_reconciliation_required"):
            self.read(self.journal)
        self.assertEqual(path.read_text(), raw)
        self.assertFalse((self.directory / "operations.reference.json").exists())


if __name__ == "__main__":
    unittest.main()
