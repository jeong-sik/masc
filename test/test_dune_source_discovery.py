"""Query Dune metadata in isolated fixtures; never build the MASC checkout."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT_DUNE = Path(__file__).resolve().parents[1] / "dune"


class SourceDiscoveryTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="masc-dune-discovery-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.write("dune-project", "(lang dune 3.22)\n(name masc)\n(package (name masc))\n")
        self.write("dune", ROOT_DUNE.read_text())
        self.write("scripts/check-runtime-deployment-preflight.sh", "#!/bin/sh\nexit 0\n")
        self.write("src/dune", "(library (name visible_source) (public_name masc.visible_source))\n")
        self.write("src/visible_source.ml", "let value = 1\n")

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def describe(self):
        # CI and Dune actions can supply the parent checkout/build directory.
        # Each query must own its temporary workspace, including when nested.
        env = os.environ.copy()
        for key in ("DUNE_SOURCEROOT", "DUNE_BUILD_DIR", "DUNE_RPC", "INSIDE_DUNE"):
            env.pop(key, None)
        return subprocess.run(
            ["dune", "describe", "workspace", "--root", str(self.root), "--display", "quiet"],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=30,
        )

    def assert_snapshot_is_data(self, content, error):
        snapshot = self.write("artifacts/runs/fixture/source/test/dune", content)
        protected = self.describe()
        self.assertEqual(protected.returncode, 0, protected.stderr)
        self.assertIn("visible_source.ml", protected.stdout)
        self.assertEqual(snapshot.read_text(), content)

        # Prove the copied stanzas really break discovery without a boundary.
        self.write("dune", "")
        unprotected = self.describe()
        self.assertNotEqual(unprotected.returncode, 0, unprotected.stdout)
        self.assertIn(error, unprotected.stderr)

    def test_incomplete_source_snapshot(self):
        self.assert_snapshot_is_data(
            "(include stanzas/test_runtime_claude_code.inc)\n"
            "(include stanzas/test_runtime_claude_input_attribution.inc)\n"
            "(include stanzas/test_runtime_antigravity.inc)\n",
            "doesn't exist",
        )

    def test_invalid_build_stanza_snapshot(self):
        self.assert_snapshot_is_data(
            "(library (name copied_source) (invalid_snapshot_field true))\n",
            "Unknown field",
        )

    def test_normal_source_errors_are_reported(self):
        self.write("src/dune", "(include missing-normal-source.inc)\n")
        result = self.describe()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("missing-normal-source.inc", result.stderr)
        self.assertIn("doesn't exist", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-dune", type=Path, default=ROOT_DUNE)
    args, remaining = parser.parse_known_args()
    ROOT_DUNE = args.root_dune.resolve()
    unittest.main(argv=[__file__, *remaining])
