"""Actual connection store edges with process-local credential records only."""
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
        self.connection_value = {"phase": "disconnected", "configuration_id": "a" * 64}

    def write(self, store, value):
        with store.locked() as root:
            store.write(root, value)

    def read(self, store):
        with store.locked() as root:
            return store.read(root)

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


if __name__ == "__main__":
    unittest.main()
