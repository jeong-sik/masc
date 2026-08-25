#!/usr/bin/env python3
"""Run and bundle the Keeper V01-V15 compile/regression conformance matrix.

This runner belongs in CI as precise contract evidence.  It intentionally
invokes Dune test aliases; callers that only want to inspect an existing
bundle use ``--verify`` and never rebuild.  It is not the product acceptance
authority: release acceptance requires RW01-RW16 from
``keeper_multi_collaboration_acceptance.py`` against an isolated real runtime.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys
import time


SCENARIOS = [
    {
        "id": "V01",
        "name": "boot_materialize",
        "authority_transition": "validated declarations -> complete Owner install -> listener-ready health",
        "user_outcome": "executable membership and invalid-config reason are inspectable",
        "evidence": ["source_sha", "config_root", "registry_names"],
        "targets": ["@test/runtest-test_server_runtime_bootstrap"],
    },
    {
        "id": "V02",
        "name": "owner_serialization",
        "authority_transition": "one Owner child claim; competing direct/autonomous request queues or rejects typed",
        "user_outcome": "one external-effect lane per Keeper",
        "evidence": ["operation_id", "owner_timeline"],
        "targets": ["@test/runtest-test_keeper_owner"],
    },
    {
        "id": "V03",
        "name": "direct_dashboard",
        "authority_transition": "Owner -> runtime -> common terminal pipeline -> reply",
        "user_outcome": "visible reply and turn_ref share the admitted turn identity",
        "evidence": ["runtime_id", "receipt", "response_digest", "turn_ref"],
        "targets": ["@test/runtest-test_keeper_chat_operation_http"],
    },
    {
        "id": "V04",
        "name": "durable_restart",
        "authority_transition": "queue commit -> reload -> exact single claim",
        "user_outcome": "async request survives restart",
        "evidence": ["queue_revision_before", "queue_revision_after"],
        "targets": ["@test/runtest-test_keeper_event_queue"],
    },
    {
        "id": "V05",
        "name": "exact_ack",
        "authority_transition": "selected source incarnation alone terminalizes",
        "user_outcome": "a newer incarnation is not lost",
        "evidence": ["source_identity", "pre_state_wal", "ack_receipt"],
        "targets": [
            "@test/runtest-test_keeper_event_queue",
            "@test/runtest-test_keeper_event_queue_state_v2",
        ],
    },
    {
        "id": "V06",
        "name": "pre_checkpoint_failover",
        "authority_transition": "retryable first attempt -> next candidate -> winner checkpoint owner",
        "user_outcome": "one final response",
        "evidence": ["attempt_sequence", "fallback_reason", "winner_owner"],
        "targets": ["@test/runtest-test_keeper_turn_driver_failover"],
    },
    {
        "id": "V07",
        "name": "post_effect_failure",
        "authority_transition": "effect boundary closes blind replay; terminal failure stays typed",
        "user_outcome": "no duplicate external effect",
        "evidence": ["effect_id", "checkpoint_stage", "terminal_disposition"],
        "targets": [
            "@test/runtest-test_keeper_gate_effect_coverage",
            "@test/runtest-test_keeper_terminal_reason_typed",
        ],
    },
    {
        "id": "V08",
        "name": "checkpoint_resume",
        "authority_transition": "winning Agent Core checkpoint or official-client session owns resume",
        "user_outcome": "conversation continuity without cross-owner resume",
        "evidence": ["checkpoint_owner", "session_owner", "resume_id"],
        "targets": [
            "@test/runtest-test_keeper_replay_checkpoint",
            "@test/runtest-test_official_client_session_store",
        ],
    },
    {
        "id": "V09",
        "name": "sandbox_tool_policy",
        "authority_transition": "descriptor policy and sandbox boundary decide before execution",
        "user_outcome": "forbidden tools fail before effect",
        "evidence": ["tool_outcome", "sandbox_profile"],
        "targets": [
            "@test/runtest-test_keeper_tool_policy_masc_surface",
            "@test/runtest-test_keeper_sandbox_containment",
        ],
    },
    {
        "id": "V10",
        "name": "hitl_replay",
        "authority_transition": "approval decision and effect outcome remain separate; replay is exact",
        "user_outcome": "decision and final delivery are correlated",
        "evidence": ["approval_id", "effect_receipt", "delivery_receipt"],
        "targets": [
            "@test/runtest-test_keeper_gate_replay",
            "@test/runtest-test_keeper_hitl_resolution_prompt",
        ],
    },
    {
        "id": "V11",
        "name": "completion_authority",
        "authority_transition": "natural-language result -> evidence -> authenticated typed verdict",
        "user_outcome": "no false task completion",
        "evidence": ["evidence_submission", "authority_verdict"],
        "targets": [
            "@test/runtest-test_verification_authority_tools",
            "@test/runtest-test_completion_trust_harness",
        ],
    },
    {
        "id": "V13",
        "name": "config_application_boundary",
        "authority_transition": "raw save -> per-key startup/fiber/turn application state",
        "user_outcome": "effective value and restart requirement are explicit",
        "evidence": [
            "configured_value",
            "effective_value",
            "applied_at",
            "reload_class",
        ],
        "targets": [
            "@test/runtest-test_runtime_toml_overrides",
            "@test/runtest-test_keeper_runtime_config_leaf",
        ],
    },
    {
        "id": "V14",
        "name": "config_typo_orphan",
        "authority_transition": "unknown/retired key -> reject; forward schema -> warning",
        "user_outcome": "no silent setting no-op",
        "evidence": ["schema_issue", "setting_registry_census"],
        "targets": [
            "@test/runtest-test_runtime_toml_overrides",
            "@test/runtest-test_keeper_runtime_config_leaf",
        ],
    },
    {
        "id": "V15",
        "name": "continuous_multi_source_liveness",
        "authority_transition": (
            "durable outbox -> active-head release; delivery terminal -> source ACK; "
            "recovery pending/transient failure -> queue-tail defer; "
            "deterministic failure -> source quarantine"
        ),
        "user_outcome": (
            "one blocked Schedule/Task/Board/Goal/Comment/Fusion source does not "
            "monopolize the Keeper"
        ),
        "evidence": [
            "source_incarnation",
            "queue_order_after_defer",
            "typed_liveness_disposition",
            "delivery_intent",
        ],
        "targets": [
            "@test/runtest-test_keeper_failed_selection_disposition",
            "@test/runtest-test_keeper_event_queue",
        ],
    },
]


def source_sha(repo: pathlib.Path) -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True
    ).strip()


def log_digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def correlation_id(sha: str, results: list[dict]) -> str:
    seed = json.dumps(
        {
            "source_sha": sha,
            "results": [
                (row["id"], row["status"], row["log_sha256"]) for row in results
            ],
        },
        sort_keys=True,
    ).encode()
    return hashlib.sha256(seed).hexdigest()


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def write_bundle(output_dir: pathlib.Path, sha: str, results: list[dict]) -> dict:
    passed = all(row["status"] == "passed" for row in results)
    bundle = {
        "schema": "masc.keeper_full_lifecycle_evidence.v1",
        "source_sha": sha,
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bundle_id": correlation_id(sha, results),
        "status": "passed" if passed else "failed",
        "scenario_count": len(results),
        "passed_count": sum(row["status"] == "passed" for row in results),
        "scenarios": results,
    }
    (output_dir / "bundle.json").write_text(
        json.dumps(bundle, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    lines = [
        "# Keeper Full-Lifecycle Evidence",
        "",
        f"- Source SHA: `{sha}`",
        f"- Bundle ID: `{bundle['bundle_id']}`",
        f"- Status: **{bundle['status']}** ({bundle['passed_count']}/{bundle['scenario_count']})",
        "",
        "| ID | Scenario | Status | Authority transition | User outcome | Evidence log |",
        "|---|---|---|---|---|---|",
    ]
    for row in results:
        lines.append(
            f"| {markdown_cell(row['id'])} | {markdown_cell(row['name'])} | "
            f"{markdown_cell(row['status'])} | "
            f"{markdown_cell(row['authority_transition'])} | "
            f"{markdown_cell(row['user_outcome'])} | `{markdown_cell(row['log'])}` |"
        )
    lines.append("")
    (output_dir / "bundle.md").write_text("\n".join(lines), encoding="utf-8")
    return bundle


def print_failure_summary(output_dir: pathlib.Path, results: list[dict]) -> None:
    failed = [row for row in results if row["status"] != "passed"]
    if not failed:
        return
    print(
        f"keeper-full-lifecycle-evidence: {len(failed)} failed scenario(s)",
        file=sys.stderr,
    )
    for row in failed:
        log_path = output_dir / row["log"]
        lines = log_path.read_text(encoding="utf-8").splitlines()
        print(
            f"--- {row['id']} {row['name']} exit={row['exit_code']} "
            f"log={row['log']} ---",
            file=sys.stderr,
        )
        print("command: " + " ".join(row["command"]), file=sys.stderr)
        for line in lines[-80:]:
            print(line, file=sys.stderr)


def run_bundle(repo: pathlib.Path, output_dir: pathlib.Path) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    sha = source_sha(repo)
    results = []
    for scenario in SCENARIOS:
        log_path = output_dir / f"{scenario['id'].lower()}-{scenario['name']}.log"
        command = [
            "opam",
            "exec",
            "--",
            "dune",
            "build",
            "--root",
            ".",
            *scenario["targets"],
        ]
        started = time.monotonic()
        try:
            completed = subprocess.run(
                command,
                cwd=repo,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            exit_code = completed.returncode
            output = completed.stdout
        except OSError as error:
            exit_code = 127
            output = f"could not execute {command[0]}: {error}\n"
        log_path.write_text(output, encoding="utf-8")
        results.append(
            {
                **scenario,
                "status": "passed" if exit_code == 0 else "failed",
                "exit_code": exit_code,
                "duration_seconds": round(time.monotonic() - started, 3),
                "command": command,
                "log": log_path.name,
                "log_sha256": log_digest(log_path),
            }
        )
    bundle = write_bundle(output_dir, sha, results)
    print_failure_summary(output_dir, results)
    print(
        f"keeper-full-lifecycle-evidence: {bundle['status']} "
        f"{bundle['passed_count']}/{bundle['scenario_count']} bundle={bundle['bundle_id']}"
    )
    return 0 if bundle["status"] == "passed" else 1


def verify_bundle(repo: pathlib.Path, output_dir: pathlib.Path) -> int:
    path = output_dir / "bundle.json"
    if not path.is_file():
        print(f"keeper-full-lifecycle-evidence: missing {path}", file=sys.stderr)
        return 1
    bundle = json.loads(path.read_text(encoding="utf-8"))
    expected_ids = [row["id"] for row in SCENARIOS]
    actual_ids = [row.get("id") for row in bundle.get("scenarios", [])]
    errors = []
    if bundle.get("schema") != "masc.keeper_full_lifecycle_evidence.v1":
        errors.append("schema mismatch")
    if actual_ids != expected_ids:
        errors.append(f"scenario ids mismatch: {actual_ids!r}")
    if bundle.get("status") != "passed":
        errors.append(f"bundle status is {bundle.get('status')!r}")
    if bundle.get("source_sha") != source_sha(repo):
        errors.append("source SHA does not match checked-out HEAD")
    scenarios = bundle.get("scenarios", [])
    if bundle.get("scenario_count") != len(SCENARIOS):
        errors.append("scenario count mismatch")
    passed_count = sum(row.get("status") == "passed" for row in scenarios)
    if bundle.get("passed_count") != passed_count:
        errors.append("passed count mismatch")
    if any(row.get("status") != "passed" for row in scenarios):
        errors.append("one or more scenarios are not passed")
    for row in scenarios:
        log_path = output_dir / str(row.get("log", ""))
        if not log_path.is_file() or log_digest(log_path) != row.get("log_sha256"):
            errors.append(f"log digest mismatch: {row.get('id')}")
    if scenarios and bundle.get("bundle_id") != correlation_id(
        str(bundle.get("source_sha", "")), scenarios
    ):
        errors.append("bundle id mismatch")
    if errors:
        for error in errors:
            print(f"keeper-full-lifecycle-evidence: {error}", file=sys.stderr)
        return 1
    print(f"keeper-full-lifecycle-evidence: verified {len(expected_ids)} scenarios")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir", default=".release-evidence/keeper-full-lifecycle"
    )
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    output_dir = (repo / args.output_dir).resolve()
    return (
        verify_bundle(repo, output_dir) if args.verify else run_bundle(repo, output_dir)
    )


if __name__ == "__main__":
    raise SystemExit(main())
