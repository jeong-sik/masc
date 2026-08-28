#!/usr/bin/env python3

from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "run-local-executable-binding.py"
)
BUILD_SCRIPT = SCRIPT.with_name("build-dashboard-if-needed.sh")
SPEC = importlib.util.spec_from_file_location("run_local_executable_binding", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
binding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(binding)


class RunLocalExecutableBindingTest(unittest.TestCase):
    def dashboard_build_fixture(
        self, root: Path, *, installed: bool = True
    ) -> tuple[Path, Path, Path]:
        source_root = root / "source"
        source_root.mkdir(mode=0o700)
        dashboard = source_root / "dashboard"
        if installed:
            (dashboard / "node_modules" / "vite").mkdir(parents=True)
        else:
            dashboard.mkdir(parents=True)
        scripts = source_root / "scripts"
        scripts.mkdir()
        helper_script = scripts / "build-dashboard-if-needed.sh"
        binding_script = scripts / "run-local-executable-binding.py"
        helper_script.write_bytes(BUILD_SCRIPT.read_bytes())
        binding_script.write_bytes(SCRIPT.read_bytes())
        helper_script.chmod(0o700)
        binding_script.chmod(0o700)
        (dashboard / ".gitignore").write_text("node_modules/\n")
        (dashboard / "package.json").write_text('{"name":"fixture"}\n')
        (dashboard / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n")
        (dashboard / "index.html").write_text("source index\n")
        if installed:
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
            'case "$1" in\n'
            "  --version) echo 10.31.0 ;;\n"
            "  install) /bin/mkdir -p node_modules/vite; "
            'printf \'{"version":"7.3.5"}\\n\' >node_modules/vite/package.json ;;\n'
            '  --dir) printf \'[{"name":"fixture","version":"1.0.0"}]\\n\' ;;\n'
            '  list) printf \'[{"name":"fixture","version":"1.0.0"}]\\n\' ;;\n'
            "  run) /bin/mkdir -p ../assets/dashboard; "
            "printf 'built index\\n' >../assets/dashboard/index.html ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n"
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
        return binding.materialize(
            private_root=private_root,
            executable=executable,
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
                    environment_path=str(node.parent.resolve()),
                )
                commit = str(before["source_commit"])
                receipt = binding.dashboard_build_receipt(
                    source_root,
                    commit,
                    before,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                    environment_path=str(node.parent.resolve()),
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
                    environment_path=str(node.parent.resolve()),
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
                        environment_path=str(node.parent.resolve()),
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
                    environment_path=str(node.parent.resolve()),
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
                        environment_path=str(node.parent.resolve()),
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
                environment_path=str(node.parent.resolve()),
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
                    environment_path=str(node.parent.resolve()),
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
                    environment_path=str(node.parent.resolve()),
                )
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("NODE_OPTIONS", None)
                clean = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                    environment_path=str(node.parent.resolve()),
                )
            self.assertEqual(
                hostile["environment_profile_sha256"],
                clean["environment_profile_sha256"],
            )
            self.assertEqual(hostile["environment_path"], clean["environment_path"])

    def test_phase_receipts_reject_missing_unknown_and_wrong_types(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(root)
            build_path = str(node.parent.resolve())
            runtime = binding.dashboard_build_runtime_receipt(
                source_root,
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
                environment_path=build_path,
            )
            build_input = binding.dashboard_build_input_receipt(
                source_root,
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
                environment_path=build_path,
            )
            missing_runtime = dict(runtime)
            missing_input = dict(build_input)
            missing_runtime.pop("input_sha256")
            missing_input.pop("input_sha256")
            with self.assertRaisesRegex(binding.BindingError, "fields differ"):
                binding.require_dashboard_runtime_transition(
                    missing_runtime, missing_input
                )
            wrong_type = dict(runtime)
            wrong_type["source_root_device"] = True
            with self.assertRaisesRegex(binding.BindingError, "type differs"):
                binding.require_dashboard_runtime_transition(wrong_type, build_input)
            unknown = dict(runtime)
            unknown["extra"] = "value"
            with self.assertRaisesRegex(binding.BindingError, "fields differ"):
                binding.require_dashboard_runtime_transition(unknown, build_input)
            cross_schema = dict(runtime)
            cross_schema["schema"] = binding.DASHBOARD_BUILD_INPUT_SCHEMA
            with self.assertRaisesRegex(binding.BindingError, "schema differs"):
                binding.require_dashboard_runtime_transition(cross_schema, build_input)
            for field in (
                "environment_path_identity_sha256",
                "environment_path_executable_sha256",
                "environment_profile_sha256",
            ):
                tampered = dict(runtime)
                tampered[field] = "0" * 64
                with self.assertRaisesRegex(
                    binding.BindingError, "prepared runtime differs"
                ):
                    binding.require_dashboard_runtime_transition(tampered, build_input)

    def test_path_surface_detects_add_and_in_place_replacement(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            _source_root, pnpm, node = self.dashboard_build_fixture(root)
            build_path = str(node.parent.resolve())
            first = binding.dashboard_runtime_selection(
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
                environment_path=build_path,
            )
            added = node.parent / "added-tool"
            added.write_text("#!/bin/sh\nexit 0\n")
            added.chmod(0o700)
            second = binding.dashboard_runtime_selection(
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
                environment_path=build_path,
            )
            self.assertNotEqual(
                first["environment_path_executable_sha256"],
                second["environment_path_executable_sha256"],
            )
            added.write_text("#!/bin/sh\nexit 1\n")
            third = binding.dashboard_runtime_selection(
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
                environment_path=build_path,
            )
            self.assertNotEqual(
                second["environment_path_executable_sha256"],
                third["environment_path_executable_sha256"],
            )

    def test_path_normalization_defines_empty_relative_duplicate_and_symlink(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            _source_root, pnpm, node = self.dashboard_build_fixture(root)
            tools_link = root / "tools-link"
            tools_link.symlink_to(node.parent, target_is_directory=True)
            previous_cwd = Path.cwd()
            try:
                os.chdir(root)
                with mock.patch.dict(
                    os.environ,
                    {"PATH": os.pathsep.join((".", "", str(tools_link)))},
                ):
                    normalized = binding.dashboard_runtime_selection(
                        package_manager_executable=pnpm,
                        package_manager_kind="pnpm",
                        node_executable=node,
                    )
            finally:
                os.chdir(previous_cwd)
            parts = str(normalized["environment_path"]).split(os.pathsep)
            self.assertEqual(len(parts), len(set(parts)))
            self.assertIn(str(root.resolve()), parts)
            self.assertIn(str(node.parent.resolve()), parts)
            with self.assertRaisesRegex(binding.BindingError, "empty entry"):
                binding.dashboard_runtime_selection(
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                    environment_path=f"{node.parent.resolve()}{os.pathsep}",
                )
            duplicate = os.pathsep.join(
                (str(node.parent.resolve()), str(node.parent.resolve()))
            )
            with self.assertRaisesRegex(binding.BindingError, "identity differs"):
                binding.dashboard_runtime_selection(
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                    environment_path=duplicate,
                )

    def test_runtime_verifier_rejects_source_replacement_before_effect(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(
                root, installed=False
            )
            build_path = str(node.parent.resolve())
            runtime = binding.dashboard_build_runtime_receipt(
                source_root,
                package_manager_executable=pnpm,
                package_manager_kind="pnpm",
                node_executable=node,
                environment_path=build_path,
            )
            runtime_path = root / "runtime.json"
            runtime_path.write_text(json.dumps(runtime))
            source_root.rename(root / "original-source")
            replacement = source_root
            (replacement / "dashboard").mkdir(parents=True)
            with self.assertRaisesRegex(binding.BindingError, "identity"):
                binding.verify_dashboard_runtime_receipt(
                    runtime_path,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                    environment_path=build_path,
                )
            self.assertFalse((replacement / "dashboard" / "node_modules").exists())

    def test_cli_rejects_multiple_actions(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--capture-dashboard-build-runtime",
                "--emit-dashboard-build-receipt",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(2, result.returncode)
        self.assertIn("not allowed with argument", result.stderr)

    def test_exact_helper_prepares_fresh_checkout_then_builds(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            root.chmod(0o700)
            source_root, pnpm, node = self.dashboard_build_fixture(
                root, installed=False
            )
            helper = source_root / "scripts" / "build-dashboard-if-needed.sh"
            dirname = shutil.which("dirname")
            self.assertIsNotNone(dirname)
            environment = {
                **os.environ,
                "PATH": os.pathsep.join(
                    dict.fromkeys(
                        [
                            str(pnpm.parent),
                            str(Path(sys.executable).resolve().parent),
                            str(Path(str(dirname)).resolve().parent),
                        ]
                    )
                ),
            }
            with mock.patch.dict(os.environ, environment, clear=True):
                runtime = binding.dashboard_build_runtime_receipt(source_root)
            runtime_receipt = root / "runtime-receipt.json"
            runtime_receipt.write_text(json.dumps(runtime))
            runtime_receipt.chmod(0o400)
            exact_arguments = [
                "/bin/bash",
                str(helper),
                "--package-manager-kind",
                "pnpm",
                "--package-manager-executable",
                str(pnpm),
                "--package-manager-sha256",
                binding.digest_file(pnpm),
                "--node-executable",
                str(node),
                "--node-sha256",
                binding.digest_file(node),
                "--build-path",
                str(runtime["environment_path"]),
                "--environment-profile-sha256",
                str(runtime["environment_profile_sha256"]),
                "--runtime-receipt",
                str(runtime_receipt),
            ]
            prepared = subprocess.run(
                [
                    exact_arguments[0],
                    exact_arguments[1],
                    "--prepare-exact",
                    *exact_arguments[2:],
                ],
                env={**environment, "NODE_OPTIONS": "--require=/tmp/evil"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, prepared.returncode, prepared.stderr)
            self.assertTrue(
                (
                    source_root / "dashboard" / "node_modules" / "vite" / "package.json"
                ).is_file()
            )
            with mock.patch.dict(os.environ, environment, clear=True):
                build_input = binding.dashboard_build_input_receipt(
                    source_root,
                    package_manager_executable=pnpm,
                    package_manager_kind="pnpm",
                    node_executable=node,
                    environment_path=str(runtime["environment_path"]),
                )
                binding.require_dashboard_runtime_transition(runtime, build_input)
            build_input_receipt = root / "build-input-receipt.json"
            build_input_receipt.write_text(json.dumps(build_input))
            build_input_receipt.chmod(0o400)
            build_arguments = [
                *exact_arguments,
                "--build-input-receipt",
                str(build_input_receipt),
            ]
            built = subprocess.run(
                [
                    build_arguments[0],
                    build_arguments[1],
                    "--build-exact",
                    *build_arguments[2:],
                ],
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, built.returncode, built.stderr)
            self.assertTrue(
                (source_root / "assets" / "dashboard" / ".build-stamp").is_file()
            )
            vite_package = (
                source_root / "dashboard" / "node_modules" / "vite" / "package.json"
            )
            vite_package.write_text('{"version":"replaced"}\n')
            rejected_input = subprocess.run(
                [
                    build_arguments[0],
                    build_arguments[1],
                    "--build-exact",
                    *build_arguments[2:],
                ],
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, rejected_input.returncode)
            vite_package.write_text('{"version":"7.3.5"}\n')
            pnpm.write_text(pnpm.read_text() + "# replaced after capture\n")
            pnpm.chmod(0o700)
            rejected = subprocess.run(
                [
                    build_arguments[0],
                    build_arguments[1],
                    "--build-exact",
                    *build_arguments[2:],
                ],
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, rejected.returncode)

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
