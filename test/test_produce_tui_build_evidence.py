import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT / "scripts" / "harness" / "workload" / "produce_tui_build_evidence.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "produce_tui_build_evidence", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


evidence = load_module()
COMMIT = "a" * 40
TREE = "b" * 40


class FakeRunner:
    def __init__(
        self,
        *,
        artifact=None,
        artifact_executable=True,
        artifact_symlink=False,
        producer_symlink=False,
        probe_stdout="masc-tui [OPTIONS]\n",
    ):
        self.artifact = artifact or b"\xcf\xfa\xed\xfe" + COMMIT.encode() + b"binary"
        self.artifact_executable = artifact_executable
        self.artifact_symlink = artifact_symlink
        self.producer_symlink = producer_symlink
        self.probe_stdout = probe_stdout
        self.snapshots = [(COMMIT, TREE), (COMMIT, TREE), (COMMIT, TREE)]
        self.statuses = ["", "", ""]
        self.environments = []
        self.build_cwds = []
        self.isolated_repo = None
        self.build_returncode = 0
        self.probe_returncode = 0

    def __call__(self, argv, cwd, environment):
        self.environments.append(dict(environment))
        args = list(argv)
        if args[:3] == ["git", "worktree", "add"]:
            isolated_repo = Path(args[-2])
            producer = isolated_repo / evidence.PRODUCER
            producer.parent.mkdir(parents=True)
            producer_target = (
                isolated_repo / "producer-real" if self.producer_symlink else producer
            )
            producer_target.write_text("#!/bin/sh\nexit 0\n")
            producer_target.chmod(producer_target.stat().st_mode | stat.S_IXUSR)
            if self.producer_symlink:
                producer.symlink_to(producer_target)
            self.isolated_repo = isolated_repo
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[:3] == ["git", "worktree", "remove"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[:2] == ["git", "rev-parse"]:
            commit, tree = self.snapshots[0]
            value = commit if args[2] == "HEAD" else tree
            if args[2] == "HEAD^{tree}":
                self.snapshots.pop(0)
            return subprocess.CompletedProcess(args, 0, value + "\n", "")
        if args[:3] == ["git", "status", "--porcelain=v1"]:
            return subprocess.CompletedProcess(args, 0, self.statuses.pop(0), "")
        if args[-1] == evidence.TARGET:
            self.build_cwds.append(cwd)
            build_dir = Path(args[args.index("--build-dir") + 1])
            artifact = build_dir / "default" / evidence.TARGET
            artifact.parent.mkdir(parents=True)
            destination = (
                artifact.with_name("masc_tui.real")
                if self.artifact_symlink
                else artifact
            )
            destination.write_bytes(self.artifact)
            executable_bits = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
            if self.artifact_executable:
                destination.chmod(destination.stat().st_mode | stat.S_IXUSR)
            else:
                destination.chmod(destination.stat().st_mode & ~executable_bits)
            if self.artifact_symlink:
                artifact.symlink_to(destination)
            return subprocess.CompletedProcess(
                args, self.build_returncode, "", "build error"
            )
        if args[-1] == "--help":
            return subprocess.CompletedProcess(
                args, self.probe_returncode, self.probe_stdout, "probe error"
            )
        raise AssertionError(f"unexpected command: {args}")


class TuiBuildEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        producer = self.repo / evidence.PRODUCER
        producer.parent.mkdir(parents=True)
        producer.write_text("#!/bin/sh\nexit 0\n")
        producer.chmod(producer.stat().st_mode | stat.S_IXUSR)
        self.output = self.root / "evidence"

    def tearDown(self):
        self.temporary.cleanup()

    def produce(self, runner, environment=None):
        return evidence.produce(
            repo=self.repo,
            expected_source_sha=COMMIT,
            expected_source_tree=TREE,
            output=self.output,
            environment_source=environment or {"PATH": "/usr/bin", "TOKEN": "secret"},
            runner=runner,
        )

    def test_produces_exact_binary_and_manifest(self):
        runner = FakeRunner()

        manifest_hash = self.produce(runner)

        manifest_path = self.output / evidence.MANIFEST
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["schema"], evidence.SCHEMA)
        self.assertEqual(manifest["source"]["head"], COMMIT)
        self.assertEqual(manifest["source"]["tree"], TREE)
        self.assertTrue(manifest["source"]["tracked_checkout_clean"])
        self.assertEqual(manifest["source"]["before"], manifest["source"]["after"])
        self.assertEqual(manifest["source"]["isolation"], "detached-temporary-worktree")
        self.assertEqual(runner.build_cwds, [runner.isolated_repo])
        self.assertNotEqual(runner.isolated_repo, self.repo)
        self.assertEqual(manifest["artifact"]["path"], "masc_tui.exe")
        self.assertEqual(
            manifest_hash, evidence.digest_bytes(manifest_path.read_bytes())
        )
        self.assertFalse((self.output / evidence.INCOMPLETE).exists())
        self.assertEqual(manifest["build"]["environment"]["forwarded_names"], ["PATH"])
        self.assertTrue(all("TOKEN" not in env for env in runner.environments))

    def test_failure_leaves_incomplete_marker(self):
        runner = FakeRunner()
        runner.build_returncode = 1

        with self.assertRaisesRegex(evidence.EvidenceError, "TUI build failed"):
            self.produce(runner)

        self.assertTrue((self.output / evidence.INCOMPLETE).exists())
        self.assertFalse((self.output / evidence.MANIFEST).exists())

    def test_rejects_source_head_mismatch(self):
        runner = FakeRunner()
        runner.snapshots[0] = ("0" * 40, TREE)

        with self.assertRaisesRegex(evidence.EvidenceError, "HEAD does not match"):
            self.produce(runner)

    def test_rejects_source_tree_mismatch(self):
        runner = FakeRunner()
        runner.snapshots[0] = (COMMIT, "0" * 40)

        with self.assertRaisesRegex(evidence.EvidenceError, "tree does not match"):
            self.produce(runner)

    def test_rejects_tracked_source_changes(self):
        runner = FakeRunner()
        runner.statuses[0] = " M bin/masc_tui.ml\n"

        with self.assertRaisesRegex(
            evidence.EvidenceError, "tracked source is not clean"
        ):
            self.produce(runner)

    def test_rejects_source_change_during_build(self):
        runner = FakeRunner()
        runner.snapshots[2] = (COMMIT, "0" * 40)

        with self.assertRaisesRegex(
            evidence.EvidenceError, "isolated source snapshot changed"
        ):
            self.produce(runner)

    def test_rejects_non_native_artifact(self):
        runner = FakeRunner(artifact=b"#!/bin/sh\n" + COMMIT.encode())

        with self.assertRaisesRegex(evidence.EvidenceError, "not ELF or Mach-O"):
            self.produce(runner)

    def test_rejects_artifact_without_source_sha(self):
        runner = FakeRunner(artifact=b"\x7fELF" + b"no-source-identity")

        with self.assertRaisesRegex(evidence.EvidenceError, "does not embed"):
            self.produce(runner)

    def test_rejects_non_executable_artifact(self):
        runner = FakeRunner(artifact_executable=False)

        with self.assertRaisesRegex(evidence.EvidenceError, "is not executable"):
            self.produce(runner)

    def test_rejects_symlinked_artifact(self):
        runner = FakeRunner(artifact_symlink=True)

        with self.assertRaisesRegex(evidence.EvidenceError, "executable is a symlink"):
            self.produce(runner)

    def test_rejects_failed_help_probe(self):
        runner = FakeRunner()
        runner.probe_returncode = 2

        with self.assertRaisesRegex(evidence.EvidenceError, "help probe failed"):
            self.produce(runner)

    def test_rejects_probe_without_tui_identity(self):
        runner = FakeRunner(probe_stdout="unrelated executable\n")

        with self.assertRaisesRegex(evidence.EvidenceError, "did not identify"):
            self.produce(runner)

    def test_rejects_nonempty_output(self):
        self.output.mkdir()
        (self.output / "old-evidence.json").write_text("{}")

        with self.assertRaisesRegex(evidence.EvidenceError, "not empty"):
            self.produce(FakeRunner())

    def test_rejects_symlinked_producer(self):
        with self.assertRaisesRegex(evidence.EvidenceError, "producer is a symlink"):
            self.produce(FakeRunner(producer_symlink=True))

    def test_scrubbed_environment_is_an_exact_allowlist(self):
        result = evidence.scrubbed_environment(
            {
                "HOME": "/home/keeper",
                "PATH": "/bin",
                "GITHUB_TOKEN": "secret",
                "ANTHROPIC_API_KEY": "secret",
                "MASC_PROVIDER_SECRET": "secret",
            }
        )

        self.assertEqual(result, {"HOME": "/home/keeper", "PATH": "/bin"})


if __name__ == "__main__":
    unittest.main()
