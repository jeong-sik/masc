---
status: runbook
last_verified: 2026-05-13
code_refs:
  - scripts/keeper-production-readiness-gate.py
  - scripts/keeper-runtime-truth-gate.sh
  - docs/RELEASE-EVIDENCE.md
  - docs/PERFORMANCE-SLO.md
---

# Production Readiness Gates

`production-ready` is a quantitative claim.  A release or feature promotion
needs all gates below attached to the PR, release evidence, or operator handoff.
Focused unit tests and green draft checks are useful, but they are not enough by
themselves.

## Gate 1: Release Artifact

Command:

```bash
scripts/release-evidence.sh _build/default/bin/main_eio.exe .release-evidence/local-release-evidence.md
```

Threshold:

| metric | required value |
|---|---:|
| binary install smoke | PASS |
| `/health` response | PASS |
| MCP `initialize` | PASS |
| MCP `tools/list` tool count | > 0 |
| `masc_status` read path | PASS |
| dashboard `mission` read path | PASS |
| dashboard `namespace-truth` read path | PASS |

## Gate 2: Keeper Turn Evidence Chain

Command:

```bash
scripts/keeper-production-readiness-gate.py \
  --base-path /Users/dancer/me \
  --keeper <keeper-name> \
  --min-terminal-turns 3 \
  --min-success-turns 3 \
  --output .release-evidence/keeper-production-readiness.json
```

Default thresholds:

| metric | required value |
|---|---:|
| terminal turns | >= 3 |
| successful turns | >= 3 |
| receipt coverage | 100% |
| checkpoint coverage for successful provider turns | 100% |
| provider attempt closure | 100% |
| event-bus correlation coverage | 100% |
| memory-injection coverage | 100% |
| tool-log coverage when tools are used | 100% |
| timestamp parse coverage | 100% |
| missing linked artifacts | 0 |
| timestamp/order violations | 0 |
| dangling provider attempts | 0 |
| max evidence span per turn | <= 600 seconds |

This gate is intentionally stricter than `keeper-runtime-truth-gate.sh`.  The
runtime-truth gate proves one turn.  The production gate proves a minimum sample
of terminal turns and reports percentages that can be compared across releases.

## Gate 3: Performance SLO

Use `docs/PERFORMANCE-SLO.md` as the source of truth.

Required thresholds:

| lane | required value |
|---|---:|
| established MCP JSON-RPC P95 | < 300 ms |
| established MCP JSON-RPC P99 | < 800 ms |
| REST `/api/v1/status` P95 | < 150 ms |
| REST `/api/v1/tasks?limit=50` P95 | < 250 ms |
| REST `/api/v1/messages?limit=20` P95 | < 250 ms |
| SSE connection success | < 1 second |
| SSE delivery P95 | < 500 ms |
| SSE reconnect/drop count | < 3 per 5 minutes |

If a live environment cannot run the performance harness, the release evidence
must say `blocked` or `not evaluated`; it must not silently treat missing
performance data as green.

## Gate 4: OAS Pin And Boundary

Commands:

```bash
scripts/check-oas-pin.sh --local-only
scripts/oas-drift-check.sh
```

Threshold:

| metric | required value |
|---|---:|
| declared OAS base version | matches installed `agent_sdk` |
| declared OAS SHA | matches local or remote API surface |
| OAS API fingerprint drift | 0 |
| MASC-specific semantics added to OAS | 0 |

OAS remains the generic runtime/proof layer.  MASC owns keeper runtime evidence,
operator semantics, and product promotion gates.

## Promotion Rule

The product is production-ready only when every gate above is attached and
passes.  Missing data is a blocker, not a pass.  A draft PR with local focused
checks is a candidate for production-readiness validation, not the validation
itself.
