#!/usr/bin/env python3

from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "run-local-executable-binding.py"
)
SPEC = importlib.util.spec_from_file_location("run_local_executable_binding", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
binding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(binding)


class RunLocalExecutableBindingTest(unittest.TestCase):
    def fixture(self, raw: str) -> tuple[Path, Path]:
        root = Path(raw)
        root.chmod(0o700)
        executable = root / "built-main-eio.exe"
        executable.write_bytes(b"same executable bytes")
        executable.chmod(0o700)
        return root / "private", executable

    def test_same_executable_with_distinct_inputs_has_distinct_provenance(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)
            first = binding.materialize(
                private_root=private_root,
                executable=executable,
                commit="a" * 40,
                fingerprint="b" * 64,
            )
            second = binding.materialize(
                private_root=private_root,
                executable=executable,
                commit="a" * 40,
                fingerprint="c" * 64,
            )

            self.assertEqual(first[0], second[0])
            self.assertNotEqual(first[2], second[2])

    def test_concurrent_materialization_converges_on_exact_artifacts(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)

            def materialize():
                return binding.materialize(
                    private_root=private_root,
                    executable=executable,
                    commit="a" * 40,
                    fingerprint="b" * 64,
                )

            with ThreadPoolExecutor(max_workers=2) as executor:
                first, second = executor.map(lambda _index: materialize(), range(2))
            self.assertEqual(first, second)

    def test_existing_artifact_with_mutable_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)
            materialized = binding.materialize(
                private_root=private_root,
                executable=executable,
                commit="a" * 40,
                fingerprint="b" * 64,
            )
            materialized[2].chmod(0o600)

            with self.assertRaisesRegex(binding.BindingError, "differs"):
                binding.materialize(
                    private_root=private_root,
                    executable=executable,
                    commit="a" * 40,
                    fingerprint="b" * 64,
                )


if __name__ == "__main__":
    unittest.main()
