#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "dune-build-input-fingerprint.py"
)
SPEC = importlib.util.spec_from_file_location("dune_build_input_fingerprint", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
fingerprint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fingerprint)


class DuneBuildInputFingerprintTest(unittest.TestCase):
    def fixture(self, root: Path) -> dict:
        build_input = root / "_build/default/lib/input.cmxa"
        build_input.parent.mkdir(parents=True)
        build_input.write_bytes(b"compiled-input-v1")
        external = root / "toolchain/ocamlopt"
        external.parent.mkdir(parents=True)
        external.write_bytes(b"compiler-v1")
        return {
            "deps": [
                {"File": ["In_build_dir", "_build/default/lib/input.cmxa"]},
                {"File": ["External", str(external)]},
            ],
            "targets": {
                "files": ["_build/default/bin/main_eio.exe"],
                "directories": [],
            },
            "action": ["run", str(external), "lib/input.cmxa"],
        }

    def test_dependency_bytes_change_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            rule = self.fixture(root)
            before = fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])
            (root / "_build/default/lib/input.cmxa").write_bytes(b"compiled-input-v2")
            after = fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])
            self.assertNotEqual(before, after)

    def test_link_action_changes_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            rule = self.fixture(root)
            before = fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])
            rule["action"].append("-opaque")
            after = fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])
            self.assertNotEqual(before, after)

    def test_dependency_order_is_not_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            rule = self.fixture(root)
            before = fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])
            rule["deps"].reverse()
            after = fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])
            self.assertEqual(before, after)

    def test_unknown_dependency_kind_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            rule = self.fixture(root)
            rule["deps"] = [{"File": ["In_install_dir", "lib/input.cmxa"]}]
            with self.assertRaisesRegex(
                fingerprint.FingerprintError, "unsupported Dune file kind"
            ):
                fingerprint.fingerprint_rule(root, "bin/main_eio.exe", [rule])


if __name__ == "__main__":
    unittest.main()
