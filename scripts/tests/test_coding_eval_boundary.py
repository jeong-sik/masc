#!/usr/bin/env python3
"""Behavior probes for coding-eval oracle, grading and resume boundaries.

Run with --docker-image IMAGE to also execute the real isolated Docker grader.
That image must already provide bash and Python 3; no image is pulled here.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/harness/lib" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sandbox = load("coding_eval_sandbox")
inputs = load("coding_eval_inputs")
DOCKER_IMAGE = None


class CodingBoundary(unittest.TestCase):
    def driver(self, root, script):
        setup = '''source "$1/scripts/harness_coding_eval.sh" --models ollama:org/model,ollama:org-model --out "$2/out" --memory-mode off
CONFIG_DIR="$2/config"
EXPERIMENT_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_experiment_inputs() { :; }
'''
        return subprocess.run(["bash", "-c", setup + script, "coding-boundary-fixture", str(ROOT), str(root)],
                              capture_output=True, text=True)

    def identity_fixture(self, root):
        (root / "config").mkdir()
        (root / "config/runtime.toml").write_text("")
        (root / "case").mkdir()
        (root / "case/case.json").write_text(json.dumps(
            {"id": "case", "timeout_sec": 1, "verify": "verify.sh", "prompt": "controlled resume"}))
        observed = self.driver(root, '''declare_requested_runtimes
jq -cn --arg first_alias "$(model_alias_of ollama org/model)" --arg second_alias "$(model_alias_of ollama org-model)" \\
  --arg first_run "$(run_id_of ollama org/model case 1)" --arg second_run "$(run_id_of ollama org-model case 1)" \\
  '{first_alias:$first_alias,second_alias:$second_alias,first_run:$first_run,second_run:$second_run}'
''')
        self.assertEqual(observed.returncode, 0, observed.stderr)
        return json.loads(observed.stdout)

    def test_original_cohorts_have_separate_runtime_and_run_identities(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed = self.identity_fixture(root)
            self.assertNotEqual(observed["first_alias"], observed["second_alias"])
            self.assertNotEqual(observed["first_run"], observed["second_run"])
            config = tomllib.loads((root / "config/runtime.toml").read_text())
            for label, model in (("first", "org/model"), ("second", "org-model")):
                alias = observed[label + "_alias"]
                self.assertEqual(config["models"][alias]["api-name"], model)
                self.assertIn(alias, config["ollama"])
                run_id = observed[label + "_run"]
                receipt = root / "out/runs" / run_id / "evidence.json"
                receipt.parent.mkdir(parents=True)
                receipt.write_text(json.dumps({"run_id": run_id, "provider": "ollama", "model": model,
                    "case_id": "case", "run_index": 1, "experiment_digest": "a" * 64, "memory_mode": "off"}))
            resumed = self.driver(root, '''run_one ollama org/model "$2/case" 1
run_one ollama org-model "$2/case" 1
''')
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertIn("skip " + observed["first_run"], resumed.stderr)
            self.assertIn("skip " + observed["second_run"], resumed.stderr)

    def test_resume_checks_every_original_run_field(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed = self.identity_fixture(root)
            run_id = observed["first_run"]
            receipt = root / "out/runs" / run_id / "evidence.json"
            receipt.parent.mkdir(parents=True)
            original = {"run_id": run_id, "provider": "ollama", "model": "org/model", "case_id": "case",
                        "run_index": 1, "experiment_digest": "a" * 64, "memory_mode": "off"}
            for key, changed in (("run_id", "foreign-run"), ("provider", "foreign-provider"),
                                 ("model", "org-model"), ("case_id", "foreign-case"), ("run_index", 2),
                                 ("run_index", True), ("experiment_digest", "b" * 64), ("memory_mode", "seeded")):
                with self.subTest(field=key, changed=changed):
                    data = json.dumps({**original, key: changed})
                    receipt.write_text(data)
                    refused = self.driver(root, 'run_one ollama org/model "$2/case" 1\n')
                    self.assertNotEqual(refused.returncode, 0, refused.stdout + refused.stderr)
                    self.assertIn("run receipt identity differs", refused.stderr)
                    self.assertNotIn("skip " + run_id, refused.stderr)
                    self.assertEqual(receipt.read_text(), data)

    def test_collect_refuses_duplicate_json_before_replacing_the_index(self):
        for duplicate in ("provider", "model", "memory_mode", "experiment_digest", "run_id", "nested", "manifest"):
            with self.subTest(duplicate=duplicate), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "runs/run").mkdir(parents=True)
                declared = {"memory_mode": "off"}
                digest = hashlib.sha256(inputs.encode(declared)).hexdigest()
                manifest = {"experiment_digest": digest, "inputs": declared}
                row = {"run_id": "run", "experiment_digest": digest, "memory_mode": "off",
                       "provider": "declared-provider", "model": "declared-model"}
                for order in ("prefix", "suffix"):
                    manifest_bytes = json.dumps(manifest)
                    row_bytes = json.dumps(row)
                    if duplicate == "manifest":
                        manifest_bytes = (
                            '{"experiment_digest":"foreign",' + manifest_bytes[1:]
                            if order == "prefix"
                            else manifest_bytes[:-1] + ',"experiment_digest":"foreign"}'
                        )
                    elif duplicate == "nested":
                        row_bytes = '{"details":{"model":"first","model":"second"},' + row_bytes[1:]
                    elif order == "prefix":
                        row_bytes = json.dumps({duplicate: "conflicting-value"})[:-1] + "," + row_bytes[1:]
                    else:
                        row_bytes = row_bytes[:-1] + "," + json.dumps({duplicate: "conflicting-value"})[1:]
                    (root / "experiment.json").write_text(manifest_bytes)
                    (root / "runs/run/evidence.json").write_text(row_bytes)
                    index = root / "runs.jsonl"
                    index.write_text("previous accepted index\n")
                    result = subprocess.run([sys.executable, str(ROOT / "scripts/harness/lib/coding_eval_inputs.py"),
                        "collect", "--experiment", str(root / "experiment.json"), "--runs", str(root / "runs"),
                        "--out", str(index)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("duplicate JSON object key", result.stderr)
                    self.assertEqual(index.read_text(), "previous accepted index\n")
                    self.assertEqual(list(root.glob(".coding-eval-rows-*")), [])

    def test_node_oracle_edit_does_not_fix_the_candidate(self):
        if not shutil.which("node"):
            self.skipTest("Node is unavailable for the fixed corpus control")
        for case_id, target in [("l1-node-sum", "sum.js"), ("l2-node-stats", "stats.js")]:
            with self.subTest(case_id=case_id), tempfile.TemporaryDirectory() as temporary:
                case = ROOT / "benchmarks/coding/cases" / case_id
                workspace = Path(temporary) / "candidate"
                shutil.copytree(case / "workspace", workspace)
                original = hashlib.sha256((workspace / target).read_bytes()).hexdigest()
                (workspace / "check.js").write_text("process.exit(0);\n")
                before = subprocess.run(["bash", str(case / "verify.sh"), str(workspace)], capture_output=True)
                self.assertEqual(before.returncode, 0)
                snapshot = Path(temporary) / "snapshot"
                snapshot.mkdir()
                sandbox.prepare_snapshot(case, workspace, snapshot)
                after = subprocess.run(["bash", str(case / "verify.sh"), str(snapshot / "workspace")], capture_output=True)
                self.assertNotEqual(after.returncode, 0)
                self.assertEqual(hashlib.sha256((snapshot / "workspace" / target).read_bytes()).hexdigest(), original)
                self.assertEqual((snapshot / "workspace/check.js").read_bytes(), (case / "workspace/check.js").read_bytes())

    def test_candidate_link_is_refused_before_host_oracle_restoration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / "candidate"
            candidate.mkdir()
            marker = root / "marker"
            marker.write_text("unchanged")
            (candidate / "check.sh").symlink_to(marker)
            with self.assertRaises(sandbox.InputRefused):
                sandbox.prepare_snapshot(ROOT / "benchmarks/coding/cases/l1-node-sum", candidate, root / "snapshot")
            self.assertEqual(marker.read_text(), "unchanged")

    def test_frozen_resume_rejects_changed_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "core.hooksPath=/dev/null", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
            script_paths = [
                "scripts/harness_coding_eval.sh", "scripts/run-local.sh",
                "scripts/harness/lib/coding_eval_evidence.sh", "scripts/harness/lib/coding_eval_inputs.py",
                "scripts/harness/lib/coding_eval_sandbox.py", "scripts/harness/lib/server_bootstrap.sh",
                "scripts/harness/lib/mcp_call.sh", "scripts/harness/lib/test_framework.sh",
                "scripts/harness/prompts/coding_keeper.txt", "config/runtime.toml",
                "cases/case/case.json", "masc", "report", "runtime.toml",
            ]
            for path in script_paths:
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(path)
            output = Path(temporary) / "out"
            output.mkdir()
            args = types.SimpleNamespace(root=root, cases=root / "cases", runtime_config=root / "runtime.toml",
                binary=root / "masc", report_binary=root / "report", models="fixture:model", memory_mode="off",
                execution_mode="live", image="sha256:" + "a" * 64, acceptance_manifest=None,
                out=output / "experiment.json", check=False)
            inputs.capture(args)
            args.check = True
            inputs.capture(args)
            for relative in ("cases/case/case.json", "config/runtime.toml", "runtime.toml", "masc", "scripts/harness/prompts/coding_keeper.txt"):
                with self.subTest(changed_input=relative):
                    path = root / relative
                    original = path.read_bytes()
                    path.write_bytes(original + b" changed")
                    with self.assertRaisesRegex(ValueError, "inputs differ"):
                        inputs.capture(args)
                    path.write_bytes(original)
            manifest = json.loads(args.out.read_text())
            original_manifest = args.out.read_text()
            args.out.write_text('{"experiment_digest":"foreign",' + original_manifest[1:])
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                inputs.capture(args)
            args.out.write_text(original_manifest)
            run = output / "runs/run/evidence.json"
            run.parent.mkdir(parents=True)
            row = {"run_id": "run", "experiment_digest": manifest["experiment_digest"], "memory_mode": "off"}
            run.write_text(json.dumps(row))
            collection = types.SimpleNamespace(experiment=args.out, runs=output / "runs", out=output / "runs.jsonl")
            inputs.collect(collection)
            self.assertEqual(json.loads(collection.out.read_text()), row)
            row["experiment_digest"] = "b" * 64
            run.write_text(json.dumps(row))
            with self.assertRaisesRegex(ValueError, "another experiment"):
                inputs.collect(collection)

    def test_actual_docker_grading_keeps_host_inputs_outside(self):
        if DOCKER_IMAGE is None:
            self.skipTest("pass --docker-image for actual Docker grading")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            case = root / "case"
            workspace = root / "candidate"
            (case / "workspace").mkdir(parents=True)
            workspace.mkdir()
            (case / "case.json").write_text(json.dumps({"verify": "verify.sh", "test_files": ["check.sh"]}))
            (case / "verify.sh").write_text('set -eu\nbash "$1/check.sh"\n')
            (case / "workspace/check.sh").write_text('set -eu\ncd "$(dirname "$0")"\npython3 candidate.py\n')
            marker = root / "host-only-marker"
            marker.write_text("host input")
            (workspace / "candidate.py").write_text(
                "import os,pathlib,socket\n"
                "assert os.getuid() != 0\n"
                "assert os.getenv('CODING_EVAL_HOST_SENTINEL') is None\n"
                "assert not pathlib.Path('/var/run/docker.sock').exists()\n"
                f"assert not pathlib.Path({str(marker)!r}).exists()\n"
                "try:\n pathlib.Path('/input/write-test').write_text('no')\n"
                "except OSError:\n pass\n"
                "else:\n raise AssertionError('input mount is writable')\n"
                "try:\n socket.create_connection(('1.1.1.1',443))\n"
                "except OSError:\n pass\n"
                "else:\n raise AssertionError('grader network is reachable')\n"
                "assert not pathlib.Path('guest-only').exists()\n"
                "pathlib.Path('guest-only').write_text('guest output')\n"
            )
            previous = os.environ.get("CODING_EVAL_HOST_SENTINEL")
            os.environ["CODING_EVAL_HOST_SENTINEL"] = "fixture-only"
            try:
                receipt = root / "receipt.json"
                self.assertEqual(sandbox.grade(case, workspace, DOCKER_IMAGE, "verify", receipt=receipt), 0)
                proof = json.loads(receipt.read_text())
                self.assertEqual(proof["image_id"], DOCKER_IMAGE)
                self.assertEqual(proof["exit_code"], 0)
                self.assertIn("workspace/candidate.py", [row["path"] for row in proof["inputs"]["files"]])
            finally:
                if previous is None:
                    del os.environ["CODING_EVAL_HOST_SENTINEL"]
                else:
                    os.environ["CODING_EVAL_HOST_SENTINEL"] = previous
            self.assertFalse((workspace / "guest-only").exists())
            self.assertEqual(marker.read_text(), "host input")
            descriptor = json.loads((case / "case.json").read_text())
            for stage in ("regression", "build"):
                descriptor[stage] = stage + ".sh"
                (case / (stage + ".sh")).write_text((case / "verify.sh").read_text())
            (case / "case.json").write_text(json.dumps(descriptor))
            output = root / "stages"
            output.mkdir()
            original_runner = sandbox.grade_snapshot
            def mutate_between_stages(*args, **kwargs):
                code = original_runner(*args, **kwargs)
                (workspace / "candidate.py").write_text("raise SystemExit(7)\n")
                return code
            sandbox.grade_snapshot = mutate_between_stages
            try:
                sandbox.grade_stages(case, workspace, DOCKER_IMAGE, output)
            finally:
                sandbox.grade_snapshot = original_runner
            self.assertEqual(json.loads((output / "grading.json").read_text()),
                             {"verify": 0, "regression": 0, "build": 0})
            proofs = [json.loads((output / (stage + "-receipt.json")).read_text())
                      for stage in ("verify", "regression", "build")]
            self.assertEqual(len({proof["inputs"]["sha256"] for proof in proofs}), 1)
            (workspace / "candidate.py").write_text("raise SystemExit(7)\n")
            self.assertEqual(sandbox.grade(case, workspace, DOCKER_IMAGE, "verify"), 7)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--docker-image")
    selected, remaining = parser.parse_known_args()
    if selected.docker_image:
        DOCKER_IMAGE = subprocess.check_output(["docker", "image", "inspect", selected.docker_image, "--format", "{{.Id}}"], text=True).strip()
    unittest.main(argv=[sys.argv[0]] + remaining)
