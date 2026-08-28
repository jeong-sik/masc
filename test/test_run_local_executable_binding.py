#!/usr/bin/env python3

from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "run-local-executable-binding.py"
)
SPEC = importlib.util.spec_from_file_location("run_local_executable_binding", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
binding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(binding)


class RunLocalExecutableBindingTest(unittest.TestCase):
    def dashboard_build_fixture(self, root: Path) -> tuple[Path, Path, Path]:
        source_root = root / "source"
        source_root.mkdir(mode=0o700)
        dashboard = source_root / "dashboard"
        (dashboard / "node_modules" / "vite").mkdir(parents=True)
        scripts = source_root / "scripts"
        scripts.mkdir()
        (scripts / "build-dashboard-if-needed.sh").write_text("producer\n")
        (scripts / "run-local-executable-binding.py").write_text("binder\n")
        (dashboard / ".gitignore").write_text("node_modules/\n")
        (dashboard / "package.json").write_text('{"name":"fixture"}\n')
        (dashboard / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n")
        (dashboard / "index.html").write_text("source index\n")
        (dashboard / "node_modules" / "vite" / "package.json").write_text(
            '{"version":"7.3.5"}\n'
        )
        output = source_root / "assets" / "dashboard"
        output.mkdir(parents=True)
        (output / "index.html").write_text("built index\n")
        tools = root / "tools"
        tools.mkdir()
        node = tools / "node"
        node.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "--version" ]; then echo v26.3.0; '
            'elif [ "$1" = "-p" ]; then printf \'darwin\\narm64\\n\'; '
            'else exec "$@"; fi\n'
        )
        node.chmod(0o700)
        pnpm = tools / "pnpm"
        pnpm.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "--version" ]; then echo 10.31.0; '
            'else printf \'[{"name":"fixture","version":"1.0.0"}]\\n\'; fi\n'
        )
        pnpm.chmod(0o700)
        subprocess.run(["git", "init", "-q", str(source_root)], check=True)
        subprocess.run(
            ["git", "-C", str(source_root), "config", "core.hooksPath", "/dev/null"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(source_root),
                "config",
                "user.email",
                "test@example.invalid",
            ],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(source_root), "config", "user.name", "test"],
            check=True,
        )
        subprocess.run(["git", "-C", str(source_root), "add", "dashboard"], check=True)
        subprocess.run(
            ["git", "-C", str(source_root), "commit", "-qm", "fixture"], check=True
        )
        return source_root, pnpm, node

    def fixture(self, raw: str) -> tuple[Path, Path]:
        root = Path(raw)
        root.chmod(0o700)
        executable = root / "built-main-eio.exe"
        executable.write_bytes(b"same executable bytes")
        executable.chmod(0o700)
        dashboard = root / "assets" / "dashboard"
        dashboard.mkdir(parents=True)
        (dashboard / "index.html").write_text("dashboard index")
        return root / "private", executable

    def materialize(
        self,
        *,
        private_root: Path,
        executable: Path,
        source_root: Path,
        commit: str,
        fingerprint: str,
    ):
        canonical, info = binding.inspect_source_root(source_root)
        return binding.materialize(
            private_root=private_root,
            executable=executable,
            source_root=source_root,
            expected_source_root=canonical,
            expected_source_root_device=info.st_dev,
            expected_source_root_inode=info.st_ino,
            dashboard_build_receipt_path=None,
            commit=commit,
            fingerprint=fingerprint,
        )

    def test_same_executable_with_distinct_inputs_has_distinct_provenance(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)
            first = self.materialize(
                private_root=private_root,
                executable=executable,
                source_root=Path(raw),
                commit="a" * 40,
                fingerprint="b" * 64,
            )
            second = self.materialize(
                private_root=private_root,
                executable=executable,
                source_root=Path(raw),
                commit="a" * 40,
                fingerprint="c" * 64,
            )

            self.assertEqual(first[0], second[0])
            self.assertNotEqual(first[2], second[2])

    def test_concurrent_materialization_converges_on_exact_artifacts(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)

            def materialize():
                return self.materialize(
                    private_root=private_root,
                    executable=executable,
                    source_root=Path(raw),
                    commit="a" * 40,
                    fingerprint="b" * 64,
                )

            with ThreadPoolExecutor(max_workers=2) as executor:
                first, second = executor.map(lambda _index: materialize(), range(2))
            self.assertEqual(first, second)

    def test_same_executable_from_distinct_worktrees_has_distinct_provenance(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)
            common_root = Path(raw) / "common"
            worktree_root = Path(raw) / "worktree"
            common_root.mkdir()
            worktree_root.mkdir()
            for root in (common_root, worktree_root):
                dashboard = root / "assets" / "dashboard"
                dashboard.mkdir(parents=True)
                (dashboard / "index.html").write_text(root.name)

            common = self.materialize(
                private_root=private_root,
                executable=executable,
                source_root=common_root,
                commit="a" * 40,
                fingerprint="b" * 64,
            )
            worktree = self.materialize(
                private_root=private_root,
                executable=executable,
                source_root=worktree_root,
                commit="a" * 40,
                fingerprint="b" * 64,
            )

            self.assertEqual(common[0], worktree[0])
            self.assertNotEqual(common[2], worktree[2])
            self.assertEqual(
                worktree_root.resolve(),
                Path(json.loads(worktree[2].read_text())["source_root"]),
            )

    def test_existing_artifact_with_mutable_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            private_root, executable = self.fixture(raw)
            materialized = self.materialize(
                private_root=private_root,
                executable=executable,
                source_root=Path(raw),
                commit="a" * 40,
                fingerprint="b" * 64,
            )
            materialized[2].chmod(0o600)

            with self.assertRaisesRegex(binding.BindingError, "differs"):
                self.materialize(
                    private_root=private_root,
                    executable=executable,
                    source_root=Path(raw),
                    commit="a" * 40,
                    fingerprint="b" * 64,
                )

    def test_source_root_same_path_replacement_is_rejected_before_materialization(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root = root / "source"
            source_root.mkdir()
            executable = root / "main.exe"
            executable.write_bytes(b"executable")
            executable.chmod(0o700)
            canonical, source_info = binding.inspect_source_root(source_root)
            source_root.rename(root / "displaced-source")
            source_root.mkdir()

            with self.assertRaisesRegex(binding.BindingError, "inode differs"):
                binding.materialize(
                    private_root=root / "private",
                    executable=executable,
                    source_root=source_root,
                    expected_source_root=canonical,
                    expected_source_root_device=source_info.st_dev,
                    expected_source_root_inode=source_info.st_ino,
                    dashboard_build_receipt_path=None,
                    commit="a" * 40,
                    fingerprint="b" * 64,
                )
            self.assertFalse((root / "private").exists())

    def test_build_receipt_carries_matching_prebuild_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            environment = {"PATH": f"{pnpm.parent}:{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment):
                before = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )
                commit = str(before["source_commit"])
                receipt = binding.dashboard_build_receipt(
                    source_root,
                    commit,
                    before,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )
                self.assertEqual(before["input_sha256"], receipt["input_sha256"])
                self.assertEqual(
                    before["installed_graph_metadata_sha256"],
                    receipt["installed_graph_metadata_sha256"],
                )
                self.assertEqual("production", receipt["build_mode"])
                self.assertEqual(1, receipt["output_file_count"])

    def test_build_receipt_rejects_source_mutation(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            environment = {"PATH": f"{pnpm.parent}:{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment):
                before = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )
                commit = str(before["source_commit"])
                (source_root / "dashboard" / "index.html").write_text("changed\n")
                with self.assertRaisesRegex(binding.BindingError, "inputs changed"):
                    binding.dashboard_build_receipt(
                        source_root,
                        commit,
                        before,
                        package_manager_executable=pnpm,
                        package_manager_kind="pnpm",
                        node_executable=node,
                    )

    def test_build_receipt_rejects_toolchain_mutation(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            environment = {"PATH": f"{pnpm.parent}:{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment):
                before = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )
                commit = str(before["source_commit"])
                pnpm.write_text(pnpm.read_text() + "# replacement\n")
                pnpm.chmod(0o700)
                with self.assertRaisesRegex(binding.BindingError, "inputs changed"):
                    binding.dashboard_build_receipt(
                        source_root,
                        commit,
                        before,
                        package_manager_executable=pnpm,
                        package_manager_kind="pnpm",
                        node_executable=node,
                    )

    def test_build_receipt_rejects_node_mutation(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            before = binding.dashboard_build_input_receipt(
                source_root,
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
            )
            node.write_text(node.read_text() + "# replacement\n")
            node.chmod(0o700)
            with self.assertRaisesRegex(binding.BindingError, "inputs changed"):
                binding.dashboard_build_receipt(
                    source_root,
                    str(before["source_commit"]),
                    before,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )

    def test_build_environment_profile_ignores_inherited_node_options(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            with mock.patch.dict(os.environ, {"NODE_OPTIONS": "--require=/tmp/evil"}):
                hostile = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("NODE_OPTIONS", None)
                clean = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                )
            self.assertEqual(
                hostile["environment_profile_sha256"],
                clean["environment_profile_sha256"],
            )
            self.assertEqual(hostile["environment_path"], clean["environment_path"])

    def test_dashboard_blob_replacement_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, _pnpm, _node = self.dashboard_build_fixture(root)
            private_root = root / "private"
            private_root.mkdir(mode=0o700)
            _dashboard_root, entries, payloads = binding.dashboard_source_entries(
                source_root
            )
            snapshot_root, _tree, _info = binding.materialize_dashboard_snapshot(
                private_root, entries, payloads
            )
            blob = snapshot_root / str(entries[0]["sha256"])
            blob.chmod(0o600)
            blob.write_bytes(b"x" * int(entries[0]["size"]))
            blob.chmod(0o600)
            with self.assertRaisesRegex(binding.BindingError, "blob differs"):
                binding.require_snapshot_tree(snapshot_root, entries)

    def test_concurrent_dashboard_cas_materialization_converges(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            before = binding.dashboard_build_input_receipt(
                source_root,
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
            )
            commit = str(before["source_commit"])
            receipt = binding.dashboard_build_receipt(
                source_root,
                commit,
                before,
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
            )
            receipt_path = root / "dashboard-receipt.json"
            receipt_path.write_text(json.dumps(receipt))
            executable = root / "main.exe"
            executable.write_bytes(b"exact executable")
            executable.chmod(0o700)
            canonical, source_info = binding.inspect_source_root(source_root)

            def materialize():
                return binding.materialize(
                    private_root=root / "private",
                    executable=executable,
                    source_root=source_root,
                    expected_source_root=canonical,
                    expected_source_root_device=source_info.st_dev,
                    expected_source_root_inode=source_info.st_ino,
                    dashboard_build_receipt_path=receipt_path,
                    commit=commit,
                    fingerprint="b" * 64,
                )

            with ThreadPoolExecutor(max_workers=2) as executor:
                first, second = executor.map(lambda _index: materialize(), range(2))
            self.assertEqual(first, second)
            provenance = json.loads(first[2].read_text())
            self.assertEqual("available", provenance["dashboard_assets"]["state"])

    def test_input_inventory_supports_newline_path_and_nul_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, _pnpm, _node = self.dashboard_build_fixture(root)
            unusual = source_root / "dashboard" / "line\nbreak.ts"
            unusual.write_bytes(b"prefix\0suffix")
            digest, count, matches_head, _lock = binding.dashboard_input_identity(
                source_root
            )
            self.assertEqual(64, len(digest))
            self.assertGreater(count, 0)
            self.assertFalse(matches_head)

    def test_input_inventory_rejects_non_utf8_path(self):
        with self.assertRaisesRegex(binding.BindingError, "not UTF-8"):
            binding.decode_git_paths(b"dashboard/valid.ts\0dashboard/invalid-\xff.ts\0")


if __name__ == "__main__":
    unittest.main()
