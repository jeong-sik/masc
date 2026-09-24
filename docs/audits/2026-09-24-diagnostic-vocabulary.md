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
| TUI Metrics loading | The Keeper turns loader already said `keeper turns load failed`, and Metrics added `Current turn observation failed`; a stale memory reading likewise repeated `refresh failed` before the loader's failure label. | #38845 keeps the loader's single source label and renders its cause once. |
| TUI standalone lane refresh | A retained lane reading displayed `STALE · refresh failed: standalone lanes load failed`. | #38863 keeps `STALE` and adds one read-failure label at the result boundary for HTTP, decode, and async errors. |
| TUI Connector read | Keeper Channels displayed `channel transports unavailable: connector load failed` on a first failure and `refresh failed: connector load failed` over retained rows. The Connector list added `(load failed)` in its title above the specific body error. | #38875 attributes HTTP, decode, and async failures once before display; Channels keeps the cause and marks retained rows `STALE`. The list leaves the verdict in the body, and the unbind-all offer names its own unavailable action separately. |
| TUI Board post detail | The same failed read travelled as `Board_post_refresh_done (Error ...)` or `Board_post_refresh_failed`, while the loader, Board detail pane, fallback page, and offscreen event added overlapping failure labels. | #38877 carries completion in one Result variant and labels the current request's error once before displaying or logging it. |
| TUI Keeper Automation read | An HTTP error said `schedules unavailable: keeper schedule load failed`, while decode and async errors had no read-failure attribution. | #38879 gives every completed Keeper schedule read one failure label before the Automation tab displays it. Successful snapshots with a schedule-store read error keep their separate status. |
| TUI Skills catalog read | The loader prefixed HTTP failures with `skills catalog load failed`, the Tools pane prefixed every error with `Skill catalog read failed`, and a retained catalog added `refresh failed` again. | #38881 passes the HTTP or decode cause through the loader, displays one failure verdict, and separately says that the previous catalog reading remains visible. |
| TUI historical Fusion Board detail | The specific refresh error row was followed by `Previous Board reading (refresh failed)`, repeating the failed verdict over the retained original. | #38887 keeps the specific error row and uses the secondary row only to say that the previous Board reading remains visible. |
| TUI Keeper chat progress | The row heading said `REQUEST ERROR`, while its detail began `stream reported an error` before the provider cause. | #38846 renders the reported cause directly. A missing cause is named before any runtime attribution is added. |
| Board reaction summary | `reacted` and `has_reacted` carried the same viewer boolean through the server, Dashboard normalizer, and UI type. | #38842 keeps `reacted`; the producer test requires the alias key to be absent. |
| Keeper status and Dashboard | `trace_history_count` and `handoff_count_total` were both `List.length m.runtime.trace_history`. | #38843 keeps `handoff_count_total` for KPI and briefing readers. |
| Keeper model label | `last_model_used_label` and `active_model_label` were populated from the same last runtime attempt, or both null. | #38844 keeps `active_model_label` and removes the duplicate producer and Dashboard fallback. |

`handoff_count_total` still reports the number of prior trace IDs. This audit
does not establish that it counts executed handoffs; that metric meaning needs
separate source evidence.

`active_model_label` is a redacted label derived from the last runtime attempt;
it is not evidence that a model is running now. The model-label slice removes
the identical alias without changing that existing meaning.

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
- Health version aliases need consumer and semantic review before collapsing
  them: equal source strings alone do not prove that their fields have the
  same meaning.
