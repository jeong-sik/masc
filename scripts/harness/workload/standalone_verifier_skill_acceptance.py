#!/usr/bin/env python3
"""Probe a built MASC binary with real configured models in a fresh workspace.

Three Goal proofs exercise the shared Task/Goal reviewer: matching evidence,
wrong revision, and missing evidence. No Keeper or production Task is created.
The binary is supplied, never built. Provider credentials stay in the inherited
environment; only public observations and fixture evidence are exported.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
import uuid

from keeper_multi_collaboration_acceptance import AcceptanceError, McpClient


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def get(url, token=""):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=10) as response:
        return json.load(response)


def find_goal(value, goal_id):
    if isinstance(value, dict):
        if value.get("id", value.get("goal_id")) == goal_id and "verification" in value:
            return value
        children = value.values()
    elif isinstance(value, list):
        children = value
    else:
        return None
    return next((found for child in children if (found := find_goal(child, goal_id))), None)


def provider_environment(path):
    providers = tomllib.loads(path.read_text()).get("providers", {})
    rows = providers.values() if isinstance(providers, dict) else providers
    names = set()
    for provider in rows:
        credentials = provider.get("credentials", {})
        if credentials.get("type") == "env":
            names.add(credentials["key"])
        if provider.get("api_key_env"):
            names.add(provider["api_key_env"])
    return {name: os.environ[name] for name in names if name in os.environ}


def wait_for(label, observe, process, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AcceptanceError(f"server exited during {label}; see server.log")
        result = observe()
        if result:
            return result
        time.sleep(2)
    raise AcceptanceError(f"{label} did not finish within probe timeout {timeout}s")


def assess(goal, run, expected_state, evidence_path, *, evidence_readable, proof_root):
    """Require the committed Goal and that exact run's successful tool records."""
    root = Path(proof_root).resolve()
    expected_path = (root / evidence_path).resolve()

    def reads_fixture(tool):
        if tool.get("tool_name") != "tool_read_file":
            return False
        arguments = tool.get("input", {})
        file_path, cwd = arguments.get("file_path"), arguments.get("cwd", "")
        if not isinstance(file_path, str) or not file_path or not isinstance(cwd, str):
            return False
        target = (root / cwd / file_path).resolve()
        return target.is_relative_to(root) and target == expected_path

    completion = goal.get("verification", {}).get("completion", {})
    tools = run.get("tools", [])
    successful = [tool for tool in tools if tool.get("disposition") == "completed"]
    verdicts = [tool for tool in successful if tool.get("tool_name") == "report_review_verdict"]
    skills = [tool for tool in successful if tool.get("tool_name") == "keeper_skill"
              and tool.get("input", {}).get("identity", {}).get("name") == "evidence-review"
              and "file" not in tool.get("input", {})]
    reads = [tool for tool in tools if reads_fixture(tool)]
    completed_reads = [tool for tool in reads if tool.get("disposition") == "completed"]
    qualifying_reads = completed_reads if evidence_readable else reads
    expected_verdict = "APPROVE" if expected_state == "proof_proven" else "REJECT"
    checks = {
        "goal_outcome": completion.get("state") == expected_state,
        "goal_phase": goal.get("phase") == ("completed" if expected_state == "proof_proven" else "executing"),
        "same_committed_run": run.get("status") == "committed" and bool(run.get("run_id"))
        and run.get("goal_id") == goal.get("id", goal.get("goal_id"))
        and completion.get("verdict", {}).get("verification_run_id") == run.get("run_id"),
        "skill_read": bool(skills),
        "evidence_read_attempt": bool(reads),
        "single_expected_verdict": len(verdicts) == 1
        and verdicts[0].get("input", {}).get("verdict") == expected_verdict,
        "skill_then_read_then_verdict": any(
            skill["finished_at"] <= read["finished_at"] <= verdict["finished_at"]
            for skill in skills for read in qualifying_reads for verdict in verdicts),
    }
    if evidence_readable:
        checks["evidence_read_success"] = bool(completed_reads)
    return {"passed": all(checks.values()), "checks": checks, "run": run, "goal": goal}


def run(args):
    binary = Path(args.binary).resolve(strict=True)
    config_source = Path(args.runtime_config).resolve(strict=True)
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=False)
    receipt = {
        "schema": "masc.standalone_verifier_skill_acceptance.v1",
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "runtime_config_sha256": hashlib.sha256(config_source.read_bytes()).hexdigest(),
        "model_mode": "configured provider; runner supplies no scripted model responses",
        "scope": "Goal proof through shared Task/Goal reviewer; three synthetic fixtures",
        "cases": {}, "passed": False,
    }
    try:
        with tempfile.TemporaryDirectory(prefix="masc-verifier-skills-") as directory:
            base = Path(directory).resolve()
            # Do not inherit storage, deployment, scheduler or production MASC
            # controls. Retain the existing HOME value for credential discovery.
            env = {key: value for key, value in os.environ.items()
                   if key in ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SSL_CERT_FILE")}
            env.update(MASC_BASE_PATH=str(base), MASC_BASE_PATH_INPUT=str(base), MASC_OTEL_ENABLED="0")

            def command(*argv):
                # Login stdout can contain credentials. Never export command output.
                result = subprocess.run([str(binary), *argv], env=env, cwd=base,
                                        capture_output=True, text=True, timeout=90)
                if result.returncode:
                    raise AcceptanceError(f"binary {argv[0]} failed (exit {result.returncode})")

            command("init", "--base-path", str(base))
            config = base / ".masc/config"
            shutil.copyfile(config_source, config / "runtime.toml")
            if args.models_overlay:
                shutil.copyfile(Path(args.models_overlay).resolve(strict=True),
                                config / "agent-core-models-overlay.toml")
            for provider_config in (config / "runtime.toml", config / "agent-core-models-overlay.toml"):
                env.update(provider_environment(provider_config))
            receipt["models_overlay_sha256"] = hashlib.sha256(
                (config / "agent-core-models-overlay.toml").read_bytes()).hexdigest()
            installed = base / ".masc/skills/evidence-review/SKILL.md"
            if not installed.is_file():
                raise AcceptanceError("binary did not install evidence-review")
            receipt["installed_skill_sha256"] = hashlib.sha256(installed.read_bytes()).hexdigest()
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            command("login", "--base-path", str(base), "--host", "127.0.0.1", "--port", str(port),
                    "--agent", "verifier-probe", "--role", "admin", "--client-env", "MASC_VERIFIER_PROBE_TOKEN",
                    "--no-expiry", "--json")
            token = (base / ".masc/auth/verifier-probe.token").read_text().strip()
            url = f"http://127.0.0.1:{port}"
            with (output / "server.log").open("w") as log:
                process = subprocess.Popen([str(binary), "start", "--base-path", str(base),
                    "--host", "127.0.0.1", "--port", str(port)], env=env, cwd=base, stdout=log, stderr=log)
                try:
                    def ready():
                        try:
                            health = get(url + "/health?full=1")
                        except (urllib.error.URLError, TimeoutError):
                            return None
                        return health if health.get("startup", {}).get("state_ready") is True else None

                    health = wait_for("isolated boot", ready, process, args.timeout)
                    if health.get("paths", {}).get("effective_base_path") != str(base):
                        raise AcceptanceError("server workspace differs from owned temporary workspace")
                    save(output / "health.json", health)
                    client = McpClient(url + "/mcp", token, 30)
                    client.initialize()
                    fixtures = base / ".masc/playground/probe"
                    fixtures.mkdir(parents=True, exist_ok=True)
                    revision = hashlib.sha1(uuid.uuid4().bytes).hexdigest()
                    for name, evidence, expected in (
                        ("matching", {"revision": revision, "passed": 3, "total": 3}, "proof_proven"),
                        ("wrong-revision", {"revision": "0" * 40, "passed": 3, "total": 3}, "proof_refuted"),
                        ("missing", None, "proof_refuted"),
                    ):
                        goal_id = "goal-probe-" + name
                        if evidence is not None:
                            save(fixtures / (name + ".json"), evidence)
                        save(output / (name + "-fixture.json"), {"evidence": evidence, "expected_revision": revision})
                        created = client.call_tool("masc_goal_upsert", {
                            "id": goal_id, "title": "Verifier Skill probe: " + name,
                            "metric": f"Read probe/{name}.json. Measure passed/total only when revision equals "
                                      f"{revision}. A missing file or another revision does not meet the criterion.",
                            "target_value": "3/3 at the specified revision", "priority": 1,
                        })
                        save(output / (name + "-created.json"), created.response)
                        submitted = client.call_tool("masc_goal_transition", {
                            "goal_id": goal_id, "action": "request_complete"})
                        save(output / (name + "-submitted.json"), submitted.response)

                        def settled():
                            goal = find_goal(client.call_tool("masc_goal_list", {}).data, goal_id)
                            save(output / (name + "-latest-goal.json"), goal)
                            if goal and goal.get("verification", {}).get("completion", {}).get("state") in (
                                "proof_proven", "proof_refuted"):
                                return goal
                            return None

                        goal = wait_for(name + " proof", settled, process, args.timeout)
                        run_id = goal["verification"]["completion"]["verdict"]["verification_run_id"]

                        def committed():
                            payload = get(url + "/api/v1/dashboard/goal-verification-runs", token)
                            save(output / (name + "-runs.json"), payload)
                            return next((item for item in payload.get("runs", [])
                                         if item.get("run_id") == run_id and item.get("status") == "committed"), None)

                        recorded = wait_for(name + " observation commit", committed, process, args.timeout)
                        receipt["cases"][name] = assess(
                            goal, recorded, expected, f"probe/{name}.json",
                            evidence_readable=evidence is not None, proof_root=fixtures.parent)
                        save(output / "receipt.json", receipt)
                        print(name + ": " + json.dumps(receipt["cases"][name]["checks"]), flush=True)
                    receipt["passed"] = all(case["passed"] for case in receipt["cases"].values())
                finally:
                    try:
                        save(output / "final-runs.json", get(url + "/api/v1/dashboard/goal-verification-runs", token))
                    except (urllib.error.URLError, TimeoutError, ValueError):
                        pass
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    except (AcceptanceError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        receipt["error"] = str(error)
    finally:
        save(output / "receipt.json", receipt)
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--runtime-config", required=True)
    parser.add_argument("--models-overlay")
    parser.add_argument("--output-dir", required=True, help="New evidence directory; must not already exist")
    parser.add_argument("--timeout", type=float, default=300, help="Probe timeout per case, in seconds")
    raise SystemExit(run(parser.parse_args()))
