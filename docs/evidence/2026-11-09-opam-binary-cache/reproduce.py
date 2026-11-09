#!/usr/bin/env python3
"""Run the composite action's actual shell bodies with isolated command stubs."""

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess

import yaml

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repo", type=Path, default=HERE.parents[2])
parser.add_argument("--baseline", default="82a9756e2e6b15ea77b9bb0c85cb548360cb5751")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
WORKTREE = args.repo.resolve()
ACTION = WORKTREE / ".github/actions/setup-ocaml-toolchain/action.yml"
RUN = args.output or (WORKTREE / "artifacts/opam-binary-cache" /
                      datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
RUN.mkdir(parents=True)
action = yaml.load(ACTION.read_text(), Loader=yaml.BaseLoader)
steps = action["runs"]["steps"]
validate = next(step for step in steps if step["name"] == "Validate OCaml compiler contract")
key_step = next(step for step in steps if step.get("id") == "opam-toolchain-key")
bootstrap = next(step for step in steps if step["name"] == "Bootstrap local opam switch")
assert key_step["env"]["OPAM_VERSION"] == "2.5.0"
assert action["inputs"]["ocaml-compiler"]["default"] == "5.5.2"
original = yaml.load(subprocess.check_output(
    ["git", "show", args.baseline + ":.github/actions/setup-ocaml-toolchain/action.yml"],
    cwd=WORKTREE, text=True), Loader=yaml.BaseLoader)
for step_id in ("opam-toolchain-cache", "opam-toolchain-store"):
    old = next(step for step in original["runs"]["steps"] if step.get("id") == step_id)
    new = next(step for step in steps if step.get("id") == step_id)
    assert old == new, "Existing switch cache identity/policy must not change"
binary_steps = [step for step in steps if "opam binary (" in step["name"]]
assert len(binary_steps) == 2
assert binary_steps[0]["if"] == "steps.opam-toolchain-key.outputs.opam-binary-save != 'true'"
assert binary_steps[1]["if"] == "steps.opam-toolchain-key.outputs.opam-binary-save == 'true'"
assert key_step["env"]["DEFAULT_BRANCH_PUSH"] == "${{ github.event_name == 'push' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch) }}"
assert "/restore@" in binary_steps[0]["uses"]
assert "/restore@" not in binary_steps[1]["uses"]
assert all("restore-keys" not in step["with"] for step in binary_steps)
assert all(step["with"] == binary_steps[0]["with"] for step in binary_steps)

OPAM = r'''#!/usr/bin/env python3
import json, os, sys
version = __VERSION__
args = sys.argv[1:]
with open(os.environ["FIXTURE_CALLS"], "a") as log:
    log.write(json.dumps({"tool":"opam", "version":version, "args":args}) + "\n")
if args == ["--version"]:
    print(version)
elif args == ["switch", "list", "--short"]:
    if os.environ.get("FIXTURE_SWITCH_EXISTS", "1") == "1":
        print("ci-5-5-2")
elif args and args[0] == "var":
    print(os.environ["FIXTURE_SWITCH_PREFIX"])
elif args[:2] == ["update", "--repositories"]:
    pass
elif args and args[0] == "init":
    pass
elif args[:2] == ["switch", "create"]:
    pass
else:
    raise SystemExit("Unexpected opam command: " + repr(args))
'''

COMMAND = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == "uname":
    print(os.environ["FIXTURE_UNAME_M"] if args == ["-m"] else os.environ["FIXTURE_UNAME_S"])
    raise SystemExit(0)
with open(os.environ["FIXTURE_CALLS"], "a") as log:
    log.write(json.dumps({"tool":tool, "args":args}) + "\n")
if tool == "curl":
    if os.environ.get("FIXTURE_CURL", "ok") == "fail":
        print("curl: (22) The requested URL returned error: 504", file=sys.stderr)
        raise SystemExit(22)
    target = pathlib.Path(args[args.index("-o") + 1])
elif tool == "gh":
    if os.environ.get("FIXTURE_GH", "fail") == "fail":
        print("release not found", file=sys.stderr)
        raise SystemExit(1)
    assert args[:3] == ["release", "download", "2.5.0"], args
    assert args[args.index("--repo") + 1] == "ocaml/opam", args
    target = pathlib.Path(args[args.index("--dir") + 1]) / args[args.index("--pattern") + 1]
else:
    raise SystemExit("Unexpected command: " + tool)
text = pathlib.Path(os.environ["FIXTURE_OPAM_TEMPLATE"]).read_text()
if os.environ.get("FIXTURE_DOWNLOAD_BROKEN") == "1":
    text = "#!/bin/sh\nexit 126\n"
else:
    text = text.replace("__VERSION__", repr(os.environ.get("FIXTURE_DOWNLOAD_VERSION", "2.5.0")))
target.write_text(text)
'''


def write(path: Path, text: str, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


results = []


def run_case(name, *, machine="x86_64", system="Linux", cached=None,
             cached_other_platform=False, cached_broken=False, cached_probe_failure=False,
             curl="ok", gh="fail",
             downloaded_version="2.5.0", downloaded_broken=False, switch=True,
             exact="true", store="", compiler="5.5.2", success=True,
             downloads=0, fallbacks=0, refreshes=0, inits=0, pinned_version=None):
    case = RUN / name
    case.mkdir()
    work = case / "work"
    work.mkdir()
    write(work / "scripts/ci/opam-cache-freshness.sh",
          (WORKTREE / "scripts/ci/opam-cache-freshness.sh").read_text())
    for command in ("uname", "curl", "gh"):
        write(case / "bin" / command, COMMAND, executable=True)
    template = case / "opam-template"
    template.write_text(OPAM)
    calls = case / "calls.jsonl"
    env = dict(os.environ)
    env.update({
        "PATH": str(case / "bin") + os.pathsep + env["PATH"],
        "RUNNER_TEMP": str(case / "runner temp"),
        "RUNNER_TOOL_CACHE": str(case / "tool cache"),
        "RUNNER_OS": "macOS" if system == "Darwin" else "Linux",
        "RUNNER_ARCH": "ARM64" if machine in ("aarch64", "arm64") else "X64",
        "ImageOS": "fixture-image", "ImageVersion": "1",
        "CACHE_DEPENDENCY_HASH": "lockhash", "CACHE_PREFIX": "unchanged-switch-prefix-",
        "DEFAULT_BRANCH_PUSH": "false", "GITHUB_SHA": "unused-non-push-sha",
        "OCAML_COMPILER_INPUT": compiler,
        "OPAM_VERSION": key_step["env"]["OPAM_VERSION"],
        "OPAM_CACHE_EXACT_HIT": exact, "OPAM_CACHE_EXACT_HIT_STORE": store,
        "GITHUB_ENV": str(case / "github-env"),
        "GITHUB_OUTPUT": str(case / "github-output"),
        "GITHUB_PATH": str(case / "github-path"),
        "FIXTURE_CALLS": str(calls), "FIXTURE_OPAM_TEMPLATE": str(template),
        "FIXTURE_UNAME_M": machine, "FIXTURE_UNAME_S": system,
        "FIXTURE_CURL": curl, "FIXTURE_GH": gh,
        "FIXTURE_DOWNLOAD_VERSION": downloaded_version,
        "FIXTURE_DOWNLOAD_BROKEN": "1" if downloaded_broken else "0",
        "FIXTURE_SWITCH_EXISTS": "1" if switch else "0",
        "FIXTURE_SWITCH_PREFIX": str(case / "switch"),
    })
    # No HOME or installed opam root is modified; every opam operation is stubbed.
    for key in ("GH_TOKEN", "GITHUB_TOKEN"):
        env.pop(key, None)
    Path(env["RUNNER_TEMP"]).mkdir()
    Path(env["RUNNER_TOOL_CACHE"]).mkdir()
    for key in ("GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_PATH"):
        Path(env[key]).touch()
    validation = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", validate["run"]],
                                cwd=work, env=env, text=True, capture_output=True)
    outputs = {}
    if validation.returncode == 0:
        subprocess.run(["bash", "-e", "-o", "pipefail", "-c", key_step["run"]],
                       cwd=work, env=env, text=True, capture_output=True, check=True)
        outputs = dict(line.split("=", 1) for line in Path(env["GITHUB_OUTPUT"]).read_text().splitlines())
        env["OPAM_VERSION"] = outputs["opam-version"] if pinned_version is None else pinned_version
        env["OPAM_BINARY_CACHE_DIR"] = outputs["opam-binary-path"]
        assert outputs["key"] == "unchanged-switch-prefix-fixture-image-1-lockhash-v4"
        arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
        os_name = "macos" if system == "Darwin" else "linux"
        asset = f"opam-2.5.0-{arch}-{os_name}"
        if cached is not None:
            seed = "opam-2.5.0-arm64-macos" if cached_other_platform else asset
            text = "#!/bin/sh\nexit 126\n" if cached_broken else OPAM.replace("__VERSION__", repr(cached))
            if cached_probe_failure:
                text = "#!/bin/sh\nprintf '2.5.0\\n'\nexit 1\n"
            write(Path(env["OPAM_BINARY_CACHE_DIR"]) / seed, text, executable=True)
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", bootstrap["run"]],
                                cwd=work, env=env, text=True, capture_output=True)
    else:
        result = validation
        asset = None
    (case / "output.log").write_text(result.stdout + result.stderr)
    events = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
    observed = {
        "downloads": sum(e["tool"] == "curl" for e in events),
        "fallbacks": sum(e["tool"] == "gh" for e in events),
        "refreshes": sum(e["tool"] == "opam" and e["args"] == ["update", "--repositories"] for e in events),
        "inits": sum(e["tool"] == "opam" and e["args"][:1] == ["init"] for e in events),
        "creates": sum(e["tool"] == "opam" and e["args"][:2] == ["switch", "create"] for e in events),
    }
    expected = dict(downloads=downloads, fallbacks=fallbacks, refreshes=refreshes, inits=inits, creates=inits)
    assert observed == expected, (name, observed, expected, result.stderr)
    assert (result.returncode == 0) == success, (name, result.returncode, result.stdout, result.stderr)
    if success:
        for event in events:
            if event["tool"] == "curl":
                assert f"https://github.com/ocaml/opam/releases/download/2.5.0/{asset}" in event["args"]
        installed = Path(env["RUNNER_TEMP"]) / "opam-bin/opam"
        assert installed.is_file() and os.access(installed, os.X_OK)
        assert subprocess.check_output([str(installed), "--version"], env=env, text=True).strip() == "2.5.0"
        assert Path(env["GITHUB_PATH"]).read_text().splitlines() == [str(installed.parent), env["FIXTURE_SWITCH_PREFIX"] + "/bin"]
        assert "OPAMSWITCH=ci-5-5-2" in Path(env["GITHUB_ENV"]).read_text()
    else:
        assert not Path(env["GITHUB_PATH"]).read_text(), name
    if outputs:
        assert not list(Path(outputs["opam-binary-path"]).glob(".download.*")), name
    results.append(dict(name=name, passed=True, exit_code=result.returncode,
                        binary_key=outputs.get("opam-binary-key"), **observed))
    print("PASS", name, flush=True)


run_case("warm-exact", cached="2.5.0")
run_case("warm-prefix-refreshes-root", cached="2.5.0", exact="false", refreshes=1)
run_case("warm-default-output", cached="2.5.0", exact="", store="true")
run_case("warm-linux-arm64", machine="aarch64", cached="2.5.0")
run_case("warm-macos-arm64", machine="arm64", system="Darwin", cached="2.5.0")
run_case("warm-macos-x64", system="Darwin", cached="2.5.0")
run_case("warm-binary-cold-switch", cached="2.5.0", switch=False, inits=1)
run_case("cold-curl-success", downloads=1)
run_case("cold-fallback-success", curl="fail", gh="ok", downloads=1, fallbacks=1)
run_case("cold-both-downloads-fail", curl="fail", gh="fail", downloads=1, fallbacks=1, success=False)
run_case("wrong-cache-version", cached="2.4.1", downloads=1)
run_case("wrong-cache-downloads-fail", cached="2.4.1", curl="fail", gh="fail",
         downloads=1, fallbacks=1, success=False)
run_case("unrunnable-cache", cached="2.5.0", cached_broken=True, downloads=1)
run_case("failed-cache-probe-with-matching-output", cached="2.5.0", cached_probe_failure=True, downloads=1)
run_case("failed-cache-probe-and-downloads", cached="2.5.0", cached_probe_failure=True,
         curl="fail", gh="fail", downloads=1, fallbacks=1, success=False)
run_case("other-platform-cache", cached="2.5.0", cached_other_platform=True, downloads=1)
run_case("downloaded-version-mismatch", downloaded_version="2.4.1", downloads=1, success=False)
run_case("downloaded-unrunnable", downloaded_broken=True, downloads=1, success=False)
run_case("unsupported-arch", machine="riscv64", cached="2.5.0", success=False)
run_case("unsupported-os", system="FreeBSD", cached="2.5.0", success=False)
run_case("unsupported-compiler", compiler="5.4.1", success=False)
run_case("missing-pinned-version", pinned_version="", success=False)
assert len({row["binary_key"] for row in results if row["name"] in
            ("warm-exact", "warm-linux-arm64", "warm-macos-arm64", "warm-macos-x64")}) == 4

# Exercise the source-identity guard in a real checkout. The workflow expression
# above admits only default-branch push events; dispatches never reach the guard.
head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=WORKTREE, text=True).strip()
save_policy = []
for name, default_push, event_sha, expected in (
        ("default-push-matching-checkout", "true", head, "true"),
        ("default-push-candidate-checkout", "true", "0" * 40, "false"),
        ("main-dispatch-candidate", "false", "0" * 40, "false"),
        ("main-dispatch-matching-checkout", "false", head, "false"),
        ("pull-request-or-feature-ref", "false", head, "false")):
    case = RUN / name
    case.mkdir()
    env = dict(os.environ, DEFAULT_BRANCH_PUSH=default_push, GITHUB_SHA=event_sha,
               RUNNER_OS="Linux", RUNNER_ARCH="X64", RUNNER_TOOL_CACHE=str(case / "tools"),
               ImageOS="fixture-image", ImageVersion="1", CACHE_DEPENDENCY_HASH="hash",
               CACHE_PREFIX="switch-", OPAM_VERSION="2.5.0", GITHUB_OUTPUT=str(case / "outputs"))
    subprocess.run(["bash", "-e", "-o", "pipefail", "-c", key_step["run"]],
                   cwd=WORKTREE, env=env, text=True, capture_output=True, check=True)
    outputs = dict(line.split("=", 1) for line in (case / "outputs").read_text().splitlines())
    assert outputs["opam-binary-save"] == expected, (name, outputs)
    save_policy.append(dict(name=name, passed=True, save_allowed=expected == "true"))
    print("PASS", name, flush=True)
manifest = dict(baseline_commit=args.baseline, tested_head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=WORKTREE, text=True).strip(),
                action_sha256=hashlib.sha256(ACTION.read_bytes()).hexdigest(),
                shell_fixture_count=len(results), save_policy_fixture_count=len(save_policy),
                results=results, save_policy=save_policy)
(RUN / "results.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"{len(results)} bootstrap and {len(save_policy)} save-policy fixtures PASS; output: {RUN}")
