# Keeper Autonomy Proof Harness — design

Status: Draft (2026-05-17)
Owner: vincent
Related issues: #13534 (parent), #13567, #13568, #13569

## Purpose

Answer one operational question continuously and verifiably:

> 모든 keeper-facing feature 에 대해 *실제 keeper 가 자율적으로* 사용한 증거가 있는가?

Today the answer is split: autonomous use itself is proven, but *every-feature* coverage is not. The three open sub-issues (#13567 policy denials, #13568 sandbox/precondition failures, #13569 zero-evidence tool surfaces) each describe a different reason a feature fails the proof contract. A single harness that classifies failures by reason and produces an artifact that can be replayed across sessions is needed before #13534 can close.

## Scope

In:
- Data model for "proof receipt" (one tool call with autonomous attribution)
- Collection pipeline (which logs / which fields / which filters)
- Three classification tracks aligned to existing sub-issues
- Reporting surface (cli tool + dashboard panel)
- Replay invariant — proof must be reconstructible from `<base-path>/.masc/logs/` alone

Out:
- Fixing the feature gaps themselves (that's per-feature follow-up)
- Operator-attributed receipts (different question)
- Cross-keeper consensus / quorum proofs (separate RFC)

## Data model

A `proof_receipt` is one tool call by one keeper, attributed autonomous, with success outcome and bounded payload fingerprint:

```ocaml
type proof_receipt = {
  ts : float;
  keeper_id : string;
  tool_name : string;
  turn_id : int;
  attribution : [`Autonomous | `Operator_triggered | `Cascade_routed];
  outcome : [`Success | `Approval_required | `Policy_denied
            | `Precondition_failed | `Sandbox_path_error
            | `Zero_evidence_placeholder];
  fingerprint : string;  (* bounded slice of input args, no PII *)
}
```

The outcome variants are intentionally aligned to the three sub-issue tracks:
- `Approval_required` + `Policy_denied` → #13567 track
- `Precondition_failed` + `Sandbox_path_error` → #13568 track
- `Zero_evidence_placeholder` → #13569 track (synthesized when a registered tool has never produced any non-placeholder receipt)
- `Success` is the only variant that *counts* against the proof contract

## Collection pipeline

Source: `<base-path>/.masc/logs/system_log_<date>.jsonl` (authoritative) + `decisions.jsonl` (turn boundary).

Step 1 — filter tool-call events with `attribution=autonomous` (already tagged by `Keeper_attribution.classify` in current code).

Step 2 — join against turn boundary to recover `turn_id`.

Step 3 — map raw error message to typed outcome using:
- new `Keeper_path_check_error.parse_prefix` (PR #15684) for path-error class
- `Keeper_failure_circuit_breaker.classify_error` for policy / approval / shell-exit class (substring grep — separate cleanup once that module's TLA+ mirror is updated)
- explicit `[approval-required]` / `[policy-denied]` log markers for #13567 class

Step 4 — emit `proof_receipt` JSON to `<base-path>/.masc/proof/<date>.jsonl`. Append-only, never edited.

Step 5 — index by `(keeper_id, tool_name)` for the reporting surface.

## Reporting surface

CLI: `sb keeper proof status [--keeper <id>] [--tool <name>] [--since <iso>]`

Outputs three sections:
1. **Coverage**: per-tool count of `Success` receipts. Tools with 0 → zero-evidence (#13569 class).
2. **Blockers**: per-tool count of non-Success receipts grouped by outcome variant. Maps directly to #13567/#13568 follow-ups.
3. **Replay**: SHA-256 over the sorted `proof_receipt` list of a date. Pin this in a follow-up `tests/proof_replay/` so a regression on collection (skipping receipts, double-counting, attribution drift) is caught as a hash mismatch.

Dashboard panel: same three sections rendered as Solid components on `/dashboard/keeper-proof`. Reuses `dashboard_http_keeper_*` types — no new transport shape.

## Three sub-track wiring

| Sub-issue | Outcome variant(s) | Closure condition |
|-----------|-------------------|-------------------|
| #13567 (policy / approval) | `Approval_required`, `Policy_denied` | All approval-required tools have at least one `Success` after a documented approval; all policy-denied receipts have a follow-up issue explaining why the policy is correct |
| #13568 (sandbox / precondition) | `Precondition_failed`, `Sandbox_path_error` | Per-tool failure rate < 5% over 7-day window AND each remaining failure has a `Keeper_path_check_error` typed cause (no raw-string class) |
| #13569 (zero-evidence) | `Zero_evidence_placeholder` | Every registered keeper-facing tool has produced at least one `Success` `proof_receipt` from at least one autonomous turn |

#13534 (parent) closes when all three rows reach their closure condition AND the SHA-256 replay test has been green for 7 consecutive days.

## Replay invariant

> A `proof_receipt` set built from `<base-path>/.masc/logs/` of date D, on any machine, by any operator, must produce the same SHA-256 as the canonical set checked into `tests/proof_replay/expected/<date>.sha256`.

This invariant is what turns "I checked yesterday and we had coverage" into a falsifiable artifact. Without it, #13534 closes on vibes.

## Non-goals

- We do not try to *fix* the policy gates / sandbox precondition failures / zero-evidence tools here. The harness only classifies and counts.
- We do not extend proof beyond keeper-attributed autonomous tool calls. Operator-triggered receipts and cascade-routed receipts are tracked separately so they cannot mask a real coverage gap.
- We do not gate CI on proof coverage. The harness is read-side observability; gating is a separate RFC if it ever becomes necessary.

## Implementation phases

1. Outcome variants + parse from existing logs (pure read-side, no new emit). Pin replay SHA against current `<base-path>/.masc/logs/2026-05-17.jsonl` to baseline.
2. CLI `sb keeper proof status` against the receipt store.
3. Dashboard panel (consumes existing `dashboard_http_keeper_*` types).
4. Close-condition sweep on #13567, #13568, #13569 each in its own follow-up PR with the harness output as evidence.
5. #13534 close once §"Replay invariant" green for 7 days.

## Open questions

- `<base-path>/.masc/proof/` location vs `<base-path>/.masc/logs/`: keep separate (append-only proof artifact) or unified (one log surface). Separate is the default in this draft.
- Cross-keeper attribution drift over a long horizon — is a 7-day window enough or do we need rolling-30? Bench data needed.
- Approval-required is a *valid* gate, not a failure. The current draft counts it as non-Success but excludes it from blocker totals. Confirm with operator.
