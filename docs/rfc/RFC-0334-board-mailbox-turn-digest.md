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
| W3a | promote the base-path profile-defaults loader to the fingerprint-revalidating cache | `reload_meta_from_disk` and any hook-driven overlay stop doing uncached TOML I/O per call; no behavior change |
| W3b | make the meta-store write-sync hook install *effective* (overlay-applied) meta, matching `reload_meta_from_disk` and the heartbeat sync | `entry.meta` provenance is deterministically effective; `effective_meta_overlay_hash` fingerprint stops oscillating raw↔effective; no wake-behavior change (fan-out still reads disk) |
| W3c | switch `wakeup_relevant_keeper_for_board_signal` from per-event disk `read_meta` to `entry.meta` | per-event meta-file reads drop from O(N keepers) to 0 (registry copy is in-memory); **wake-behavior change**: TOML-profile `mention_targets` now affect board wake (see §W3 design) |

## Verification

- W1 pins: fanout cap with 3 candidates and limit 2 → 2 woken, 3 queues populated; the deferred keeper's next heartbeat turn observes the signal.
- W2 pins: 5 board signals spread over >2s while keeper busy → exactly 1 digest observation on next turn; explicit-mention ordering pin; identity-dedup pin unchanged.
- W3c pin: register a keeper, delete its on-disk meta file, emit a board signal whose text mentions it → the keeper still matches via the in-memory `entry.meta` (disk-read independence). No per-event meta-read counter is added (a counter whose only consumer is a test is a counter-as-pin reject); the structural disk-deletion pin proves the same property.
- Workaround-gate self-check: this *removes* a cap-as-loss signature by re-typing it as deferral; W2 removes a time-window heuristic in favor of a structural unit (the turn); W3c *removes* a per-event disk scan, and W3b removes a raw↔effective oscillation rather than adding a cache layer over it. Any future PR re-introducing a drop on the delivery path is a cap/cooldown reject.

## W3 design (census-resolved 2026-07-10, issue #23837)

The RFC deferred W3 sizing to a census; here is its resolution. The original "addressee index" framing (an inverted needle→keeper map) is the *eventual* O(addressees) target, but the census found the dominant per-event cost is not the match loop — it is `N` **uncached disk `read_meta` calls** (`keeper_keepalive_signal.ml:636`), one per running keeper per board event. Eliminating that disk scan is the bulk of the win and is separable from building an inverted index, so W3 is split.

**Provenance is the gate.** `Keeper_registry` `entry.meta` today has *mixed* provenance: the write-sync hook (`sync_meta_if_registered`) installs RAW persisted meta, while `reload_meta_from_disk` and the heartbeat loop install EFFECTIVE (TOML/persona-overlay-applied) meta. The fan-out reads RAW today (via disk `read_meta`). Switching it to `entry.meta` naively would read whichever provenance last won — nondeterministic. So provenance must be unified first (W3b).

**Direction: unify to effective, not raw.** The overlaid-field set (`effective_meta_of_profile_defaults`, `keeper_meta_contract.ml:705-783`) is: `persona`, `proactive.*`, `tool_denylist`, `goal`, `instructions`, `autoboot_enabled`, `mention_targets` (when TOML defaults non-empty), `active_goal_ids`, `tool_access`, `sandbox_profile`, `sandbox_image`, `network_mode`, `multimodal_policy`, `allowed_paths`, `telemetry_feedback_*`, `always_approve`, `oas_env`. Of these the board fan-out consumes exactly one — `mention_targets` (`keeper_world_observation_board_signal.ml:103`); every other field it reads (`name`, `agent_name`, `paused`, `auto_resume_after_sec`, `runtime.last_blocker`) is raw-safe. Meanwhile `keeper_status_detail.ml:209` is literally named `effective_meta_overlay_hash` and fingerprints the *effective* overlay to invalidate its status cache — it *requires* effective. Unifying to raw would break that by design; unifying to effective is what the majority consumer already wants and what the heartbeat loop already installs most of the time.

**Consequence to sanction (W3c exit behavior).** Once the fan-out reads effective `entry.meta`, a keeper whose `mention_targets` come from its TOML profile (not the `masc_keeper_up`/`update` MCP path) will begin matching `@alias` board mentions. Today it does not, because the fan-out reads raw disk meta which lacks the overlay. This aligns board wake with operator configuration intent — a latent-bug fix — but it is a **wake-semantic change** and is the explicit, RFC-sanctioned exit behavior of W3c, not an incidental side effect.

**Ordering and gates.**
1. **W3a (prerequisite, perf, no behavior change):** `load_keeper_profile_defaults_result_for_base_path` (`keeper_types_profile.ml:232`) is uncached; only the scope-keyed variant (`:481`) uses `profile_defaults_cache` with fingerprint revalidation. W3b would put overlay computation in the hot write-sync hook, so the base-path loader must first be promoted to the cache (base-path-keyed, same fingerprint revalidation) or W3b will regress every durable meta write into an uncached TOML read.
2. **W3b (behavior-preserving):** hook installs effective. Removes the raw↔effective oscillation (which currently churns `effective_meta_overlay_hash` and the status cache). Fan-out still reads disk, so no wake change yet.
3. **W3c (sanctioned wake-semantic change):** fan-out reads `entry.meta`; disk scan eliminated. The paused-wake path's meta-version lag (`keeper_keepalive_signal.ml:579`) becomes a real registry-CAS clobber risk only here, so it is fixed as part of W3c, not before.

Prerequisite already landed: the supervisor prune ghost-entry fix (#23861, census freshness caveat 1) removes the "pruned keeper resurrected via `entry.meta` write" hazard that W3c would otherwise expose.

An inverted needle→keeper index (the original framing, O(addressees) instead of O(N) match loop) remains a possible W3d, but the census showed the match loop is cheap relative to the disk scan; W3d is deferred until profiling shows the in-memory scan is a bottleneck.

## Boundaries (untouched)

- RFC-0020 deterministic addressing (explicit mention short-circuit, typed wake reasons) — unchanged.
- `Keeper_event_queue` identity/dedup semantics and durable persistence — reused, not redesigned.
- Paused/latched keeper suppression (`board_wakeup_allowed`, tombstones) — a suppressed keeper still doesn't wake; whether its mailbox receives ambient signals while latched follows the existing tombstone rules.
- Non-board stimuli (bootstrap, fusion_completed, no_progress_recovery) — out of scope.

## Evidence record

- Evidence: `lib/keeper/keeper_keepalive_signal.ml:423-448,606-710`, `lib/keeper_runtime/keeper_event_queue.ml` (`enqueue_if_missing`, `drain_board_window`), `lib/keeper/keeper_registry_event_queue.ml`, census artifact e1d4ba86 (axis A5, WEAKENED→surviving core), fresh-read verified 2026-07-09 at `ae027bed8f`.
- Confidence: High for the three seams (all cited lines re-read at HEAD). W3 sizing was resolved by the 2026-07-10 consumer census (issue #23837, §W3 design above): the disk scan — not the match loop — is the cost, provenance unification is the gate, and the fan-out wake-semantic change is now RFC-sanctioned. W3a/W3b remain unimplemented; W3c is gated on them plus the §W3 wake-semantic sanction.
- Delta: reframes the fanout cap from loss to deferral using infrastructure that already exists; the census's "no mailbox" claim is corrected to "mailbox exists, delivery and consumption still event-keyed".
