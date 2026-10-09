#!/usr/bin/env python3
"""_gh_merge_base must read the merge base without decoding file patches."""
import importlib.util
import json
import pathlib
import stat
import unittest

spec = importlib.util.spec_from_file_location(
    "gh_merge_base", pathlib.Path(__file__).with_name("_gh_merge_base.py"))
gm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gm)

MERGE = "f2c74e36a3254b5b86ad06808a06f33d2d7011f8"
HEAD = "cfffad1b6a853e8014d0239c021bf568c2449c93"
REPO = "jeong-sik/masc"

# File bytes around the printf token. EVEN is valid JSON (two backslashes);
# ODD is the observed corruption (one backslash: a \u escape with a non-hex
# payload), which breaks json.loads of the whole response.
EVEN = b'let s = Printf.sprintf \\"\\\\u00%02X\\" byte in'
ODD = b'let s = Printf.sprintf \\"\\u00%02X\\" byte in'


def compare_document(patch_body: bytes) -> bytes:
    return (
        b'{"merge_base_commit": {"sha": "' + MERGE.encode()
        + b'", "parents": []}, '
        b'"files": [{"filename": "lib/tui_terminal_text.ml", "patch": "@@ -1 +1 @@\\n-'
        + patch_body + b'\\n+after"}]}'
    )


def gh_script(directory: pathlib.Path, fixture: pathlib.Path, *, fail=False):
    """A stand-in gh executable that replays a saved response."""
    if fail:
        body = "#!/bin/sh\necho 'gh: boom' >&2\nexit 1\n"
    else:
        body = f"#!/bin/sh\nexec cat '{fixture}'\n"
    gh = directory / "gh"
    gh.write_text(body)
    gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
    return str(gh)


def read_merge_base(directory: pathlib.Path, raw: bytes, **kwargs):
    fixture = directory / "compare.json"
    fixture.write_bytes(raw)
    return gm.merge_base(gh_script(directory, fixture, **kwargs), REPO, MERGE, HEAD)


class WholeResponseValidity(unittest.TestCase):
    def test_even_serialization_is_valid_json(self):
        json.loads(compare_document(EVEN))

    def test_odd_serialization_is_the_reported_corruption(self):
        with self.assertRaises(ValueError):
            json.loads(compare_document(ODD))


class MergeBaseReading(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory(prefix="gh-merge-base-test-")
        self.directory = pathlib.Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_reads_merge_base_from_a_valid_document(self):
        self.assertEqual(read_merge_base(self.directory, compare_document(EVEN)), MERGE)

    def test_reads_merge_base_when_the_patch_region_is_corrupt(self):
        self.assertEqual(read_merge_base(self.directory, compare_document(ODD)), MERGE)

    def test_reads_merge_base_when_the_tail_is_cut_away(self):
        # Cutting anywhere after the merge_base_commit object must not matter:
        # the files region is never interpreted.
        raw = compare_document(EVEN)
        cut = raw.index(b'"files"')
        self.assertEqual(read_merge_base(self.directory, raw[: cut + 4]), MERGE)

    def test_truncated_merge_base_object_is_refused_with_the_cause(self):
        # A cut inside the merge_base_commit object itself (here: inside the
        # SHA string) leaves an unterminated object, which must be refused.
        raw = compare_document(EVEN)
        with self.assertRaises(ValueError) as caught:
            read_merge_base(self.directory, raw[:60])
        self.assertIn("truncated", str(caught.exception))

    def test_missing_merge_base_object_is_refused_with_the_cause(self):
        with self.assertRaises(ValueError) as caught:
            read_merge_base(self.directory, b'{"files": []}')
        self.assertIn("no merge_base_commit", str(caught.exception))

    def test_bad_sha_is_refused_instead_of_returned(self):
        raw = compare_document(EVEN).replace(MERGE.encode(), b"not-a-sha")
        with self.assertRaises(ValueError) as caught:
            read_merge_base(self.directory, raw)
        self.assertIn("complete merge base", str(caught.exception))

    def test_gh_failure_names_the_comparison(self):
        with self.assertRaises(ValueError) as caught:
            read_merge_base(self.directory, compare_document(EVEN), fail=True)
        self.assertIn("GitHub comparison failed", str(caught.exception))
        self.assertIn("gh: boom", str(caught.exception))

    def test_partial_ids_are_refused_before_any_call(self):
        with self.assertRaises(ValueError) as caught:
            gm.merge_base("gh", REPO, MERGE[:8], HEAD)
        self.assertIn("complete commit IDs", str(caught.exception))
        with self.assertRaises(ValueError) as caught:
            gm.merge_base("gh", "bad repo name", MERGE, HEAD)
        self.assertIn("invalid repository", str(caught.exception))


class ReviewDiffValidation(unittest.TestCase):
    def test_diff_identity_refuses_partial_ids_without_a_call(self):
        spec = importlib.util.spec_from_file_location(
            "review_diff",
            pathlib.Path(__file__).with_name("review-diff.py"))
        rd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rd)
        with self.assertRaises(ValueError):
            rd.diff_identity(REPO, MERGE[:8], HEAD, pathlib.Path("."))


if __name__ == "__main__":
    unittest.main()
