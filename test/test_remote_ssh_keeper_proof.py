"""Initial workspace acceptance must preserve declared bytes, not hide stale state."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/remote-ssh-keeper-proof.py'
spec = importlib.util.spec_from_file_location('ssh_files_proof', SCRIPT)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class InitialWorkspace(unittest.TestCase):
    def snapshot(self, directory, names):
        result = subprocess.check_output(
            [sys.executable, '-c', proof.initial_workspace_inspection(), str(directory), json.dumps(names)],
            text=True)
        snapshot = json.loads(result)
        # The endpoint owner policy is tested below independently of CI's uid.
        snapshot['uid'] = 1000
        return snapshot

    def test_empty_workspace_still_requires_no_undeclared_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof.validate_initial_workspace(self.snapshot(root, []), {})
            (root / 'stale').write_bytes(b'stale')
            with self.assertRaises(proof.smoke.SmokeError):
                proof.validate_initial_workspace(self.snapshot(root, []), {})

    def test_declared_binary_bytes_are_accepted_and_changes_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = 'retained file.bin'
            data = b'preserve\x00\r\nexact bytes'
            (root / name).write_bytes(data)
            manifest = proof.preserved_file_manifest([(name, hashlib.sha256(data).hexdigest())])
            proof.validate_initial_workspace(self.snapshot(root, [name]), manifest)
            (root / name).write_bytes(data + b'changed')
            with self.assertRaises(proof.smoke.SmokeError):
                proof.validate_initial_workspace(self.snapshot(root, [name]), manifest)

    def test_missing_file_directory_and_symlink_are_refused(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            root = Path(directory)
            outside = Path(external) / 'outside'
            outside.write_bytes(b'bytes')
            target = root / 'expected'
            digest = hashlib.sha256(b'bytes').hexdigest()
            manifest = {'expected': digest}
            for kind in ('missing', 'directory', 'symlink'):
                with self.subTest(kind=kind):
                    if kind == 'directory':
                        target.mkdir()
                    elif kind == 'symlink':
                        target.rmdir()
                        target.symlink_to(outside)
                    with self.assertRaises(proof.smoke.SmokeError):
                        proof.validate_initial_workspace(self.snapshot(root, ['expected']), manifest)

    def test_unknown_entries_duplicate_rows_and_root_owner_are_refused(self):
        digest = hashlib.sha256(b'bytes').hexdigest()
        expected = {'kept': digest}
        valid = {'uid': 1000, 'files': ['kept'], 'preserved_files': expected}
        for change in ({'uid': 0}, {'uid': True}, {'files': ['kept', 'kept']},
                       {'files': ['kept', 'stale']}, {'preserved_files': {}}, {'files': 'kept'}):
            with self.subTest(change=change), self.assertRaises(proof.smoke.SmokeError):
                proof.validate_initial_workspace(dict(valid, **change), expected)

    def test_manifest_refuses_escaping_names_duplicates_and_bad_digests(self):
        digest = hashlib.sha256(b'bytes').hexdigest()
        for name in ('', '.', '..', '/tmp/outside', '../outside', 'sub/file', 'bad\x00name'):
            with self.subTest(name=name), self.assertRaises(proof.smoke.SmokeError):
                proof.preserved_file_manifest([(name, digest)])
        for invalid in ('', 'g' * 64, 'A' * 64, digest + '0'):
            with self.subTest(digest=invalid), self.assertRaises(proof.smoke.SmokeError):
                proof.preserved_file_manifest([('kept', invalid)])
        with self.assertRaises(proof.smoke.SmokeError):
            proof.preserved_file_manifest([('kept', digest), ('kept', digest)])


if __name__ == '__main__':
    unittest.main()
