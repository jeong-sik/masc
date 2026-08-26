#!/usr/bin/env python3
"""Self-test for check-merge-audit.py (task-377, PR #30463 broken window).

Rebuilds the three merge shapes this audit exists to distinguish:

1. CLEAN       -- every required context concluded ``success`` on the merged
                  SHA (what a healthy merge looks like).
2. UNFINISHED  -- the PR #30463 shape: ``CI Gate`` CANCELLED, ``Build and
                  Test`` SKIPPED. The audit must refuse to bless it.
3. ABSENT      -- a required context with no run on the merged SHA at all.

Run directly: ``python3 scripts/ci/test_check_merge_audit.py``
(wired into run-lint-suite.sh alongside the other self-tests).
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
GUARD = REPO_ROOT / "scripts" / "ci" / "check-merge-audit.py"

# Captured shape of PR #30463's merge (2026-08-25 07:21:50Z): the merge landed
# while its own checks stood cancelled/skipped. Rebuilt from kidsnote's
# artifacts/task-343-broken-window-pr30463.json observation.
CHECK_RUNS_BROKEN_WINDOW = [
    {"name": "CI Gate", "status": "completed", "conclusion": "cancelled"},
    {"name": "Build and Test", "status": "completed", "conclusion": "skipped"},
    {"name": "Dashboard", "status": "completed", "conclusion": "cancelled"},
    # A stale older re-run must not override the newest conclusion.
    {"name": "CI Gate", "status": "completed", "conclusion": "success"},
]

CHECK_RUNS_CLEAN = [
    {"name": "CI Gate", "status": "completed", "conclusion": "success"},
]

CHECK_RUNS_ABSENT: list[dict[str, str]] = []

COMBINED_STATUS_EMPTY = {"statuses": [], "state": ""}


def run_guard(
    check_runs: list[dict[str, str]] | None,
    combined_status: dict[str, object] | None,
    contexts: str = "CI Gate",
) -> tuple[int, str, dict[str, object]]:
    """Invoke the guard with fixture files; return (exit, output, parsed JSON)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        runs_file = tmp_path / "check-runs.json"
        status_file = tmp_path / "status.json"
        out_file = tmp_path / "audit.json"
        runs_file.write_text(json.dumps(check_runs), encoding="utf-8")
        status_file.write_text(json.dumps(combined_status), encoding="utf-8")
        proc = subprocess.run(
            [
                sys.executable,
                str(GUARD),
                "--sha",
                "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "--repo",
                "example/example",
                "--contexts",
                contexts,
                "--check-runs-file",
                str(runs_file),
                "--status-file",
                str(status_file),
                "--json-out",
                str(out_file),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        parsed: dict[str, object] = {}
        if out_file.exists():
            parsed = json.loads(out_file.read_text(encoding="utf-8"))
        return proc.returncode, proc.stdout + proc.stderr, parsed


def expect(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} {detail}")
        raise SystemExit(1)


def main() -> int:
    # 1. Clean merge: required context concluded success.
    code, out, parsed = run_guard(CHECK_RUNS_CLEAN, COMBINED_STATUS_EMPTY)
    expect(
        "clean merge exits 0",
        code == 0,
        f"exit={code} out={out!r}",
    )
    expect("clean merge reports CLEAN", "CLEAN" in out, out)
    expect("clean merge json clean=true", parsed.get("clean") is True, str(parsed))

    # 2. The PR #30463 broken-window shape: CI Gate CANCELLED (newest run).
    code, out, parsed = run_guard(
        CHECK_RUNS_BROKEN_WINDOW, COMBINED_STATUS_EMPTY
    )
    expect(
        "broken window exits 1",
        code == 1,
        f"exit={code} out={out!r}",
    )
    expect(
        "broken window names CI Gate as unfinished",
        any(
            entry.get("context") == "CI Gate"
            and entry.get("conclusion") == "cancelled"
            for entry in parsed.get("offending", [])
        ),
        str(parsed),
    )
    expect(
        "newest run wins over the stale success re-run",
        any(
            entry.get("context") == "CI Gate"
            and entry.get("conclusion") == "cancelled"
            for entry in parsed.get("offending", [])
        ),
        str(parsed),
    )

    # 3. Required context absent from the merged SHA entirely.
    code, out, parsed = run_guard(CHECK_RUNS_ABSENT, COMBINED_STATUS_EMPTY)
    expect(
        "absent required context exits 1",
        code == 1,
        f"exit={code} out={out!r}",
    )
    expect(
        "absent context reported as unfinished/absent",
        any(
            entry.get("context") == "CI Gate"
            and entry.get("conclusion") == "absent"
            for entry in parsed.get("offending", [])
        ),
        str(parsed),
    )

    # 4. Legacy statuses fallback still catches a pending (no-verdict) state.
    code, out, parsed = run_guard(
        CHECK_RUNS_ABSENT,
        {"statuses": [{"context": "CI Gate", "state": "pending"}], "state": "pending"},
    )
    expect(
        "pending legacy status exits 1",
        code == 1,
        f"exit={code} out={out!r}",
    )

    # 5. Multiple contexts CSV.
    code, out, parsed = run_guard(
        CHECK_RUNS_BROKEN_WINDOW,
        COMBINED_STATUS_EMPTY,
        contexts="CI Gate,Build and Test",
    )
    expect(
        "second required context also reported",
        {entry.get("context") for entry in parsed.get("offending", [])}
        == {"CI Gate", "Build and Test"},
        str(parsed),
    )

    # 6. A raw ``gh api .../check-runs > fixture.json`` capture carries the
    #    envelope (total_count + check_runs); the guard must unwrap it. The
    #    first version read the envelope as the run list and crashed on real
    #    captured data, which the bare-list fixtures above never caught.
    envelope_fixture = "/tmp/task377-envelope-check-runs.json"
    with open(envelope_fixture, "w", encoding="utf-8") as handle:
        json.dump({"total_count": 1, "check_runs": CHECK_RUNS_CLEAN}, handle)
    with tempfile.TemporaryDirectory() as tmp:
        status_file = Path(tmp) / "status.json"
        out_file = Path(tmp) / "audit.json"
        status_file.write_text(json.dumps(COMBINED_STATUS_EMPTY), encoding="utf-8")
        proc = subprocess.run(
            [
                sys.executable,
                str(GUARD),
                "--sha",
                "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "--repo",
                "example/example",
                "--check-runs-file",
                envelope_fixture,
                "--status-file",
                str(status_file),
                "--json-out",
                str(out_file),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        expect(
            "raw gh api envelope fixture unwraps and passes",
            proc.returncode == 0 and "CLEAN" in proc.stdout,
            f"exit={proc.returncode} out={proc.stdout!r}",
        )

    print("All merge-audit self-tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
