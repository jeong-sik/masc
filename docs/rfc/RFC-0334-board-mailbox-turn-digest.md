# RFC-0334 — Board wake as mailbox delivery: enqueue-always, cap only the wake, one digest per turn

- Status: Draft
- Decision driver: Ilya-30-papers adversarial transfer census (2026-07-08), axis A5's surviving core after the top-k attention proposal was weakened: "actor-mailbox coalescing (턴당 1 Board_digest) — 실병목 O(N) rescan + Cap 증상의 root 프레임". The learned-attention half (scoring which keepers "should" care) stays rejected — addressing remains deterministic (mention targets, thread/reaction followups, RFC-0020); this RFC only changes *delivery* and *consumption* units.
- Area: `lib/keeper/keeper_keepalive_signal.ml:423-448` (`select_board_wakeup_candidates` — fanout cap with hard drop), `:606-710` (`wakeup_relevant_keeper_for_board_signal` — per-event scan of every running keeper's meta + cap + `BoardSignalWakeupCappedTotal` counter), `lib/keeper_runtime/keeper_event_queue.ml` (`enqueue_if_missing` identity dedup, `drain_board_window` 2-second arrival window), `lib/keeper/keeper_registry_event_queue.ml` (queue owner).
- Fresh-read refinement over the census (2026-07-09): masc already has most of a mailbox — a durable per-keeper stimulus queue with identity dedup and a 2s board batching window. The census framing "no mailbox" is too broad. The actual gaps are three seams where the *event* is still the unit instead of the *keeper*:

## Problem (audited)

1. **The fanout cap drops delivery, not just wake-ups.** `select_board_wakeup_candidates` takes the first `board_reactive_wakeup_max` non-explicit candidates and discards the rest (`:445-447`); the drop is counted (`BoardSignalWakeupCappedTotal`, `:694-709`) and logged, but the dropped keepers' queues never receive the stimulus. A keeper addressed by a thread-reply followup that loses the cap race never learns the reply happened. Counter-as-alarm on a real loss — the workaround catalog's cap signature, kept alive because the alternative (waking 30 keepers per post) was correctly unacceptable. The conflation: **wake scheduling** (must be capped) and **delivery** (must not be lossy) ride the same decision.
2. **Board batching is arrival-time-keyed, not turn-keyed.** `drain_board_window` coalesces board signals that arrived within 2 seconds of now. A keeper in a 90-second turn accumulating five board signals consumes them as up to five separate wake→turn cycles (each outside the next drain's window), when one digest turn would do. The census's "턴당 1 Board_digest" names the correct unit: everything queued since the keeper's last turn is one observation.
3. **Per-event O(N) meta scan.** Every board post/comment/reaction reads every running keeper's meta file to compute wake reasons (`:610-663`, with a yield meter acknowledging the CPU cost). N keepers × M events is quadratic pressure on the hot publish path; the addressing inputs (mention_targets, self-comment/reaction history) change far less often than events arrive.

## Decision

1. **Split delivery from wake (W1).** On a board signal, enqueue the typed `Board_signal` stimulus to *every* addressed keeper's queue (append + identity dedup — cheap, lossless), then apply `board_reactive_wakeup_max` only to how many keepers get an *immediate wake*. Non-woken keepers keep the stimulus and observe it on their next turn, whatever triggers it (heartbeat, schedule, later signal). `BoardSignalWakeupCappedTotal` becomes a deferral counter, not a loss counter; the log line changes from "dropped" to "deferred to mailbox".
2. **Turn-keyed digest consumption (W2).** At turn start, drain *all* queued board stimuli for the keeper (not a 2s arrival window) into one typed `Board_digest` observation: posts/comments/reactions grouped by thread, newest last, explicit mentions surfaced first. `drain_board_window`'s window parameter is retired; identity dedup already bounds the digest (`enqueue_if_missing` collapses repeats). One turn, one board observation — regardless of how the signals arrived.
3. **Addressee index instead of per-event meta scan (W3, separable).** Maintain a registry-owned index from addressing keys (mention target, active thread participation) to keeper names, updated when meta changes (registration, mention_targets edit, comment/reaction by the keeper), consulted per event. The wake-reason *decision* logic is unchanged — only its input acquisition stops being O(N) file reads per event.
4. **What this is not.** No learned relevance, no semantic scoring of "which keepers care" (axis A5's rejected half; the RFC-0020 boundary comment at `:418-422` stays normative). No new queue — the existing durable queue is the mailbox. No priority inversion: explicit mentions keep their unconditional immediate wake.

## Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| W1 | enqueue-always + cap-only-the-wake in `wakeup_relevant_keeper_for_board_signal` | a capped keeper's queue contains the stimulus; `BoardSignalWakeupCappedTotal` semantics documented as deferral; zero stimuli discarded on the publish path |
| W2 | turn-start full drain → one `Board_digest` per turn | a keeper with k>1 queued board signals runs one turn consuming all k; window-parameter reads = 0 |
| W3 | addressee index for wake-reason inputs | per-event meta-file reads drop from O(N keepers) to O(addressees); index refreshed on meta mutation, not per event |

## Verification

- W1 pins: fanout cap with 3 candidates and limit 2 → 2 woken, 3 queues populated; the deferred keeper's next heartbeat turn observes the signal.
- W2 pins: 5 board signals spread over >2s while keeper busy → exactly 1 digest observation on next turn; explicit-mention ordering pin; identity-dedup pin unchanged.
- W3 pins: meta read counter per event = addressee count; index invalidation on mention_targets change.
- Workaround-gate self-check: this *removes* a cap-as-loss signature by re-typing it as deferral; W2 removes a time-window heuristic in favor of a structural unit (the turn). Any future PR re-introducing a drop on the delivery path is a cap/cooldown reject.

## Boundaries (untouched)

- RFC-0020 deterministic addressing (explicit mention short-circuit, typed wake reasons) — unchanged.
- `Keeper_event_queue` identity/dedup semantics and durable persistence — reused, not redesigned.
- Paused/latched keeper suppression (`board_wakeup_allowed`, tombstones) — a suppressed keeper still doesn't wake; whether its mailbox receives ambient signals while latched follows the existing tombstone rules.
- Non-board stimuli (bootstrap, fusion_completed, no_progress_recovery) — out of scope.

## Evidence record

- Evidence: `lib/keeper/keeper_keepalive_signal.ml:423-448,606-710`, `lib/keeper_runtime/keeper_event_queue.ml` (`enqueue_if_missing`, `drain_board_window`), `lib/keeper/keeper_registry_event_queue.ml`, census artifact e1d4ba86 (axis A5, WEAKENED→surviving core), fresh-read verified 2026-07-09 at `ae027bed8f`.
- Confidence: High for the three seams (all cited lines re-read at HEAD); Medium for W3 sizing (index invalidation surface needs a dedicated census before implementation).
- Delta: reframes the fanout cap from loss to deferral using infrastructure that already exists; the census's "no mailbox" claim is corrected to "mailbox exists, delivery and consumption still event-keyed".
