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


class MappedScandir:
    """Keep scandir's iterator and context-manager protocols when mapping entries."""

    def __init__(self, entries, convert):
        self.entries = entries
        self.convert = convert

    def __iter__(self):
        return self

    def __next__(self):
        return self.convert(next(self.entries))

    def __enter__(self):
        self.entries.__enter__()
        return self

    def __exit__(self, *args):
        return self.entries.__exit__(*args)


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
        self.real_lstat = os.lstat

    def deny_directory(self, path):
        if Path(path) == self.denied:
            raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), str(path))
        return self.real_scandir(path)

    def deny_entry_type(self, path, vanished=False, denied=None):
        denied = self.denied if denied is None else denied

        class UnreadableEntry:
            def __init__(self, entry):
                self.name = entry.name
                self.path = entry.path

            def is_dir(self):
                if vanished:
                    return False
                raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), self.path)

        return MappedScandir(
            self.real_scandir(path),
            lambda entry: UnreadableEntry(entry) if Path(entry.path) == denied else entry,
        )

    def deny_lstat(self, path, *args, **kwargs):
        if Path(path) == self.denied:
            raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), str(path))
        return self.real_lstat(path, *args, **kwargs)

    def assert_incomplete_walk_fails(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as raised:
                env_reads.main(str(self.names), [str(self.sources)])
        self.assertIn("cannot enumerate OCaml source files", str(raised.exception))
        self.assertIn(str(self.denied), str(raised.exception))
        self.assertNotIn("no prohibited literal-shaped call", output.getvalue())

    def test_existing_caller_keeps_default_walk_behavior(self):
        with mock.patch("os.scandir", side_effect=self.deny_directory):
            self.assertEqual(list(byte_cut.source_files([str(self.sources)])), [str(self.safe)])

    def test_environment_scan_rejects_an_incomplete_walk(self):
        with mock.patch("os.scandir", side_effect=self.deny_directory):
            self.assert_incomplete_walk_fails()

    def test_scandir_mock_supports_both_walk_iterator_protocols(self):
        def check(entries):
            paths = set()
            while True:
                try:
                    entry = next(entries)
                except StopIteration:
                    break
                paths.add(Path(entry.path))
                if Path(entry.path) == self.denied:
                    with self.assertRaises(PermissionError):
                        entry.is_dir()
            self.assertEqual(paths, {self.safe, self.denied})

        # Python 3.12 walks by calling next() on the context manager itself.
        scanner = self.deny_entry_type(self.sources)
        with scanner:
            self.assertIs(iter(scanner), scanner)
            check(scanner)
        # Newer Python walks the value returned by __enter__ instead.
        with self.deny_entry_type(self.sources) as entries:
            self.assertIs(iter(entries), entries)
            check(entries)

    def test_environment_scan_rejects_an_unknown_entry_type(self):
        with mock.patch("os.scandir", side_effect=self.deny_entry_type):
            # os.walk treats is_dir errors as non-directories; the existing
            # byte-cut caller retains that behavior, while this scan fails.
            self.assertEqual(list(byte_cut.source_files([str(self.sources)])), [str(self.safe)])
            self.assert_incomplete_walk_fails()

    def test_environment_scan_rejects_lstat_error(self):
        with mock.patch("os.lstat", side_effect=self.deny_lstat):
            self.assert_incomplete_walk_fails()

    def test_environment_scan_rejects_unavailable_entry_treated_as_a_file(self):
        def vanish(path):
            return self.deny_entry_type(path, vanished=True)

        def missing_lstat(path, *args, **kwargs):
            if Path(path) == self.denied:
                raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), str(path))
            return self.real_lstat(path, *args, **kwargs)

        with mock.patch("os.scandir", side_effect=vanish), mock.patch("os.lstat", side_effect=missing_lstat):
            self.assertEqual(list(byte_cut.source_files([str(self.sources)])), [str(self.safe)])
            self.assert_incomplete_walk_fails()

    def test_environment_scan_rejects_file_replaced_by_directory(self):
        self.hidden.write_text('let x = Sys.getenv_opt "HOME"\n', encoding="utf-8")
        racing = self.sources / "racing"
        racing.write_text("ordinary file\n", encoding="utf-8")
        replacement = Path(self.tmp.name) / "replacement"
        replacement.mkdir()
        (replacement / "owned.ml").write_text('let x = Sys.getenv_opt "MASC_KEEPER_DEBUG"\n', encoding="utf-8")
        old_file = Path(self.tmp.name) / "old-file"

        class ReplacedEntry:
            def __init__(self, entry):
                self.entry = entry
                self.name = entry.name
                self.path = entry.path

            def is_dir(self):
                result = self.entry.is_dir()
                if result:
                    raise AssertionError("fixture entry was not a file")
                os.replace(self.path, old_file)
                os.replace(replacement, self.path)
                return result

        def replace_after_is_dir(path):
            return MappedScandir(
                self.real_scandir(path),
                lambda entry: ReplacedEntry(entry) if Path(entry.path) == racing else entry,
            )

        output = io.StringIO()
        with mock.patch("os.scandir", side_effect=replace_after_is_dir):
            with contextlib.redirect_stdout(output):
                with self.assertRaises(SystemExit) as raised:
                    env_reads.main(str(self.names), [str(self.sources)])
        self.assertTrue((racing / "owned.ml").is_file())
        self.assertIn("source entry changed", str(raised.exception))
        self.assertIn(str(racing), str(raised.exception))
        self.assertNotIn("no prohibited literal-shaped call", output.getvalue())

    def test_strict_walk_preserves_excluded_directories(self):
        for name in byte_cut.SKIPPED_DIRECTORIES:
            directory = self.sources / name
            directory.mkdir()
            (directory / "skipped.ml").write_text('let x = Sys.getenv_opt "MASC_KEEPER_DEBUG"\n', encoding="utf-8")
        roots = [str(self.sources)]
        expected = {str(self.safe), str(self.hidden)}
        self.assertEqual(set(byte_cut.source_files(roots)), expected)
        self.assertEqual(set(byte_cut.source_files(roots, strict=True)), expected)

    def test_strict_walk_preserves_symlink_policy(self):
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (outside / "outside.ml").write_text('let x = Sys.getenv_opt "MASC_KEEPER_DEBUG"\n', encoding="utf-8")
        self.hidden.write_text('let x = Sys.getenv_opt "HOME"\n', encoding="utf-8")
        try:
            (self.sources / "dir_link").symlink_to(outside, target_is_directory=True)
            (self.sources / "dir_link.ml").symlink_to(outside, target_is_directory=True)
            (self.sources / "file_link.ml").symlink_to(outside / "outside.ml")
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")

        roots = [str(self.sources)]
        expected = {str(self.safe), str(self.hidden), str(self.sources / "file_link.ml")}
        self.assertEqual(set(byte_cut.source_files(roots)), expected)
        self.assertEqual(set(byte_cut.source_files(roots, strict=True)), expected)
        with self.assertRaises(SystemExit) as raised:
            env_reads.main(str(self.names), roots)
        self.assertIn(str(self.sources / "file_link.ml"), str(raised.exception))
        self.assertNotIn(str(self.sources / "dir_link"), str(raised.exception))

    def test_non_ml_symlink_type_error_does_not_block_scan(self):
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        link = self.sources / "external"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")

        def unavailable(path):
            return self.deny_entry_type(path, denied=link)

        roots = [str(self.sources)]
        expected = {str(self.safe), str(self.hidden)}
        with mock.patch("os.scandir", side_effect=unavailable):
            self.assertEqual(set(byte_cut.source_files(roots)), expected)
            self.assertEqual(set(byte_cut.source_files(roots, strict=True)), expected)

    def test_non_ml_symlink_loop_does_not_block_scan(self):
        link = self.sources / "loop"
        try:
            link.symlink_to("loop")
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")
        with self.assertRaises(OSError) as raised:
            os.stat(link)
        self.assertEqual(raised.exception.errno, errno.ELOOP)
        self.hidden.write_text('let x = Sys.getenv_opt "HOME"\n', encoding="utf-8")
        roots = [str(self.sources)]
        expected = {str(self.safe), str(self.hidden)}
        self.assertEqual(set(byte_cut.source_files(roots)), expected)
        self.assertEqual(set(byte_cut.source_files(roots, strict=True)), expected)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            env_reads.main(str(self.names), roots)
        self.assertIn("2 .ml files scanned", output.getvalue())

        ml_link = self.sources / "loop.ml"
        ml_link.symlink_to("loop.ml")
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                env_reads.main(str(self.names), roots)
        self.assertIn(str(ml_link), str(raised.exception))

    def test_non_ml_symlink_to_inaccessible_target_does_not_block_scan(self):
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        target = outside / "target"
        target.mkdir()
        (target / "owned.ml").write_text('let x = Sys.getenv_opt "MASC_KEEPER_DEBUG"\n', encoding="utf-8")
        file_target = outside / "outside.ml"
        file_target.write_text('let x = Sys.getenv_opt "MASC_KEEPER_DEBUG"\n', encoding="utf-8")
        link = self.sources / "external"
        file_link = self.sources / "external_file"
        try:
            link.symlink_to(target, target_is_directory=True)
            file_link.symlink_to(file_target)
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")
        self.hidden.write_text('let x = Sys.getenv_opt "HOME"\n', encoding="utf-8")
        outside.chmod(0)
        try:
            if os.access(outside, os.X_OK):
                self.skipTest("cannot deny access to the symlink target")
            with self.assertRaises(PermissionError):
                os.stat(link)
            with self.assertRaises(PermissionError):
                os.stat(file_link)
            roots = [str(self.sources)]
            expected = {str(self.safe), str(self.hidden)}
            self.assertEqual(set(byte_cut.source_files(roots)), expected)
            self.assertEqual(set(byte_cut.source_files(roots, strict=True)), expected)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                env_reads.main(str(self.names), roots)
            self.assertIn("2 .ml files scanned", output.getvalue())

            ml_link = self.sources / "external.ml"
            ml_link.symlink_to(file_target)
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    env_reads.main(str(self.names), roots)
            self.assertIn(str(ml_link), str(raised.exception))
        finally:
            outside.chmod(0o700)

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
        self.assertIn("no prohibited literal-shaped call", output.getvalue())

    def test_unresolved_bindings_are_advisory(self):
        clean = Path(self.tmp.name) / "bindings"
        clean.mkdir()
        examples = [
            'let key = "MASC_KEEPER_DEBUG"\nlet f key = Sys.getenv_opt key\n',
            'module A = struct let key = "MASC_KEEPER_DEBUG" end\n'
            'module B = struct let key = "HOME" end\n'
            'let f () = Sys.getenv_opt B.key\n',
            'let key = "MASC_KEEPER_DEBUG"\nlet f () = Sys.getenv_opt key\n',
        ]
        path = clean / "sample.ml"
        for sample in examples:
            with self.subTest(sample=sample):
                path.write_text(sample, encoding="utf-8")
                output, errors = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    env_reads.main(str(self.names), [str(clean)])
                self.assertIn("no prohibited literal-shaped call", output.getvalue())
                self.assertIn("Advisory: unresolved binding candidates", errors.getvalue())

    def test_literal_still_fails_when_bindings_are_advisory(self):
        clean = Path(self.tmp.name) / "mixed"
        clean.mkdir()
        (clean / "sample.ml").write_text(
            'let key = "MASC_KEEPER_DEBUG"\n'
            'let a () = Sys.getenv_opt key\n'
            'let b () = Sys.getenv_opt (("MASC_KEEPER_DEBUG"))\n',
            encoding="utf-8",
        )
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as raised:
            env_reads.main(str(self.names), [str(clean)])
        self.assertIn("Prohibited literal-shaped getenv calls", str(raised.exception))
        self.assertIn("Advisory: unresolved binding candidates", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
