"""Adversarial upstream archive tests for the regular-only macOS payload."""
import importlib.util
import io
import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/package-macos-runtime.py'
spec = importlib.util.spec_from_file_location('runtime_package', SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PythonArchive(unittest.TestCase):
    def exercise(self, entries):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        archive = root / 'upstream.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            for name, content, link in entries:
                info = tarfile.TarInfo(name)
                info.mode = 0o755
                if link is not None:
                    info.type, info.linkname = tarfile.SYMTYPE, link
                else:
                    info.size = len(content)
                output.addfile(info, io.BytesIO(content) if link is None else None)
        package.unpack_python(archive, root / 'payload')
        return root / 'payload'

    def test_internal_interpreter_alias_is_materialized(self):
        root = self.exercise([('python/bin/python3.13', b'python bytes', None),
                              ('python/bin/python3', b'', 'python3.13')])
        alias = root / 'python/bin/python3'
        self.assertFalse(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), b'python bytes')
        self.assertEqual(alias.stat().st_mode & 0o777, 0o755)

    def test_absolute_traversal_and_escaping_links_are_rejected(self):
        for entries in ([('/outside', b'bad', None)],
                        [('python/../../outside', b'bad', None)],
                        [('python/bin/python3', b'', '/usr/bin/python3')],
                        [('python/bin/python3', b'', '../../../outside')],
                        [('python/bin/python3', b'', 'python3')]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.exercise(entries)

    def test_duplicate_members_are_rejected(self):
        with self.assertRaises(ValueError):
            self.exercise([('python/bin/python3', b'one', None), ('python/bin/python3', b'two', None)])


class PinnedDownload(unittest.TestCase):
    def exercise(self, payload, reaches_extraction):
        expected = b'reviewed Python archive'
        url = 'https://github.com/astral-sh/python-build-standalone/releases/download/pinned/python.tar.gz'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / 'lock.json'
            lock.write_text(json.dumps({'platforms': {'macos-arm64': {
                'browser_download_url': url, 'size': len(expected),
                'digest': 'sha256:' + hashlib.sha256(expected).hexdigest()}}}))
            with patch.object(package, 'fetch', return_value=payload) as fetch, patch.object(
                    package, 'unpack_python', side_effect=RuntimeError('verified bytes reached extraction')) as unpack:
                if reaches_extraction:
                    with self.assertRaisesRegex(RuntimeError, 'verified bytes reached extraction'):
                        package.package(root / 'dist', root / 'stage', 'macos-arm64', 'a' * 40, lock)
                    unpack.assert_called_once()
                else:
                    with self.assertRaisesRegex(ValueError, 'checksum differs from pin'):
                        package.package(root / 'dist', root / 'stage', 'macos-arm64', 'a' * 40, lock)
                    unpack.assert_not_called()
                fetch.assert_called_once_with(url)

    def test_verified_payload_uses_only_pinned_download(self):
        self.exercise(b'reviewed Python archive', True)

    def test_equal_size_tampering_is_rejected_before_extraction(self):
        self.exercise(b'altered! Python archive', False)

    def test_truncated_payload_is_rejected_before_extraction(self):
        self.exercise(b'reviewed Python', False)


class BinaryPublication(unittest.TestCase):
    def test_readonly_destination_is_replaced_with_staged_bytes_and_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root / 'staged', root / 'masc-macos-arm64'
            source.write_bytes(b'verified staged executable')
            source.chmod(0o555)
            destination.write_bytes(b'old executable')
            destination.chmod(0o555)
            old_inode = destination.stat().st_ino
            package.publish_binary(source, destination)
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o555)
            self.assertNotEqual(destination.stat().st_ino, old_inode)
            self.assertEqual({p.name for p in root.iterdir()}, {'staged', 'masc-macos-arm64'})

    def test_destination_symlink_target_is_never_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target, destination = root / 'staged', root / 'untouched', root / 'masc-macos-arm64'
            source.write_bytes(b'verified staged executable')
            source.chmod(0o755)
            target.write_bytes(b'external old executable')
            target.chmod(0o444)
            destination.symlink_to(target)
            package.publish_binary(source, destination)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
            self.assertEqual(target.read_bytes(), b'external old executable')
            self.assertEqual(target.stat().st_mode & 0o777, 0o444)


if __name__ == '__main__':
    unittest.main()
