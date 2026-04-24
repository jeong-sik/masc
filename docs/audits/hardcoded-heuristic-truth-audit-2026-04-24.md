# Hardcoded / Heuristic Truth Audit - 2026-04-24

Scope: active `masc-mcp` source, tests, scripts, and CI surfaces. The goal is to
separate confirmed semantic debt from broad grep noise, then remove the most
dangerous hardcoded boundary.

## Confirmed Findings

### Fixed in this branch: main-worktree mutation boundary

`lib/keeper/keeper_tool_registry.ml` used to decide whether a mutating tool
should bypass the main-worktree boundary by matching concrete tool names. That
was a real drift risk: coordination aliases and keeper aliases could diverge
without compiler help.

This branch moves the decision to typed `Tool_catalog.effect_domain` metadata:

- `Read_only`
- `Masc_coordination`
- `Playground_write`
- `Main_worktree_write`

`Keeper_tool_registry.is_main_worktree_boundary_exempt_with_input` now delegates
to `Tool_catalog.is_main_worktree_boundary_exempt` after the existing input-aware
read-only checks.

### Still confirmed: keeper agent affordance grouping

`lib/keeper/keeper_agent_run.ml` still has string-derived tool grouping and
fallback surfaces (`tool_required_affordances`, `String.starts_with`,
`fallback_tool_surface`, `is_claim_only_turn`). This should be migrated to the
same typed metadata/catalog pattern rather than adding more name checks.

### Still confirmed: provider label heuristics

`lib/provider_adapter.ml` still infers provider identity from model labels and
hardcoded CLI provider names in telemetry/metring logic. The current behavior is
not the same blast radius as dispatch safety, but it is still heuristic and
should be replaced by provider capability metadata.

### Still confirmed: advisory CI bug-class gates

`.github/workflows/ci.yml` keeps the meta bug-class gates advisory via
`continue-on-error: true` and `|| true`. This is visible now through
`scripts/audit-hardcoding-truth.sh`, but the existing gates are not merge
blockers.

### Improved: anti-fake detector noise

`scripts/anti-fake-audit.sh` now recognizes common Alcotest forms such as
unqualified `check bool` and classifies CLI/distributed harness files separately
from fake tests. This reduces false positives where real assertions were hidden
behind OCaml open/module style rather than the exact `Alcotest.` string.

## New Audit Surface

Run:

```bash
bash scripts/audit-hardcoding-truth.sh
```

Optional strict mode:

```bash
bash scripts/audit-hardcoding-truth.sh --fail-on-confirmed
```

The default mode is non-blocking so it can run in CI and preserve visibility
while the remaining confirmed debt is paid down incrementally.

## Verification

Executed in this branch:

```bash
bash scripts/anti-fake-audit.sh
# Good: 445, Suspect: 2, Fake: 0, Harness: 9, Total: 456

bash scripts/audit-hardcoding-truth.sh
# Status: findings
# Confirmed active issue groups: 3
#   1. keeper_agent_run string-derived affordance grouping
#   2. provider_adapter provider/model heuristics
#   3. advisory CI bug-class gates

bash scripts/lint/no-unknown-permissive-default.sh
# Scanned 738 .ml files. No #8605 family violations found.

bash scripts/ci/check-enum-string-safety.sh
# STR gate: PASS

scripts/dune-local.sh build @check
# PASS

scripts/dune-local.sh exec ./test/test_tool_spec.exe
# PASS, 14 tests
```

`scripts/dune-local.sh exec ./test/test_keeper_github_read_only.exe` was started
as an extra focused check but was stopped while waiting behind unrelated global
`/tmp/me-dune-local.lock` holders. The boundary code is type-checked by the
successful `@check` run above; this extra executable run should be retried when
the lock is free.

After the successful `@check`, one unused helper introduced by the branch was
removed. A second `@check` rerun was attempted and stopped while waiting behind
the same unrelated global dune lock holders; `rg "playground_write_tool"` now
returns no references.
