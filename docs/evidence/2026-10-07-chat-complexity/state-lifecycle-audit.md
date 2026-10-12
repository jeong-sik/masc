# TUI chat state lifecycle audit

Baseline: `5a9d7aeac2e609a5dab261204cf89825155860b6`.
Scope: chat queue/state, source selection, observer/history/journal routing, and workspace fencing.
Method: read-only source inspection and explicit state-transition traces. No production edits, builds, CI, fixture execution, or runtime reproduction. The findings below are source-backed reachability proofs, not observed live failures.

## P2: history arriving before journal termination permanently stops an observer

Primary defect: `bin/masc_tui.ml:16317-16320`. The handler marks an operation journal unavailable when `loaded_turn_has_ended` is true, even if the journal page it received is still `Working` or `Waiting`.

Reachable input state and transition:

1. A dashboard/API operation `reply-op` for Keeper `alpha` is running. This TUI observes it through journal reads; it does not own its POST, so `msg_inflight=[]`.
2. The final response is persisted and `keeper_chat_appended` is broadcast (`lib/server/server_routes_http_keeper_stream.ml:2324-2343`) before the completion projection emits the final `Reply_details` and `Run_finished` (2801-2863).
3. The history result arrives first and puts the assistant row in `state.msg_loaded`, under `me_request_id="reply-op"`. The history decoder retains it as `Said_by_keeper` (`bin/masc_tui_keeper_chat_history.ml:1428-1439`), mapped to `Message_keeper, Turn_output` (`bin/masc_tui.ml:6594-6595`). `loaded_turn_has_ended` now returns true merely from its role (`bin/masc_tui_types.ml:7223-7234`).
4. An overlapping journal read returns an earlier partial page without the terminal events. The transcript remains `Working` or `Waiting`, and `turn_log_holds_the_turn` is false (`bin/masc_tui_types.ml:3064-3076`).
5. The journal handler calls `remember_journal_unavailable state "reply-op"` because the stored reply exists (`bin/masc_tui.ml:16304-16320`). This entry remains until workspace reset.
6. Later observer follow requests return `Follow_nothing` (`bin/masc_tui_types.ml:7191-7195`), and history reloads exclude that source from journal fetch targets (3020-3023). The final journal events can no longer complete the held transcript.

Impact: durable reply text can be present while its observed journal remains incomplete. Missing final text reconciliation, tool/result transitions, reasoning events or termination state are not repaired by subsequent journal notifications. Reopening the same Keeper does not clear the unavailable list. This is a source-backed interleaving, not an executed race reproduction.

Independent challenge corrected the initial checkpoint explanation: `pending_direct_continuation()=Some` takes the tools-only persistence route (`server_routes_http_keeper_stream.ml:2348-2351`). `Keeper_direct_gate_continuation.pending` recognizes cooperative, runtime-retry and gate checkpoints. Thus the claim that every checkpoint persists an assistant row was withdrawn; the ordinary final-history-before-terminal-journal race above is the supported finding. The comment at 2359 about all checkpoint paths is insufficient evidence against the actual branch.

Existing coverage misses the fetching boundary: `test/test_tui_chat_queue_wiring.ml:3293-3305` marks a journal unavailable and then manually calls `turn_log_add` with later `Reply_details`/`Run_finished`. That proves rendering retains direct injections, but production `journal_follow_for_source` prevents those later reads.

Minimal repair direction: separate durable chat-row presence from authoritative operation/journal termination. A valid journal read with a nonterminal boundary must not enter a permanent unavailable set because history already has an assistant row.

## P2: journal tracking collapses distinct Keepers with the same operation ID

Primary defect: `bin/masc_tui_types.ml:7082-7125`, consumed at 7191-7208. `msg_journal_unavailable`, `msg_journal_inflight`, and `msg_journal_wanted` key entries solely by the source's string ID.

The authoritative identity is scoped by Keeper:

- Operation storage lives at `<keepers_runtime_dir>/<keeper>/chat-operations.sqlite3` (`lib/keeper_chat_operations/keeper_chat_operation_store.ml:42-45`).
- Event journals live at `<events_dir>/<keeper>/<operation_id>.jsonl` (`lib/keeper/keeper_chat_event_log.ml:618-621`).
- Held-log lookup correctly checks both Keeper name and request ID (`bin/masc_tui_types.ml:6959-6964`).
- `daily-review` is a valid caller-supplied operation ID (`lib/keeper_operation_identity/keeper_operation_id.ml:5-26`). The server does not reserve it globally across Keepers.

Reachable input state and transition:

1. Keeper `alpha` has operation `daily-review`; its journal was pruned. The TUI reads it and handles `Journal_pruned`, storing only `"daily-review"` in `msg_journal_unavailable` (`bin/masc_tui.ml:16321-16324`).
2. The user switches to Keeper `beta`, whose independent `daily-review` operation is running with a valid journal. Switching Keeper leaves the journal tracking lists intact (`bin/masc_tui.ml:848-875`); those lists are reset only on workspace transition (10627-10630).
3. Beta's observer frame invokes `journal_follow_for_source ~keeper_name:"beta" ~source:(Operation "daily-review")`. The correctly scoped held-log lookup finds no Beta log, but the unscoped unavailable lookup immediately returns `Follow_nothing` (`bin/masc_tui_types.ml:7191-7195`). Beta's history fetch also excludes the same ID (3020-3023).

The same Keeper omission also exists in the own-request exclusion (`bin/masc_tui_types.ml:7186-7189`) and observed-log in-flight classification (`7277-7282`): another Keeper's same-named request can prevent journal reads or hide a held partial log.

Impact: an unavailable journal for one Keeper permanently removes another Keeper's valid streaming view in that TUI session. The same missing scope also shares in-flight markers and wanted high-water marks; finishing one Keeper's read can clear the other's marker or consume its pending follow request.

Minimal repair direction: use a full `(keeper_name, journal_source)` key consistently for journal availability, in-flight ownership, wanted cursors, and held targets. Do not flatten identity before state lookup.

## Examined boundaries without a finding

- Late journal results after workspace switches are wrapped by `workspace_enqueue` with captured workspace authority (`bin/masc_tui.ml:1592-1594`, 6305, 6327-6328), and the central handler discards old authority (`13574-13583`). The unguarded-looking inner journal handler is therefore not itself a cross-workspace acceptance bug.
- Stream reconnect preserves the request's journal cursor, while creating a fresh SSE decoder (`bin/masc_tui.ml:1984-2059`). A partial decoder buffer is not reused across subscriptions.
- Checkpoint POST watching correctly reconnects after the last journal sequence (`bin/masc_tui.ml:2032-2036`). The early-retirement finding concerns observer/journal consumption, not this direct watcher loop.
- Source selection uses per-execution identity, terminal coverage, then journal high-water position (`bin/masc_tui_types.ml:6970-7004`). No separate failover-source selection defect was established in this audit.
