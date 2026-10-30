"""Source traversal errors must not make a partial environment scan pass."""

import contextlib
import errno
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import test_byte_cut_previews as byte_cut
import test_file_owned_env_reads as env_reads


class SourceWalkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.sources = root / "sources"
        self.sources.mkdir()
        self.denied = self.sources / "denied"
        self.denied.mkdir()
        self.safe = self.sources / "safe.ml"
        self.safe.write_text('let x = Sys.getenv_opt "HOME"\n', encoding="utf-8")
        self.hidden = self.denied / "hidden.ml"
        self.hidden.write_text('let x = Sys.getenv_opt "MASC_KEEPER_DEBUG"\n', encoding="utf-8")
        self.names = root / "names.txt"
        self.names.write_text("MASC_KEEPER_DEBUG\n", encoding="utf-8")
        self.real_scandir = os.scandir

    def deny_directory(self, path):
        if Path(path) == self.denied:
            raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), str(path))
        return self.real_scandir(path)

    def test_existing_caller_keeps_default_walk_behavior(self):
        with mock.patch("os.scandir", side_effect=self.deny_directory):
            self.assertEqual(list(byte_cut.source_files([str(self.sources)])), [str(self.safe)])

    def test_environment_scan_rejects_an_incomplete_walk(self):
        output = io.StringIO()
        with mock.patch("os.scandir", side_effect=self.deny_directory):
            with contextlib.redirect_stdout(output):
                with self.assertRaises(SystemExit) as raised:
                    env_reads.main(str(self.names), [str(self.sources)])
        self.assertIn("cannot enumerate OCaml source files", str(raised.exception))
        self.assertIn(str(self.denied), str(raised.exception))
        self.assertNotIn("no direct environment read", output.getvalue())

    def test_complete_walk_reports_the_hidden_violation(self):
        with self.assertRaises(SystemExit) as raised:
            env_reads.main(str(self.names), [str(self.sources)])
        self.assertIn(str(self.hidden), str(raised.exception))
        self.assertIn("Sys.getenv_opt", str(raised.exception))

    def test_complete_safe_walk_succeeds(self):
        clean = Path(self.tmp.name) / "clean"
        clean.mkdir()
        (clean / "safe.ml").write_text('let x = Sys.getenv_opt "HOME"\n', encoding="utf-8")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            env_reads.main(str(self.names), [str(clean)])
        self.assertIn("1 .ml files scanned", output.getvalue())
        self.assertIn("no direct environment read", output.getvalue())


if __name__ == "__main__":
    unittest.main()
