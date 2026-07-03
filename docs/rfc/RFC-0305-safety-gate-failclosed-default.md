---
rfc: "0305"
title: "Safety and governance gates fail closed by default"
status: Draft
created: 2026-07-04
updated: 2026-07-04
author: vincent
supersedes: []
superseded_by: null
related: ["0304"]
implementation_prs:
  - "#23092" # Site I — dashboard approval-resolve fail-closed default
  - "#23044/#23086 follow-up" # reconcile stale `test_oas_callback_hard_forbidden_queues_critical` with immediate-reject behavior
---

# RFC-0305 — Safety and governance gates fail closed by default

## 1. Problem

A safety gate that **fails open** — approves, allows, or proceeds when its check
cannot run — provides no protection in exactly the situation it exists for. The
gate silently becomes a no-op the moment its evaluator is unavailable, its input
is malformed, or a capability measurement is missing.

The motivating case, grounded on a live config snapshot and 2026-07-03 logs:

- `lib/task/anti_rationalization.ml` is the excuse-detection gate. When its LLM
  evaluator is unavailable it consults `Env_config.AntiRationalization.fail_mode`,
  whose default is **`Open`** (`lib/config/env_config_governance.ml:180` `| _ -> Open`,
  `:188` `get_string ~default:"open" "MASC_ANTI_RATIONALIZATION_FAIL_MODE"`).
- With `fail_mode = Open` and no active gate-2 substring advisory, an unavailable
  evaluator emits `verdict = Approve` (`lib/task/anti_rationalization.ml:1032-1043`,
  `"approving by default; mode=open"`).
- The default runtime (`[runtime].default = glm-coding.glm-5-turbo`) is a `Glm`
  provider kind, which OAS `validate_output_schema_request` rejects for native
  `json_schema` ("Glm supports JSON mode only"). The anti-rationalization schema
  request therefore returns `LLM unavailable` on every autonomous cycle routed to
  the default — observed **32 times** on 2026-07-03 (last `13:28Z`). Each one
  auto-approved by the fail-open policy. The `runtime.toml` comment above
  `[runtime].default` already records the same failure mode from an earlier
  outage: *"returned empty 10/20 times today and auto-approved by liveness
  (#8688)."*

The excuse-detection safety check is bypassed precisely when it cannot evaluate.

### 1.1 This is not one bug — but the codebase is already mostly fail-closed

Two read-only surveys of `lib/` (governance/verifier and keeper/tool-guard
domains) found the fail-open default is the **exception**, not the norm. The
principle is already applied nearly everywhere; a handful of sites deviate from
it. That makes this an alignment RFC, not a new mandate.

Deviations found (fail-open where a safety decision cannot complete):

| # | Site | Gate | Fail-open mechanism | Active? |
|---|------|------|---------------------|---------|
| A | `lib/config/env_config_governance.ml:180,188` + `lib/task/anti_rationalization.ml:1032` | excuse detection | `fail_mode` default `open` → `Approve` | **yes** |
| B | `lib/keeper_runtime/keeper_fd_pressure.ml:552` | fleet turn admission | `system_fds = None -> Admit` (siblings :535/:561 block) | yes |
| C | `lib/eval_gate.ml:262,348` | destructive-command scan | malformed JSON args → `""` → no match → `Pass` | yes |
| D | `lib/eval_gate.ml:203` | destructive evasion detect | regex evaluator error → `false` → passes | yes |
| E | `lib/worker_oas.ml:262`, `lib/keeper/keeper_guards.ml:157` | command extraction | payload under unexpected field → `""` → not screened | yes |
| F | `lib/governance_pipeline_risk.ml:129,337` | approval risk classify | unknown tool/verb → `Low` → below HITL threshold | yes |
| G | `lib/sdk_tool_contract.ml:245` | tool input schema | unknown JSON-Schema `type` → `Ok ()` (accepted) | yes |
| H | `lib/tool_surface/tool_capability.ml:52` | destructive capability filter | no `destructive` metadata → treated non-destructive → scan skipped | yes |
| I | `lib/server/server_dashboard_http.ml:318-326` | HITL approval-resolve endpoint | missing `decision` field → `~default:"approve"` | yes |
| J | `lib/verifier_oas.ml:229-232` | PreToolUse LLM verify | verifier backend error → `Continue` (allow) | dormant (no callers) |
| K | `lib/verification.ml:315-333` | criterion evaluator | empty criteria / schema-only → `Pass` | dormant (no callers) |

Counter-examples — sites that already fail closed, establishing the norm:

- `lib/approval_callbacks.ml:14-31` — MASC's default approval callback returns
  `Reject`, **explicitly overriding OAS's fail-open default** (#7883). This is a
  direct in-tree precedent for the principle.
- `lib/keeper_runtime/keeper_disk_pressure.ml:268` — unmeasurable disk → `Block`.
- `lib/keeper_runtime/keeper_fd_pressure.ml:535,561` — unknown fd probe →
  `probe_unknown_block`. (This makes site B, in the same module, the outlier.)
- `lib/governance_pipeline.ml:54-68,545-564` — unknown `governance_level` → require
  confirm; no matching approval rule → block via HITL.
- `lib/keeper/keeper_approval_queue.ml:97` + rules types — HITL approval
  timeout/expiry → `reject` (fails closed on operator non-response).
- `lib/server/server_dashboard_http_link_preview.ml:131-135` — unparseable IP →
  treated private/reserved → blocked (SSRF guard).
- `lib/mcp_server_eio_protocol.ml:963-973` — exhaustive `tool_profile` match
  deliberately avoids `_ -> Full` to prevent silently elevating a future
  restricted profile to full tool access.
- `lib/tool_input_validation.ml:29` — tool with no registered schema → rejected.

## 2. Principle

> A gate whose purpose is to **prevent** an unsafe action must, when it cannot
> reach a verdict, resolve to the **safe** outcome (block / pause / reject /
> require-approval), not the permissive one. "Cannot reach a verdict" includes:
> evaluator unavailable or errored, input unparseable, a required capability or
> measurement absent, or an unknown/unmodeled variant.

This is the gate-level specialization of the existing CLAUDE.md boundary rule
"unknown input → typed error / None, never a permissive default" (AI code-gen
anti-pattern #2). It is already the codebase norm; this RFC names it so the
deviations in §1.1 can be closed and future gates can be reviewed against it.

### 2.1 The real trade-off (why this is not automatic)

Fail-closed is not free. #10474 introduced the anti-rationalization fail-open
default for a concrete reason: *"do not block every agent waiting for a runtime
fix."* A runtime outage that makes the evaluator unavailable would, under strict
fail-closed, halt every keeper turn that passes through that gate — converting a
degraded-evaluation condition into a full fleet stall. The preflight/compaction
memory note (`#22925` recovery-preemption) is the same tension: a guard that
blocks before recovery is exhausted creates a "constraint hell."

So the principle must be paired with a bounded escape, not applied blindly:

1. **Default fail-closed.** The unconfigured behavior is the safe outcome.
2. **Explicit, logged operator opt-out.** An operator may set a gate to
   fail-open (e.g. `MASC_ANTI_RATIONALIZATION_FAIL_MODE=open`) during a known
   outage. The choice is visible and emits the existing fallback counter.
3. **Prefer degrade-in-place over hard block where a cheaper safe path exists.**
   The excuse-detection gate already has one: the gate-2 substring advisory
   (`lib/task/anti_rationalization.ml:944-967`) rejects on a detected excuse phrase even
   when the LLM is down. Fail-closed should reuse such advisories, reserving a
   hard reject for the residual case. This narrows the fleet-stall blast radius.
4. **Block only after recovery is exhausted** (the `#22925` rule): a gate that
   sits downstream of compaction/rotation should fail closed on the *post-recovery*
   estimate, not preempt the recovery path.

## 3. Scope

In scope — bring the §1.1 deviations to fail-closed default, keeping an explicit
opt-out where a fleet-stall risk is real:

- **A (anti-rationalization `fail_mode`)**: flip the default from `Open` to
  `Closed`. Operators who need liveness during an outage set
  `MASC_ANTI_RATIONALIZATION_FAIL_MODE=open` explicitly. The `Closed` branch
  (`lib/task/anti_rationalization.ml:1046`, `Reject "verifier unavailable (fail-closed)"`)
  and the gate-2 advisory already exist; only the default changes.
- **B (fd-pressure admission)**: `system_fds = None -> probe_unknown_block`,
  matching the two sibling branches in the same function.
- **C/D/E (destructive-command path)**: a shared `Reject` (or `Trajectory` fail)
  when command extraction or args-JSON parsing fails, instead of scanning an
  empty string. One helper closes all three (they share `lib/eval_gate` +
  `lib/worker_oas`/`lib/keeper/keeper_guards`).
- **F (risk classify unknown → Low)**: unknown tool/verb → a risk floor that
  still requires confirm, not `Low`. Mirror `lib/governance_pipeline.ml`'s
  unknown-level → require-confirm.
- **G (tool schema unknown type)**: unknown JSON-Schema `type` → `Error`, mirror
  the fail-closed sibling `param_type_of_schema_opt` (#8832).
- **H (destructive capability metadata)**: a tool with no `destructive` tag is
  screened (or explicitly tagged), not silently skipped. Requires deciding the
  default tag or forcing tagging at registration.
- **I (dashboard approve default)**: a resolve request missing `decision` →
  `Error`, not `~default:"approve"`.

### 3.1 Hard-forbidden OAS callback disposition

Hard-forbidden OAS callbacks (`lib/governance_pipeline.ml:323`
`reject_hard_forbidden`, invoked at `:409` whenever
`auto_approval_hard_forbidden` is true) are **immediately rejected** and never
enter the HITL operator approval queue. A Critical-risk tool or a
runtime-contract-blocked tool cannot be rescued by an operator approve action
or a remembered rule; the callback returns `Agent_sdk.Hooks.Reject` as a
terminal event.

> **Note (SSOT reconciliation):**
> `test/test_governance_pipeline.ml:1025`
> `test_oas_callback_hard_forbidden_queues_critical` currently expects a Critical
> hard-forbidden callback to be queued and to pass on operator approval. That
> expectation is stale after the immediate-reject behavior merged in #23086; the
> test must be updated in the follow-up PR that reconciles #23044 with #23086
> (see `implementation_prs`).

### 3.2 Fail-closed disposition map

| Gate category | Trigger | Disposition | Reference |
|---|---|---|---|
| Hard-forbidden OAS callback | `auto_approval_hard_forbidden` true | Immediate `Reject`; never queued | `lib/governance_pipeline.ml:323`, `:409` |
| Excuse detection (A) | evaluator unavailable, no gate-2 advisory | `Reject` | `lib/task/anti_rationalization.ml:1046` |
| FD-pressure admission (B) | `system_fds = None` | `probe_unknown_block` | `lib/keeper_runtime/keeper_fd_pressure.ml:552` |
| Destructive-command scan (C/D/E) | malformed JSON args / regex error / unexpected payload field | `Reject` | `lib/eval_gate.ml:203,262,348`; `lib/worker_oas.ml:262`; `lib/keeper/keeper_guards.ml:157` |
| Risk classify unknown (F) | unknown tool/verb | require confirm | `lib/governance_pipeline_risk.ml:129,337` |
| Tool schema unknown type (G) | unknown JSON-Schema `type` | `Error` | `lib/sdk_tool_contract.ml:245` |
| Destructive capability metadata (H) | missing `destructive` tag | screen or require explicit tag | `lib/tool_surface/tool_capability.ml:52` |
| Dashboard approve default (I) | missing `decision` field | `Error` | `lib/server/server_dashboard_http.ml:318-326` |

Out of scope (noted, not mandated here):

- **J/K (dormant verifier/verification facilities)**: no callers today. Fix when
  wired, or delete if dead. Recorded so they are not wired as-is.
- **Trust-ledger `~default:true` inputs** (`lib/reputation_ledger_v2.ml:151-152`,
  `lib/tool_agent_timeline.ml:313`, `lib/keeper/keeper_runtime_trust_timeline.ml:112`): these
  feed scoring, not hard gates. A separate decision on whether absent trust
  signals should read as good-vs-unknown; deliberately not bundled.
- **`lib/exec/approval_config.ml:47-52` autonomous overlay**: `Observe`-everything
  by design, backstopped by a trust-independent catastrophic floor in
  `Approval_policy.decide`. In scope only if that floor is found insufficient.

## 4. Non-goals

- Not a blanket "reject on any error." Advisory/telemetry-only gates that are
  documented as non-enforcing (e.g. `lib/keeper/keeper_guards.ml:842` `cost_guard`) stay
  advisory.
- Not removing operator opt-out. The opt-out is the mechanism that makes
  fail-closed operationally viable during outages.
- Not a runtime hot-reload change. These are startup-config / code defaults.

## 5. Implementation plan

Per-site, each is a small, independently reviewable change with a test that
drives the unavailable/unparsable path and asserts the safe outcome. Sequence by
blast radius, smallest first:

1. **I, G, C/D/E** — pure fail-closed on malformed/unknown input. No fleet-stall
   risk (malformed input is not a normal path). Each gets a unit test:
   malformed → reject.
2. **B** — one-line, aligns with in-module siblings; test: `system_fds = None`
   → admission blocked.
3. **F, H** — risk/capability defaults; wider behavioral surface, needs a sweep
   of currently-unclassified tools so nothing legitimate is newly blocked.
4. **A** — the default flip. Highest fleet-stall exposure, so it lands last and
   with the opt-out documented in `runtime.toml` and an operator runbook note.
   Verify the gate-2 advisory + `Closed` branch cover the common excuse cases so
   a routine outage degrades rather than hard-stalls.

Each item is its own PR referencing this RFC. The RFC merges first; the default
flip (A) does not merge until the routing fix (anti-rationalization off a
`json_schema`-incapable default runtime) is in place, so the flip does not
convert a config gap into a fleet stall on day one.

## 6. Verification

- Per-site unit test on the unavailable/unparsable branch asserting the safe
  outcome (the mutation-test discipline: the test must fail on the pre-fix
  fail-open form).
- A grep-based ratchet candidate (follow-up): flag new `| _ -> (Approve|Allow|
  Admit|Continue|Pass)` / `~default:"approve"|"open"|true` introduced in
  gate/guard/governance modules, so the principle does not silently regress. Not
  required for this RFC to land; proposed as a Meta Guard once the §3 sites are
  closed.

## 7. Open questions

- **H** (Open — deferred to implementation PR): should the default
  `destructive` tag be "screen it" (fail-closed, possibly over-screening) or
  should registration force an explicit tag (fail-closed via compile/registration
  error)? The latter is stronger but touches every tool definition.
- **A opt-out surfacing**: the fail-open opt-out is currently an env var. Should
  an active `=open` override surface in the dashboard governance view (like
  RFC runtime-note-field) so an operator does not forget a temporary outage
  setting is still on?
- Should the trust-ledger `~default:true` inputs (§3 out-of-scope) be a
  follow-up RFC, or folded in once the hard gates are closed?
