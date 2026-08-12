#!/usr/bin/env python3
"""Fail closed when Keeper real-world credentials can reach an untrusted ref."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RUNNER = ROOT / "scripts" / "ci" / "run-keeper-realworld-acceptance.sh"


def fail(message: str) -> None:
    print(f"keeper-realworld-secret-boundary: {message}", file=sys.stderr)
    raise SystemExit(1)


def indented_block(text: str, header: str, indent: int) -> str:
    marker = " " * indent + header
    start = text.find(marker)
    if start < 0:
        fail(f"missing block: {header}")
    remainder = text[start + len(marker) :]
    next_header = re.search(rf"^{' ' * indent}\S", remainder, re.MULTILINE)
    end = start + len(marker) + (next_header.start() if next_header else len(remainder))
    return text[start:end]


def require(block: str, needle: str, context: str) -> None:
    if needle not in block:
        fail(f"{context} is missing {needle!r}")


workflow = WORKFLOW.read_text(encoding="utf-8")
runner = RUNNER.read_text(encoding="utf-8")

live_gate = indented_block(workflow, "pr-live-gate:", 2)
changes = indented_block(workflow, "changes:", 2)
acceptance = indented_block(workflow, "keeper-realworld-acceptance:", 2)
product_gate = indented_block(workflow, "keeper-realworld-gate:", 2)
package_step = indented_block(
    workflow, "- name: Package exact-revision Keeper acceptance runtime", 6
)
upload_step = indented_block(
    workflow, "- name: Upload exact-revision Keeper acceptance runtime", 6
)

for context, block in (
    ("PR live gate", live_gate),
    ("acceptance job", acceptance),
    ("runtime package step", package_step),
    ("runtime upload step", upload_step),
    ("product gate", product_gate),
):
    require(block, "refs/heads/main", context)
    require(block, "ref_protected", context)

for trusted_event in ("push", "workflow_dispatch"):
    require(
        acceptance,
        f"github.event_name == '{trusted_event}'",
        "acceptance job",
    )
if "github.event_name == 'pull_request'" in acceptance:
    fail("acceptance job still admits pull_request refs")
require(acceptance, "ZAI_API_KEY_SB: ${{ secrets.ZAI_API_KEY_SB }}", "acceptance job")
if workflow.count("ZAI_API_KEY_SB: ${{ secrets.ZAI_API_KEY_SB }}") != 1:
    fail("CI workflow must expose ZAI_API_KEY_SB in exactly one guarded job")

for main_push_guard in (
    '${GITHUB_EVENT_NAME}" = "push"',
    '${GITHUB_REF}" = "refs/heads/main"',
    "keeper_realworld=true",
):
    require(changes, main_push_guard, "protected-main acceptance obligation")

for context, block in (
    ("runtime package step", package_step),
    ("runtime upload step", upload_step),
):
    for trusted_event in ("push", "workflow_dispatch"):
        require(block, f"github.event_name == '{trusted_event}'", context)
    if "github.event_name == 'pull_request'" in block:
        fail(f"{context} still admits pull_request refs")

for field in (
    "masc.keeper_acceptance_runtime.v2",
    "source_ref",
    "source_ref_protected",
    "workflow_ref",
    "workflow_sha",
):
    require(package_step, field, "runtime manifest")

for evidence in (
    '"$EVENT_NAME" = "push"',
    '"$EVENT_NAME" = "workflow_dispatch"',
    "EVENT_REF_PROTECTED",
    "EVENT_WORKFLOW_REF",
    "EVENT_WORKFLOW_SHA",
):
    require(product_gate, evidence, "product gate")

for check in (
    "KEEPER_ACCEPTANCE_EXPECTED_EVENT",
    "KEEPER_ACCEPTANCE_EXPECTED_REF",
    "KEEPER_ACCEPTANCE_EXPECTED_REF_PROTECTED",
    "KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_REF",
    "KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_SHA",
    "masc.keeper_acceptance_runtime.v2",
    "manifest_event",
    "manifest_ref_protected",
    "manifest_workflow_ref",
    "manifest_workflow_sha",
):
    require(runner, check, "acceptance runner")

print("keeper-realworld-secret-boundary: OK")
