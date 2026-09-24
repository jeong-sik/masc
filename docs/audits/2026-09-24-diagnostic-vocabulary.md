# Diagnostic vocabulary audit — 2026-09-24

This is the first inspected slice of message, variant, error, and log wording.
It is not a repository-wide completion claim. The criterion is whether two
fields or phrases carry the same fact, rather than whether they share a word.

## Confirmed overlap and repair

| Surface | Same fact before | Change |
| --- | --- | --- |
| Librarian exact preflight (`keeper_librarian_runtime`) | `Exact_request_projection_failed.slot_id` repeated the first ID already embedded in its formatted `reason` list. A single-slot failure printed the ID twice. | Keep each slot ID beside its typed `Exact_output.admission_error` until rendering. The error line prints every refused slot once in declared order. |
| Librarian CLI fallback (`keeper_librarian_runtime`) | `API failure:` wrapped an error that already identified the API projection; the WARN said `cli lane-slot failed` before `failure_to_string` said the same thing. | Compose the API and CLI details without a second failure label; use `librarian fallback:` for the WARN. |
| Shared CLI slot execution error (`keeper_lane_cli_oneshot`) | The wrapper printed `runtime_id` before `Fusion_official_client.failure_detail` printed the same ID for client failures. Some setup failures had no ID at all. | Distinguish raw and already attributed setup failures as variants, then render the runtime ID once for each case. Keep the slot failure label and complete cause. |
| Board attention CLI WARN (`keeper_board_attention_exact_flow`) | The WARN said `cli lane-slot failed` before the shared failure detail named that slot failure again. | Identify the Board attention fallback once, then append the shared failure detail. |
| HITL CLI walk (`hitl_summary_worker`) | The last slot failure was logged at dispatch and repeated when the walk exhausted its candidates. Domain validation logged its cause without the slot ID and stored it under the misleading `Invalid_json_output` variant even though JSON parsing had succeeded. | Send execution and domain failures through one slot-aware log helper, classify the latter as `Invalid_domain_output`, and make the terminal line name exhaustion and the last bound slot without replaying the cause. The quarantine still uses the typed failure. |
| TUI exact-run detail (`masc_tui_render`) | `RUN failed` was followed by `FAILURE librarian_failed`. | Label the second line `CODE`, preserving the machine code and detail without a second status word. |

## Follow-up slices — 2026-09-25

These changes are on independent branches; a pushed branch or open PR is not a
merged or deployed behavior claim.

| Surface | Same fact | Reviewable change |
| --- | --- | --- |
| Fusion failed-panel Board evidence | `reason_detail` and `reason` stored the same `panel_failure_text`. | #38825 keeps `reason_detail` and updates Board, Fusion, and chat readers. TUI already requires that field. |
| TUI continuity measurement | The sample header and its cause line both said `QUESTION/ANSWER/JUDGE FAILED`. | #38829 keeps `FAILED` in the status and names the stage on its `CAUSE` line, including when the header scrolls away. |
| Board reaction summary | `reacted` and `has_reacted` carried the same viewer boolean through the server, Dashboard normalizer, and UI type. | `fix/board-reaction-single-selected-20260925` keeps `reacted`; the producer test requires the alias key to be absent. |
| Keeper status and Dashboard | `trace_history_count` and `handoff_count_total` were both `List.length m.runtime.trace_history`. | `fix/keeper-handoff-single-count-20260925` keeps `handoff_count_total` for KPI and briefing readers. |

`handoff_count_total` still reports the number of prior trace IDs. This audit
does not establish that it counts executed handoffs; that metric meaning needs
separate source evidence.

## Similar names that carry different facts

- `Keeper_skill_activation_projection` and `Keeper_snapshot_unread` emit a
  short `reason` code plus a separate diagnostic `detail`. These are distinct
  wire fields and were left intact.
- `Runtime_verification.unmeasured` carries `code`, a human `message`, and an
  optional producer `detail`. Its decoder checks that only codes with details
  receive one; collapsing these would discard a contract distinction.
- `Keeper_runtime_attempt` maps provider `detail` into the HTTP client's
  `message` field at a type boundary. The source value is transferred, not
  stored twice in one error.

## Remaining audit areas

- Other exact-output lanes' preflight and fallback errors.
- Runtime/provider error conversion and the final operator log wrapper.
- Dashboard and TUI renderers that print a status next to a code with the same
  status word.
- Wire records with both code/reason and detail/message: check the producer
  and decoder before changing any schema.
- `Fusion_decision` writes `notes` by concatenating its stored `decision`,
  `choice`, and `reason`. Its strict reader requires `notes`, and Task history
  displays that field; removing only the write would make existing decisions
  unreadable. This needs a storage and read-projection change together.
- Keeper model labels and health version aliases need consumer and semantic
  review before collapsing them: equal source strings alone do not prove that
  their fields have the same meaning.
