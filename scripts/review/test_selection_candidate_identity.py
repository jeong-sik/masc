#!/usr/bin/env python3
"""Compose real local Git candidates under differing actor environments."""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

P = runpy.run_path(str(Path(__file__).with_name("prepare-approved-batch.py")))


class Commands:
    sha = staticmethod(P["sha"])
    command = staticmethod(P["command"])


class CandidateIdentityCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="selection-identity-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "--quiet", "--object-format=sha1", ".")
        base = self.commit(self.tree({}), [])
        self.left = self.commit(self.tree({"left": "left content\n"}), [base])
        self.right = self.commit(self.tree({"right": "right content\n"}), [base])
        self.trees = P["Trees"](Commands(), str(self.repo), "unused/repo", "unused")

    def git(self, *args, text=None, env=None):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], input=text,
            text=True, capture_output=True, check=True, env=env).stdout.strip()

    def tree(self, files):
        entries = []
        for name, content in sorted(files.items()):
            blob = self.git("hash-object", "-w", "--stdin", text=content)
            entries.append(f"100644 blob {blob}\t{name}\n")
        return self.git("mktree", text="".join(entries))

    def commit(self, tree, parents):
        args = ["-c", "commit.gpgSign=false", "commit-tree", tree]
        for parent in parents:
            args += ["-p", parent]
        env = os.environ | {
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_AUTHOR_DATE": "2001-01-01T00:00:00Z",
            "GIT_COMMITTER_DATE": "2001-01-01T00:00:00Z",
        }
        return self.git(*args, text="fixture parent\n", env=env)

    def test_actor_identity_and_dates_do_not_change_candidate_sha(self):
        expected = self.trees.merge(self.left, self.right)
        for name in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
                     "GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE"):
            value = "2002-01-01T00:00:00Z" if name.endswith("DATE") else "Other actor"
            with self.subTest(name=name), patch.dict(os.environ, {name: value}):
                self.assertEqual(self.trees.merge(self.left, self.right), expected)

    def test_repository_identity_and_encoding_do_not_change_candidate_sha(self):
        expected = self.trees.merge(self.left, self.right)
        for key, value in (("user.name", "Other actor"), ("user.email", "other@example.invalid"),
                           ("i18n.commitEncoding", "ISO-8859-1")):
            with self.subTest(key=key):
                self.git("config", key, value)
                self.assertEqual(self.trees.merge(self.left, self.right), expected)

    def test_generated_object_retains_exact_parents_and_combined_content(self):
        candidate = self.trees.merge(self.left, self.right)
        body = self.git("cat-file", "-p", candidate)
        self.assertIn(f"parent {self.left}\nparent {self.right}\n", body)
        for role in ("author", "committer"):
            self.assertIn(f"{role} Approved selection <approved-selection@example.invalid> 946684800 +0000\n", body)
        self.assertNotIn("\nencoding ", body)
        self.assertEqual(self.git("ls-tree", "--name-only", candidate).splitlines(), ["left", "right"])
        self.assertEqual(self.git("show", candidate + ":left"), "left content")
        self.assertEqual(self.git("show", candidate + ":right"), "right content")
        self.assertTrue(body.endswith("\n\nExplicit source-approved candidate"))


if __name__ == "__main__":
    unittest.main()
