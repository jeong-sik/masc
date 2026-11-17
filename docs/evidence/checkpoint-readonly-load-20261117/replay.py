#!/usr/bin/env python3
"""Direct native source replay using explicitly supplied existing dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--repo", type=Path, default=HERE.parents[2])
parser.add_argument("--native-config", type=Path, required=True,
                    help="JSON compile_prefix/link_prefix argv; {out} is expanded")
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
config = json.loads(args.native_config.read_text())
prefix = [arg.replace("{out}", str(out)) for arg in config["compile_prefix"]]
link = [arg.replace("{out}", str(out)) for arg in config["link_prefix"]]
version = subprocess.check_output([prefix[0], "-version"], text=True).strip()
assert version == "5.5.2"
assert "-warn-error" in prefix and "+4+8+32+69" in prefix
manifest = json.loads((HERE / "source-manifest.json").read_text())
sources = {item["path"]: item for item in manifest["sources"]}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source(path, label):
    if label == "before":
        data = subprocess.check_output(["git", "show", manifest["baseline_head"] + ":" + path],
                                       cwd=args.repo)
        expected = sources[path]["baseline_sha256"]
    else:
        data = (args.repo / path).read_bytes()
        expected = sources[path]["candidate_sha256"]
    assert digest(data) == expected, path
    return data


typing = []


def compile(unit, data):
    target = out / unit
    target.write_bytes(data)
    result = subprocess.run([*prefix, "-c", unit], cwd=out, capture_output=True, text=True)
    (out / (unit + ".stderr")).write_text(result.stderr)
    typing.append({"unit": unit, "derived_source_sha256": digest(data),
                   "exit_code": result.returncode})
    if result.returncode:
        raise RuntimeError(result.stderr)


for label in ["before", "after"]:
    codec_prefix = ("open Agent_core\n"
                    "module Checkpoint_contract = Agent_core__Checkpoint_contract\n"
                    "module Checkpoint_types = Agent_core__Checkpoint_types\n"
                    "module Result_syntax = Agent_core_base.Result_syntax\n").encode()
    compile("codec_" + label + ".ml", codec_prefix + source("packages/agent_core/lib/checkpoint_codec.ml", label))
    objects_prefix = ("open Agent_core\nmodule Checkpoint_types = Agent_core__Checkpoint_types\n"
                      "module Checkpoint_codec = Codec_" + label + "\n").encode()
    for extension in ["mli", "ml"]:
        compile("objects_" + label + "." + extension,
                objects_prefix + source("packages/agent_core/lib/checkpoint_objects." + extension, label))
compile("cases.ml", (HERE / "cases.ml").read_bytes())
objects = [str(out / (name + ".cmx")) for name in
           ["codec_before", "objects_before", "codec_after", "objects_after", "cases"]]
result = subprocess.run([*link, *objects], cwd=out, capture_output=True, text=True)
(out / "link.stderr").write_text(result.stderr)
if result.returncode:
    raise RuntimeError(result.stderr)
env = os.environ.copy()
env.pop("MASC_TEST_ALLOW_HOME_BASE_PATH", None)
with tempfile.TemporaryDirectory(prefix="masc-checkpoint-readonly-proof-") as temporary:
    env["MASC_BASE_PATH"] = temporary
    result = subprocess.run([str(out / "test_checkpoint_readonly.exe")], cwd=temporary, env=env,
                            capture_output=True, text=True)
(out / "run.stdout").write_text(result.stdout)
(out / "run.stderr").write_text(result.stderr)
if result.returncode:
    raise RuntimeError(result.stderr)
observed = json.loads(result.stdout)
observed.update({"compiler_version": version, "cases_source_sha256": digest((HERE / "cases.ml").read_bytes()),
                 "replay_source_sha256": digest(Path(__file__).read_bytes()),
                 "temporary_base_path": True, "home_guard_escape_absent": True,
                 "executable_sha256": digest((out / "test_checkpoint_readonly.exe").read_bytes())})
(out / "observed.json").write_text(json.dumps(observed, indent=2) + "\n")
(out / "typing.json").write_text(json.dumps({"scope": "Whole source bodies under isolated names; existing native dependencies",
    "compiler_version": version, "fatal_warnings": [4, 8, 32, 69], "units": typing}, indent=2) + "\n")
print(json.dumps({"assertions": observed["assertions"], "cases": len(observed["cases"]), "exit_code": 0}))
