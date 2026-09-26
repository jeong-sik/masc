"""Compare two Linux probe artifacts using owned HTTP/model/workspace fixtures."""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import tempfile

from linux_probe_artifact import digest, fetch, require
from server_artifact_session import decode_response, write_json

PHASES = ("mutation", "cold", "warm", "concurrent_mutation", "concurrent_liveness")


def stats(values):
    values = sorted(values)
    return {"n": len(values), "min": values[0], "median": statistics.median(values),
            "p95": values[math.ceil(.95 * len(values)) - 1], "max": values[-1]}


def normalized_tasks(tasks):
    return sorted([{k: v for k, v in task.items() if k not in ("created_at", "updated_at")}
                   for task in tasks], key=lambda task: task["id"])


def validate_session(directory, entry, expected, *, tasks, cycles, runner_hash, fixture_hash):
    require(not (directory / "failure.json").exists(), "session recorded a failure")
    identity = json.loads((directory / "identity.json").read_text())
    require(all(identity[k] == expected[k] for k in ("source", "artifact", "run_id", "sha256")),
            "session artifact identity differs")
    require(identity["tasks"] == tasks and identity["cycles"] == cycles
            and identity["encoding"] == entry["encoding"] and identity["text_kind"] == entry["text_kind"]
            and identity["runner_sha256"] == runner_hash and identity["fixture_sha256"] == fixture_hash,
            "session protocol differs")
    cleanup = json.loads((directory / "cleanup.json").read_text())
    require(cleanup["reaped"] is True and cleanup["server_returncode"] == 0
            and cleanup["stub_stopped"] is True
            and all(x == {"method": "GET", "path": "/v1/models"} for x in cleanup["model_requests"]),
            "unclean shutdown or unexpected model call")
    before = json.loads((directory / "health-before.json").read_text())
    after = json.loads((directory / "health-after.json").read_text())
    for health in (before, after):
        require(health["keeper_fibers"] == 0
                and health["build"]["binary_commit"] == expected["source"]
                and health["build"]["executable_sha256"] == expected["sha256"]["main_eio.exe"]
                and health["paths"]["effective_masc_root"] == identity["base"] + "/.masc",
                "runtime identity/isolation differs")
    require(before["build"]["runtime_instance_id"] == after["build"]["runtime_instance_id"],
            "runtime instance changed")
    rows = [json.loads(line) for line in (directory / "requests.jsonl").read_text().splitlines()]
    expected_counts = {phase: cycles for phase in PHASES}
    expected_counts.update(initialize=1, registry=1, seed=(tasks + 19) // 20, prime=1)
    require(Counter(row["phase"] for row in rows) == expected_counts, "incomplete request receipts")
    indexed = {}
    for row in rows:
        is_rpc = row["phase"] in ("initialize", "registry", "seed", "mutation", "concurrent_mutation")
        expected_path = "/mcp" if is_rpc else (
            "/health/live" if row["phase"] == "concurrent_liveness" else "/api/v1/dashboard/execution")
        require((row["method"], row["path"]) == ("POST" if is_rpc else "GET", expected_path),
                "receipt endpoint differs from phase")
        requested_encoding = entry["encoding"] if row["phase"] in ("prime", "cold", "warm") else "identity"
        actual_encoding = row["encoding"] or "identity"
        require(row["requested_encoding"] == requested_encoding
                and (actual_encoding == "identity"
                     or (requested_encoding == "gzip" and actual_encoding == "gzip")),
                "unaccepted or misreported response encoding")
        raw = row["body_utf8"].encode()
        require(row["status"] == 200 and hashlib.sha256(raw).hexdigest() == row["body_sha256"]
                and len(raw) == row["json_bytes"], "failed/tampered response receipt")
        require(row["end_ns"] >= row["start_ns"]
                and row["wire_ms"] == (row["end_ns"] - row["start_ns"]) / 1e6
                and math.isfinite(row["wire_ms"]), "invalid elapsed time")
        body = decode_response(raw)
        if row["path"] == "/mcp":
            require(body.get("id") == row["rpc_id"] and "error" not in body, "JSON-RPC failure")
            if row["rpc_method"] == "tools/call":
                result = body["result"]
                require(not result.get("isError", False) and result["structuredContent"]["ok"] is True,
                        "tool failure")
        if row["phase"] in PHASES:
            key = row["phase"], row["cycle"]
            require(key not in indexed and row["cycle"] in range(1, cycles + 1), "duplicate/unexpected cycle")
            indexed[key] = row, body
    task_snapshots = []
    prime = decode_response(next(row["body_utf8"].encode() for row in rows if row["phase"] == "prime"))
    require(len(prime["tasks"]) == tasks, "prime task count differs")
    previous_generation = prime["execution_publication_generation"]
    for cycle in range(1, cycles + 1):
        cold, body = indexed["cold", cycle]
        warm, warm_body = indexed["warm", cycle]
        require(cold["body_sha256"] == warm["body_sha256"] and body == warm_body, "warm response changed")
        require(len(body["tasks"]) == tasks + cycle and body["execution_invalidated"] is False
                and body["query"]["actor"] is None and body["query"]["default_light_request"] is True,
                "execution count or scope differs")
        generation = body["execution_publication_generation"]
        require(generation > previous_generation, "generation did not advance")
        previous_generation = generation
        for row, phase in ((cold, "cold"), (warm, "warm")):
            names = {part.strip().split(";", 1)[0] for part in (row["server_timing"] or "").split(",")}
            require(("cache_compute" in names) == (phase == "cold"), "cache timing mismatch")
        task_snapshots.append(normalized_tasks(body["tasks"]))
        for phase, offset in (("mutation", 0), ("concurrent_mutation", cycles)):
            row, result = indexed[phase, cycle]
            require(row["tool"] == "masc_add_task"
                    and result["result"]["structuredContent"]["task_id"] == f"task-{tasks + offset + cycle:03d}",
                    "unexpected mutation receipt")
        require(indexed["concurrent_liveness", cycle][1].get("live") is True, "liveness not proven")
    success = json.loads((directory / "success.json").read_text())
    primary = (directory / "backlog.json").read_bytes()
    require(primary == (directory / "backlog.json.last-good").read_bytes(), "persisted copies differ")
    backlog = json.loads(primary)
    require(len(backlog["tasks"]) == success["final_tasks"] == tasks + 2 * cycles
            and backlog["version"] == success["final_revision"]
            == success["initial_revision"] + (tasks + 19) // 20 + 2 * cycles, "persisted revision/count differs")
    overlap = 0
    for cycle in range(1, cycles + 1):
        left = indexed["concurrent_mutation", cycle][0]
        right = indexed["concurrent_liveness", cycle][0]
        overlap += max(left["start_ns"], right["start_ns"]) < min(left["end_ns"], right["end_ns"])
    inputs = [(r["phase"], r["cycle"], r["arguments_sha256"]) for r in rows if r.get("tool")]
    selected = [r for r in rows if r["phase"] in PHASES]
    return selected, {"timings": {phase: stats([r["wire_ms"] for r in selected if r["phase"] == phase])
                                  for phase in PHASES}, "client_overlap_pairs": overlap}, {
        "inputs": inputs, "projected_tasks": task_snapshots, "persisted_tasks": normalized_tasks(backlog["tasks"])}


def run_child(command, out, name):
    with (out / (name + ".stdout.txt")).open("wb") as stdout, (out / (name + ".stderr.txt")).open("wb") as stderr:
        child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = child.wait()
        finally:
            if child.poll() is None:
                # The owner has a separately grouped server and unwinds it.
                previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
                try:
                    child.send_signal(signal.SIGINT)
                    try:
                        child.wait(timeout=40)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                finally:
                    for sig, handler in previous.items():
                        signal.signal(sig, handler)
            write_json(out / (name + ".exit.json"), {"returncode": child.returncode})
    require(code == 0, "session failed: " + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--repository-id", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--tasks", type=int, default=250)
    for role in ("baseline", "candidate"):
        parser.add_argument("--" + role + "-run", type=int, required=True)
        parser.add_argument("--" + role + "-artifact", type=int, required=True)
        parser.add_argument("--" + role + "-commit", required=True)
    args = parser.parse_args()
    require(min(args.tasks, args.cycles, args.repetitions) > 0, "positive workload sizes required")
    require(args.baseline_commit != args.candidate_commit, "baseline and candidate source must differ")
    require(platform.system() == "Linux" and platform.machine() == "x86_64", "Linux x86-64 required")
    repo = Path(__file__).resolve().parents[3]
    runner = Path(__file__).with_name("server_artifact_session.py")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        with tempfile.TemporaryDirectory(prefix="masc-server-artifacts-") as temporary:
            artifacts = Path(temporary)
            identities = {}
            for role in ("baseline", "candidate"):
                identities[role] = fetch(artifacts / role, repository=args.repository,
                    repository_id=args.repository_id, source=getattr(args, role + "_commit"),
                    run_id=getattr(args, role + "_run"), artifact_id=getattr(args, role + "_artifact"))
                write_json(out / (role + "-identity.json"), identities[role])
            require(identities["baseline"]["sha256"]["main_eio.exe"] != identities["candidate"]["sha256"]["main_eio.exe"],
                    "baseline and candidate binaries must differ")
            plan = [{"name": f"{kind}-{encoding}-{rep:02d}-{role}", "role": role,
                     "text_kind": kind, "encoding": encoding, "repetition": rep}
                    for kind in ("ascii", "multilingual") for encoding in ("identity", "gzip")
                    for rep in range(1, args.repetitions + 1)
                    for role in (("baseline", "candidate") if rep % 2 else ("candidate", "baseline"))]
            write_json(out / "plan.json", {"sessions": plan, "tasks": args.tasks, "cycles": args.cycles,
                "runner_sha256": digest(runner), "driver_sha256": digest(Path(__file__)),
                "verifier_sha256": digest(Path(__file__).with_name("linux_probe_artifact.py")),
                "observer_commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
                "platform": platform.platform(), "python": sys.version,
                "scope": "fresh TCP; timer through body read, before decompression/parse; concurrent phase separate"})
            all_rows, sessions, semantics = [], [], {}
            for entry in plan:
                name, role = entry["name"], entry["role"]
                command = [sys.executable, "-u", str(runner), str(artifacts / role), str(out / name),
                           "--repo", str(repo), "--tasks", str(args.tasks), "--cycles", str(args.cycles),
                           "--encoding", entry["encoding"], "--text-kind", entry["text_kind"]]
                print("START " + name, flush=True)
                run_child(command, out, name)
                rows, summary, observed = validate_session(out / name, entry, identities[role],
                    tasks=args.tasks, cycles=args.cycles, runner_hash=digest(runner),
                    fixture_hash=digest(repo / "scripts/fixtures/release-evidence/runtime.toml"))
                kind = entry["text_kind"]
                if kind in semantics:
                    require(semantics[kind] == observed, "cross-session inputs/tasks differ: " + name)
                else:
                    semantics[kind] = observed
                sessions.append({**entry, **summary})
                all_rows.extend({"role": role, "text_kind": kind,
                                 "requested_encoding": entry["encoding"],
                                 "response_encoding": r["encoding"] or "identity",
                                 "phase": r["phase"], "wire_ms": r["wire_ms"]} for r in rows)
                write_json(out / "completed-sessions.json", sessions)
                print("PASS " + name, flush=True)
            groups = {}
            for kind in ("ascii", "multilingual"):
                for encoding in ("identity", "gzip"):
                    for role in ("baseline", "candidate"):
                        for phase in PHASES:
                            selected = [r for r in all_rows if
                                      (r["text_kind"], r["requested_encoding"], r["role"], r["phase"])
                                      == (kind, encoding, role, phase)]
                            values = [r["wire_ms"] for r in selected]
                            require(len(values) == args.repetitions * args.cycles, "incomplete group")
                            groups[f"{kind}-{encoding}-{role}-{phase}"] = {
                                **stats(values), "response_encoding_counts": dict(Counter(
                                    r["response_encoding"] for r in selected))}
            write_json(out / "summary.json", {"groups": groups, "sessions": sessions, "goal_ms": .1,
                "all_observations_below_goal": all(r["wire_ms"] < .1 for r in all_rows),
                "p95_definition": "nearest rank sorted[ceil(.95*n)-1]",
                "scope": "synthetic isolated Linux comparison; no deployment, physical display or broad continuity proof",
                "concurrency_scope": "client request overlap is recorded; encoder overlap and scheduler-only delay are unproven"})
    except BaseException as error:
        write_json(out / "failure.json", {"type": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
