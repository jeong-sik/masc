#!/usr/bin/env python3
"""Self-test for check-stale-base-revert.py (RFC-0235).

Reconstructs the 2026-06-12 stale-base topology in throwaway git repos
and asserts the guard fires on the real defect shape while staying quiet
on the legitimate ones. The synthetic repo *is* the harness: the guard's
detection semantics are proven by construction, not by prose argument.

Run directly: `python3 scripts/ci/test_check_stale_base_revert.py`
Exits 0 on success, 1 on the first failed expectation.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPO_ROOT / "scripts" / "ci" / "check-stale-base-revert.py"

# Eight substantial, distinct lines — like the telemetry block #20853
# added. Each is long and identifier-bearing so the guard counts it.
MAIN_ADDED = [f"let telemetry_store_handle_{i} = Dated_jsonl.create ()" for i in range(8)]


def git(repo: Path, *args: str, env_extra: dict[str, str] | None = None) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t",
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    if env_extra:
        env.update(env_extra)
    out = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True, env=env,
    )
    return out.stdout.strip()


def init_repo(repo: Path) -> None:
    # --template='' skips any globally configured init.templateDir so the
    # throwaway repo does not inherit commit-blocking hooks from the host.
    git(repo, "init", "-q", "-b", "main", "--template=")
    git(repo, "config", "core.hooksPath", "/dev/null")
    git(repo, "config", "commit.gpgsign", "false")


def write(repo: Path, rel: str, lines: list[str]) -> None:
    (repo / rel).write_text("\n".join(lines) + "\n")


def commit_all(repo: Path, msg: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", msg)
    return git(repo, "rev-parse", "HEAD")


def run_guard(repo: Path, base: str, head: str,
              labels: str = "") -> tuple[int, str, str]:
    env = {**os.environ, "PR_LABELS": labels}
    res = subprocess.run(
        [sys.executable, str(GUARD), "--base", base, "--head", head],
        cwd=str(repo), capture_output=True, text=True, env=env,
    )
    return res.returncode, res.stdout, res.stderr


def _build_base(repo: Path) -> str:
    """Common ancestor: F=[a,b,c], G=[g]. Returns the merge-base SHA."""
    init_repo(repo)
    write(repo, "F.ml", ["let a = 1", "let b = 2", "let c = 3"])
    write(repo, "G.ml", ["let g = 0"])
    return commit_all(repo, "base")


def _advance_main(repo: Path) -> str:
    """On main, add the eight substantial lines to F."""
    write(repo, "F.ml",
          ["let a = 1", "let b = 2", "let c = 3", *MAIN_ADDED])
    return commit_all(repo, "feat: add telemetry block to F (sibling PR)")


# --- scenarios ---------------------------------------------------------

def scenario_fire(repo: Path) -> tuple[int, str, str]:
    """Stale-base PR: branches at base, edits F but never gets main's
    additions. Merging would revert the eight lines."""
    base_sha = _build_base(repo)
    main_tip = _advance_main(repo)
    git(repo, "checkout", "-q", "-b", "feature", base_sha)
    # The PR touches F (so it is a candidate) but from the stale base —
    # its F lacks MAIN_ADDED entirely.
    write(repo, "F.ml", ["let a = 1", "let b = 2", "let c = 3", "let feat = 9"])
    feat_tip = commit_all(repo, "feature: tweak F from stale base")
    return run_guard(repo, base=main_tip, head=feat_tip)


def scenario_rebased(repo: Path) -> tuple[int, str, str]:
    """PR carries main's additions (as after a rebase): nothing missing."""
    _build_base(repo)
    main_tip = _advance_main(repo)
    git(repo, "checkout", "-q", "-b", "feature", main_tip)
    write(repo, "F.ml",
          ["let a = 1", "let b = 2", "let c = 3", *MAIN_ADDED, "let feat = 9"])
    feat_tip = commit_all(repo, "feature: tweak F on top of main")
    return run_guard(repo, base=main_tip, head=feat_tip)


def scenario_disjoint(repo: Path) -> tuple[int, str, str]:
    """PR edits a different file than main did: no overlap, no risk."""
    base_sha = _build_base(repo)
    main_tip = _advance_main(repo)
    git(repo, "checkout", "-q", "-b", "feature", base_sha)
    write(repo, "G.ml", ["let g = 0", "let g2 = 1"])
    feat_tip = commit_all(repo, "feature: edit G only")
    return run_guard(repo, base=main_tip, head=feat_tip)


def scenario_acked(repo: Path) -> tuple[int, str, str]:
    """Fire topology, but the operator labeled it an intentional revert."""
    base_sha = _build_base(repo)
    main_tip = _advance_main(repo)
    git(repo, "checkout", "-q", "-b", "feature", base_sha)
    write(repo, "F.ml", ["let a = 1", "let b = 2", "let c = 3", "let feat = 9"])
    feat_tip = commit_all(repo, "feature: deliberate revert of telemetry block")
    return run_guard(repo, base=main_tip, head=feat_tip, labels="stale-base-ack")


def main() -> int:
    cases = [
        ("fire: stale-base PR reverts main", scenario_fire, 1,
         "absent"),
        ("pass: PR has main's additions", scenario_rebased, 0,
         "no stale-base reversal"),
        ("pass: PR edits a disjoint file", scenario_disjoint, 0,
         "no stale-base reversal"),
        ("pass: intentional revert acked", scenario_acked, 0,
         "acknowledged"),
    ]
    failures = 0
    for name, fn, want_code, want_substr in cases:
        with tempfile.TemporaryDirectory() as d:
            code, out, err = fn(Path(d))
        combined = out + err
        ok = code == want_code and want_substr in combined
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {name} (exit={code}, want={want_code})")
        if not ok:
            failures += 1
            print(f"        expected substring: {want_substr!r}")
            print("        --- stdout ---")
            print("\n".join("        " + l for l in out.splitlines()))
            print("        --- stderr ---")
            print("\n".join("        " + l for l in err.splitlines()))
    if failures:
        print(f"\n{failures} self-test(s) failed.")
        return 1
    print("\nAll stale-base guard self-tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
