# KEQ Q-1 — KeeperEventQueue.tla preamble lags the runtime (first-entry audit)

**Date**: 2026-05-12 · **Iteration**: 68 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: Q (first entry)
**Spec**: `specs/keeper-state-machine/KeeperEventQueue.tla` (203 LOC, 4 vars, bug-model paired)
**OCaml**: `lib/keeper/keeper_event_queue.{ml,mli}` (91 + 79 LOC), `keeper_keepalive_signal.ml`, `keeper_heartbeat_loop.ml`
**RFC**: `docs/rfc/RFC-0020-keeper-event-queue-layer-separation.md` (Status: Draft, created 2026-04-30)
**Verdict**: spec preamble is the stale party — it frames KEQ as forward-looking design ("forthcoming RFC", "Today this state lives only implicitly", "the refactor that adds a real Event Queue") while the runtime has substantially caught up. New first-entry sub-class: **"spec banner lags runtime"** — the inverse of the 6th drift class *and* the inverse of KOAS M-1 (where the runtime owes the spec).

## What the spec preamble claims vs what's in main

| KEQ.tla preamble line | Reality (2026-05-12) |
|---|---|
| "Models the design described in `docs/design/keeper-event-queue-layer-separation.md` (forthcoming RFC)" | The RFC exists as **`docs/rfc/RFC-0020-keeper-event-queue-layer-separation.md`** (not "forthcoming"; wrong path). `ls docs/design/keeper-event-queue*` → 0 matches. RFC-0020 itself cites `KeeperEventQueue.tla (#12386)`. |
| "itself derived from RUTHLESS_JUDGMENT §3-4" | RFC-0020 cites `RUTHLESS_JUDGMENT.md §1 A5` for the starvation race. The spec's "§3-4" pointer disagrees. |
| "event_queue : the new Event Layer FIFO ... Today this state lives only implicitly via fiber_wakeup and the interruptible_sleep race window" | **`lib/keeper/keeper_event_queue.ml` (91 LOC, .mli 79 LOC) exists** — a persistent FIFO with `enqueue` / `dequeue` / `dedup_by_post_id` / `sort_by_urgency` / `classify` / `drain_board_window`. Its `.mli` opens with "Models the contract verified in `[specs/keeper-state-machine/KeeperEventQueue.tla]`". |
| "This spec models the refactor that adds a real Event Queue" | The refactor **landed** (data side + substantial wiring): `keeper_keepalive_signal.ml:124-135` calls `Keeper_registry.enqueue_event` and comments "RFC-0020 Rule 1 (enqueue is independent of policy)"; `keeper_heartbeat_loop.ml:670-676` does the dequeue and comments "pins the [Conservation] invariant from [KeeperEventQueue.tla] (dequeued_total <= enqueued_total) in production"; `keeper_heartbeat_loop.ml:1400-1403` forces `Emit` when the queue is non-empty and comments "Pinned by KeeperEventQueue.tla QueueNeverStarvedBySkip invariant". |

So a contributor reading **only** `KeeperEventQueue.tla` today would conclude the Event Layer is unbuilt. In fact: the data module is in `lib/keeper/`, the enqueue side is wired into the keepalive signal path, the dequeue side runs in `keeper_heartbeat_loop.ml`, and the spec's two core safety invariants (`Conservation`, `QueueNeverStarvedBySkip`) are cited by name at the call sites that enforce them. The only honestly-incomplete part is the *consumer-side* (`Heartbeat_smart.should_emit`-consults-queue) wiring, which `keeper_event_queue.mli` and `keeper_heartbeat_loop.ml:670` both flag as "follow-up".

## Spec ↔ OCaml link health

The OCaml side is in good shape — it references the spec by invariant name at the enforcement points:

| Spec action / invariant | OCaml site | Note |
|---|---|---|
| `Enqueue` (side-effect-free Event Layer op) | `keeper_keepalive_signal.ml:124-135` (`Keeper_registry.enqueue_event`) | "RFC-0020 Rule 1" comment |
| `TurnDequeue` / `Conservation` (`dequeued_total <= enqueued_total`) | `keeper_heartbeat_loop.ml:670-676` | "pins the [Conservation] invariant ... in production" |
| `TickQueueOverride` | `keeper_heartbeat_loop.ml:673-676` | "becomes a real runtime transition ... PR-C2 #12412" |
| `QueueNeverStarvedBySkip` | `keeper_heartbeat_loop.ml:1400-1403` | forces `Emit` when queue non-empty |
| `EmitMatchesEvidence` | (not separately pinned at a call site) | candidate for a Q-3 cross-check |

So the drift is one-directional: **spec preamble → runtime** (the preamble's status framing). Every other link is current.

## `keeper_event_queue.mli` is also (mildly) stale

The `.mli` header says: *"This module is data only. Wiring into `keeper_keepalive_signal.wakeup_keeper` and `Heartbeat_smart.should_emit` lives in a follow-up patch so the queue can be exercised in isolation by tests first."* — but `keeper_keepalive_signal.ml` already calls `Keeper_registry.enqueue_event` (the enqueue side of that wiring). The accurate statement is "enqueue wiring landed; the `Heartbeat_smart.should_emit`-side consumer wiring is the remaining follow-up."

## Why this is "톱니처럼 정교하지 않은" (not gear-tight)

A spec banner is a contract with the reader: "here is the implementation status." When the runtime catches up but the banner doesn't, the reader either (a) underestimates coverage and re-implements something that exists, or (b) distrusts the spec ("it says forthcoming, but here's `keeper_event_queue.ml` — which is right?"). The same failure mode the K-2.d / L-2.a / M-2.a status-disclosure trilogy was built to prevent, in the opposite direction: those disclosed *dormancy*; KEQ needs to disclose *that the dormancy ended*. The fix is the same shape — a dated "Runtime status" block.

## Fix-PR candidates (Q-2.*)

1. **Q-2.a (LOW, comment-only)** — rewrite the KEQ.tla preamble's status framing:
   - `docs/design/keeper-event-queue-layer-separation.md` (forthcoming RFC) → `docs/rfc/RFC-0020-keeper-event-queue-layer-separation.md` (Draft, 2026-04-30)
   - `RUTHLESS_JUDGMENT §3-4` → `RUTHLESS_JUDGMENT.md §1 A5`
   - "Today this state lives only implicitly via fiber_wakeup" → a dated "Runtime status (2026-05-12)" block: data module = `lib/keeper/keeper_event_queue.{ml,mli}`; enqueue wired in `keeper_keepalive_signal.ml` (RFC-0020 Rule 1); dequeue + `QueueNeverStarvedBySkip` enforcement in `keeper_heartbeat_loop.ml`; remaining follow-up = `Heartbeat_smart.should_emit` consumer wiring.
   - This is the 15th-honest-doc shape (status-disclosure family, "dormancy ended" flavour).
2. **Q-2.b (LOW, comment-only)** — `keeper_event_queue.mli` header: "This module is data only. Wiring ... lives in a follow-up" → "enqueue wiring landed in `keeper_keepalive_signal.ml`; consumer-side `Heartbeat_smart.should_emit` wiring is the remaining follow-up." Could be bundled with Q-2.a (commit-order coupling — same as L-2.a + L-2.b).
3. **Q-2.c (LOW, audit/test)** — pin `EmitMatchesEvidence` at its enforcement site (if one exists) or document that it is a pure-spec property with no single OCaml witness. Mirrors the K-2.c `.mli` mapping-table shape.
4. **Q-2.d (LOW, TLC refresh)** — re-run `KeeperEventQueue.cfg` (clean → no error) + `KeeperEventQueue-buggy.cfg` (`TickStarvesQueue` → `QueueNeverStarvedBySkip` violated). Last full-corpus state in `docs/tla-audit/cross-spec-3-divergences-classify-2026-05-12.md` (iter 41) noted "KEQ clean OK 0s + KEQ buggy violation exit 12".

## First-entry sub-class catalogue (updated — 9 sub-shapes)

| # | Sub-shape | Exemplar |
|---|-----------|----------|
| 1 | coverage gap (naming + under-modelled Init + superset condition) | iter 1 KSM A-1 |
| 2 | drift (behavioural divergence) | iter 22 KCR C-1 |
| 3 | cross-spec staleness (set identifier rename) | iter 38 KEQ DecisionSet |
| 4 | doc-layer drift (phase-count, OCaml docstring) | iter 47 KCtxL H-1 |
| 5 | dormancy (flag-gated runtime) | iter 56 KAL K-1 |
| 6 | design-ground (no runtime) | iter 58 KRL L-1 |
| 7 | runtime owes spec (bug-model verified, 0 concept hits) | iter 61 KOAS M-1 |
| 8 | line-reference drift (functions exist, line numbers stale) | iter 63 KAQ N-1 |
| **9** | **spec banner lags runtime (aspirational framing outlived)** | **iter 68 KEQ Q-1** |

## Verification (this audit)

```
$ ls docs/design/keeper-event-queue*                         # 0 matches
$ ls docs/rfc/RFC-0020-keeper-event-queue-layer-separation.md # exists, Status: Draft
$ wc -l lib/keeper/keeper_event_queue.{ml,mli}                # 91 + 79
$ rg -n 'RFC-0020 Rule 1|enqueue_event' lib/keeper/keeper_keepalive_signal.ml   # lines 124-135
$ rg -n 'KeeperEventQueue.tla' lib/keeper/keeper_heartbeat_loop.ml              # lines 672, 1402
$ rg -n 'QueueNeverStarvedBySkip|Conservation == ' specs/keeper-state-machine/KeeperEventQueue.tla  # 179, 185
```

No spec, OCaml, or .cfg modified by this PR — audit only.

## RFC trail

RFC-0020 (Draft, 2026-04-30) — `docs/rfc/RFC-0020-keeper-event-queue-layer-separation.md`. The Q-2.* fix-PRs above are comment-only / TLC-refresh; none touch a credential/identity/operator/sandbox/hooks/workflow surface, so RFC-WAIVED applies to each.
