"""Record old/new guard consumption against real temporary Git histories."""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1]).resolve()
# Parent of the original diff-binding change, reachable from this PR's history.
baseline = "1f1cd345b3f81459004371b53ca647433df31dce"
spec = importlib.util.spec_from_file_location("policy", root / "scripts/review/test_source_review_policy.py")
assert spec and spec.loader
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
records = {}
with tempfile.TemporaryDirectory() as temp:
    old = Path(temp)
    for name in ("approve-guard.sh", "ci-checks.sh", "review-verdict.sh"):
        data = subprocess.check_output(["git", "--no-replace-objects", "-C", str(root), "show", f"{baseline}:scripts/review/{name}"])
        (old / name).write_bytes(data)
    fixture = policy.SourceReviewPolicy()
    fixture.setUp()
    try:
        body = fixture.root / "body"
        body.write_text(f"verdict: PASS head: {policy.HEAD} by: independent\nReviewed the feature files.")
        fixture.fixture.write_text(json.dumps(fixture.state))
        args = ["bash", str(old / "approve-guard.sh"), "--repo", "team/repo", "--pr", "1", "--head", policy.HEAD]
        posted = subprocess.run([*args, "--body", str(body)], env=fixture.env, text=True, capture_output=True, check=False)
        assert posted.returncode == 0, posted.stderr
        fixture.state = json.loads(fixture.fixture.read_text())
        old_body = fixture.state["posted"]["body"]
        fixture.state.update(base="older-parent", base_sha=policy.OTHER)
        fixture.fixture.write_text(json.dumps(fixture.state))
        consumed = subprocess.run([*args, "--merge-check", "--receipt-json"], env=fixture.env, text=True, capture_output=True, check=False)
        assert consumed.returncode == 0, consumed.stderr
        records["old"] = {"source": baseline,
            "head":policy.HEAD, "reviewed_base":fixture.base, "retargeted_base":policy.OTHER,
            "old_diff":fixture.digest, "changed_diff":fixture.identity(policy.OTHER),
            "approval_body":old_body, "exit":consumed.returncode, "stdout":consumed.stdout,
            "expected_exit":2, "control":"old guard incorrectly accepts changed diff"}
    finally:
        fixture.doCleanups()
    fixture = policy.SourceReviewPolicy()
    fixture.setUp()
    try:
        body = fixture.root / "body"
        body.write_text(f"verdict: PASS head: {policy.HEAD} by: independent\nReviewed both feature files.")
        produced = fixture.invoke("approve-guard.sh", "--body", str(body))
        assert produced.returncode == 0, produced.stderr
        fixture.state = json.loads(fixture.fixture.read_text())
        bound_body = fixture.state["posted"]["body"]
        outcomes = {}
        for label, base in (("unchanged",fixture.base), ("retarget-expanded",policy.OTHER),
                            ("parent-landed-narrowed",fixture.narrowed_base)):
            fixture.state["base_sha"] = base
            result = fixture.invoke("approve-guard.sh", "--merge-check", "--receipt-json")
            expected = 0 if label == "unchanged" else 2
            assert result.returncode == expected, result.stdout + result.stderr
            outcomes[label] = {"base":base, "diff":fixture.identity(base), "exit":result.returncode,
                               "stdout":result.stdout, "stderr":result.stderr}
        fixture.git("checkout", "-qb", "unrelated-base", fixture.base)
        fixture.commit_file("unrelated.txt", "base moved but the PR change stayed the same")
        moved_base = fixture.git("rev-parse", "HEAD")
        fixture.state.update(base="renamed-parent",base_sha=moved_base)
        result = fixture.invoke("approve-guard.sh","--merge-check","--receipt-json")
        assert result.returncode == 0, result.stderr
        outcomes["moved-base-identical-diff"] = {"base":moved_base, "diff":fixture.identity(moved_base),
            "exit":result.returncode, "stdout":result.stdout, "stderr":result.stderr}
        records["new"] = {"head":policy.HEAD, "reviewed_base":fixture.base,
            "approval_body":bound_body, "outcomes":outcomes,
            "original_approval_preserved":json.loads(fixture.fixture.read_text())["posted"]["body"] == bound_body,
            "actions_requests":[line for line in fixture.calls.read_text().splitlines() if "/actions/" in line]}
    finally:
        fixture.doCleanups()
print(json.dumps(records, indent=2))
