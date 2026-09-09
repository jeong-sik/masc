"""Adversarial upstream archive tests for the regular-only macOS payload."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

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


if __name__ == '__main__':
    unittest.main()
