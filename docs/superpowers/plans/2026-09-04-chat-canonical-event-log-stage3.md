# Chat Canonical Event Log — Stage 3a (TUI: one log, one projection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The TUI keeper-chat pane holds each operation's turn as one seq-ordered event log and draws it through one projection. Live SSE frames and the v2 journal feed the same log; settle marks the log committed instead of swapping representations; reasoning stays on screen after settle; a runtime retry marks the earlier attempt superseded instead of wiping it; a dropped stream resumes with `since_seq` instead of restarting a fresh decoder; and after a TUI restart, turns whose journal still exists are rebuilt from `/chat/events` so reasoning survives reload.

**Architecture:** RFC-0412 §3.3 (`docs/rfc/RFC-0412-chat-is-one-canonical-event-log.md`), stage 3. Stage 3 is split: **3a (this plan)** replaces the live representation and the settle/reload/retry transitions around it; **3b** collapses `msg_history`/`msg_loaded` into the same log and replaces the physical-identity memo chain; **3c** makes the Memory-OS journal a typed lane and folds Ctrl-R / Ctrl-N into one projection parameter. 3b and 3c get their own plan documents after 3a lands; §3.3 bullets are mapped to sub-stages in the appendix.

**Tech Stack:** OCaml 5.5 / Eio / Alcotest, Python PTY suites. No local dune (constitution execution protocol) — static review + CI (`gh workflow run ci.yml --ref <branch>` for `@check`, `gh workflow run test.yml --ref <branch>` for the behavioural suite; the two lanes have different concurrency groups and can run together).

---

## Context (read first — anchors verified 2026-09-05 on main `e6983e357e`; the RFC's own `bin/masc_tui.ml` line numbers have drifted by +130..+170 and must not be trusted)

### What the server gives the TUI now (stage 2 landed: #33103, #33109)

- Every projected SSE frame is `id: <seq>\ndata: {...}\n\n` (`lib/sse_wire/sse_wire.ml:8-11`). Frames that never went through the bus have no `id:` line: `KEEPER_CHAT_OPERATION_ACCEPTED` (`server_routes_http_keeper_stream.ml`, `publish_acceptance`) and the settle glue's synthesized `RUN_ERROR`.
- `POST /api/v1/keepers/chat/stream` accepts `since_seq : int` (>= -1) next to `request_id`; when the owner already holds the operation (`existing`) the server replays journaled events with `seq > since_seq` through the same projection, then attaches live. Seqs of events that project to nothing (connector-only blocks) leave gaps: `since_seq` is a journal position, not a frame count.
- `GET /api/v1/keepers/:name/chat/events?operation_id=&since_seq=&limit=` (CanAdmin) → `{schema:"masc.keeper_chat_events.v2", operation_id, events:[<journal line>], has_more, next_since_seq}`; each element decodes with `Masc.Keeper_chat_event_log.journaled_event_of_json` into `{ seq; ts; event : Keeper_chat_events.keeper_chat_event }`. 404 `unknown_operation`, 410 `journal_pruned` (terminal row, journal aged out), 503 `journal_unreadable|journal_corrupt`. Served lines pass the keeper's `redact_json`.
- The TUI's bearer is Admin by construction (`bin/masc_tui_http.ml:65-115`, `Auth_login.mint ~role:Masc_domain.Admin`), and `get_json`/`auth_headers` already carry it to a CanAdmin route (`post_repository_add`, `:1676`). No credential work.

### The three representations today (what 3a touches, what it leaves)

- `bin/masc_tui_types.ml`: `msg_live : Masc_tui_keeper_chat_transcript.t option` (`:3151`), `msg_history : msg_entry list` (`:3133`), `msg_loaded : msg_entry list` (`:3156`, "replaced wholesale by a load"), `msg_reasoning_visibility` (`:3201`), `msg_memory_visibility` (`:3171`). `msg_entry` (`:327-361`), `msg_role` (`:118-156`, has `Message_thinking` and `Message_memory`), `msg_identity` (`:305-316`: `Persisted_row | Persisted_legacy_row | Session_row`).
- Inflight: `type inflight = { sent_request; submitted_at; sent_at; origin; mutable phase; live : Masc_tui_keeper_chat_transcript.t }` (`masc_tui_types.ml:2188-2195`; `live` at `:2194`).
- Live SSE path: `post_keeper_chat_watching` (`bin/masc_tui.ml:2074-2120`) creates a **fresh** `Keeper_chat_live.create ()` per (re)connect, feeds chunks, enqueues `Keeper_chat_stream_deltas`; handler (`:9923-9935`) does `Keeper_chat_transcript.apply ~now entry.live` per delta. On an `Outcome_unverified` error it sleeps 0.5s and re-POSTs the same `request_id` with no resume position.
- Settle: `settle_live_turn` (`:2137-2169`), called from `Keeper_chat_done` (`:9898`) and `Keeper_chat_dispatch_blocked` (rg `settle_live_turn` for the second site): copies `Trail_skill`/`Trail_tools` into `msg_history` via `append_chat_history`, drops `Trail_thinking`/`Trail_text`, clears `msg_live`. Then `apply_keeper_chat_result` (`:6482-`) appends the reply row from the strict decoder's `completed.reply` (= `KEEPER_REPLY_DETAILS`, `bin/masc_tui_keeper_chat_projection.ml:883-888`, `finalize` `:1261-1297`). Then `launch_keeper_history_load` (`:9914`) re-reads `/chat/history`; `Keeper_chat_history_loaded` (`:10230-`) runs `forget_session_rows_the_transcript_holds` (`:4901-`: keeper/tool/skill/thinking/memory session rows always dropped, user rows dropped when the transcript holds the request) and sets `msg_loaded <- history_entries @ memory_entries`.
- Retry: `Keeper_chat_transcript.apply` on `Live.Runtime_attempt_started` (`bin/masc_tui_keeper_chat_transcript.ml:1040-1053`) clears both buffers and pops the unfinished head `Node_text`/`Node_thinking`.
- Render: the committed timeline is built in `masc_tui_types.ml` (`chat_timeline` `:746-754`, `chat_timeline_slots` `:636-686`, `chat_timeline_rows` `:831-`, `compute_chat_rows_for` `:3890-`) from `msg_loaded @ msg_history` — `msg_live` never enters it. The live turn is drawn separately by `live_projection` in `bin/masc_tui_render.ml:8404-8505`. Reasoning visibility is applied **twice**: committed rows at `masc_tui_render.ml:7660` (`me_role <> Message_thinking || visibility <> Reasoning_hidden`), live trail at `:8492-8507`. Memos: `chat_rows_memo` (`masc_tui_types.ml:3929-3968`, keyed on `==` of `msg_loaded`/`msg_history`), `chat_timeline_ats_memo` (`render:7603-7618`), `visible_timeline_memo` (`:7630-7674`), `layout_entries_memo` (`:8000-8130`). 3a keeps the committed-timeline chain untouched (3b replaces it); 3a only adds one **suppression rule** to it.
- History decode: `bin/masc_tui_keeper_chat_history.ml` — a v1 row's `turn_id` is the operation request id when the row carries delivery provenance (`Delivery_identity.Operation request_id`, `:338-346`), else `turn_ref`. `Reasoning` rows come from trace blocks and become `Message_thinking` (`masc_tui.ml:4977-4978`) — but trace thinking steps are `content_withheld` today (RFC-0358 §2), so reload never shows reasoning text. That is the gap Task 7 closes.
- SSE framing: `classify_sse_line` (`bin/masc_tui_keeper_chat_projection.ml:1220-1229`) returns `Sse_ignored` for `id:` lines. Both decoders share it (`_live.ml:326`). The strict decoder must keep ignoring `id:`; the live decoder must read it.
- The strict decoder (`_projection.ml`) validates protocol shape and extracts only acceptance + `Reply_details` + tool occurrences; it accumulates no text. `Masc_tui_keeper_chat_live.delta` (`bin/masc_tui_keeper_chat_live.mli:19-65`, `event_deltas :335-323` pure) is the content-bearing type; `Keeper_chat_transcript.apply` is the fold that turns deltas into the trail. Neither carries `Reply_details` (the live decoder returns `[]` for `KEEPER_REPLY_DETAILS`, `_live.ml:269`).
- dune: every `bin/masc_tui_<x>` module except `masc_tui`, `masc_tui_render`, `masc_tui_loader`, `masc_tui_http` is its own `(library (name masc_tui_<x>) (wrapped false) (modules masc_tui_<x>) ...)` stanza with a `test/test_tui_<x>.ml`; the executable lists them under `(libraries ...)` (`bin/dune:975-1075`). New modules follow that pattern. `masc_tui_keeper_chat_live` links `masc` already (`bin/dune:328-332`), so `Masc.Keeper_chat_event_log` / `Masc.Keeper_chat_events` are reachable from the TUI.

### Concurrent work on the same file

`bin/masc_tui.ml` moves daily: between the RFC and this plan +130..+170 lines; between `b49c0654e1` and `e6983e357e` (one afternoon) #33119, #33118, #33114 landed in it and #33120, #33121, #33123 are open against it. Every task that edits `bin/masc_tui.ml` re-derives its anchors with `rg` at start, rebases before push, and keeps its diff to the chat pane's handlers so the owner's TUI PRs merge past it.

### Locked decisions

1. **Log entry unit = the TUI's `Masc_tui_keeper_chat_live.delta`, tagged with the journal seq.** Two total decoders feed it: the existing AG-UI `event_deltas` (live SSE, seq from the `id:` line) and a new `delta_of_journaled : Keeper_chat_events.keeper_chat_event -> delta list` (exhaustive match, no wildcard; adapter-only blocks map to `[]` exactly where the server projection maps to `None`). Rationale: the delta type already drives the transcript fold, the TUI never links server projection code, and no inverse AG-UI decoder is written. A golden test pins that the two decoders agree on the stage-1 golden fixture.
2. **The projection stays `Masc_tui_keeper_chat_transcript`**, made re-derivable: `of_log` re-folds a log from scratch. Live updates keep the incremental `apply` for cost; a re-fold from the same entries must produce an equal trail (pinned).
3. **Settle = `Log.commit`.** The trail is not copied into `msg_history` and `msg_live` is not cleared; the reply row is projected from the `Reply_details` entry. Committed-timeline rows whose request id the log holds are suppressed (one rule, `Message_user`/`Message_status`/`Message_local` exempt, mirroring `forget_session_rows_the_transcript_holds`), so a turn is drawn from exactly one source. Reasoning drawn from the log stays after settle; the second visibility site (`render:8490-8505`) stays for now but calls the same `Reasoning_visibility` rule as the first — full unification of the two render paths is 3b.
4. **Retry = supersede, not wipe.** `Runtime_attempt_started` increments the log's attempt counter; entries keep their attempt; the fold draws entries of earlier attempts as a `Trail_superseded` block (dimmed), never discards them.
5. **Reconnect = `since_seq = Log.last_seq`**, same decoder state, seq dedup on `add`. Entries without a seq (ACCEPTED, synthesized RUN_ERROR) are never deduplicated.
6. **Reload = fill the log from v2 for operations it does not hold**, bounded: only turns visible in the loaded transcript with an operation id, newest-first, at most `reload_journal_fetch_cap = 20` per load, only operations not already in the log (so the per-tick reload fetches nothing once filled). 404/410/503 → the v1 rows stay as they are (pre-journal, pruned, or broken); a fetched operation is drawn from the log and its v1 rows are suppressed by the rule in (3).
7. **What 3a does not touch:** `msg_history`/`msg_loaded` and their memo chain (3b), the Memory journal lane and the Ctrl-N/Ctrl-R toggles' storage (3c), the strict decoder's validation role (it keeps producing the terminal `response` for queue/inflight bookkeeping), the dashboard.

---

## Task 1: Test triage (RFC §6: "the first task of the stage")

No code. Appendix B of this document lists, per suite, which test cases pin three-representation behaviour that 3a deletes (category A), which survive (B), and which need a decision (C). Each later task names the A-cases it deletes or rewrites; a task that changes behaviour a B-case pins is wrong, not the test.

- [ ] Appendix B filled from the classification report and reviewed against the suite files.
- [ ] Confirm which lanes run in CI: `test/dune` registers the OCaml suites in the single `(tests ...)` stanza; the PTY suites run only under `test.yml`'s runner (check `test/dune` for the lane names before claiming a scenario is verified — `masc-tui-pty-suite-hides-never-run-scenarios`).

---

## Task 2: The live decoder reads the frame's seq

**Files:**
- Modify: `bin/masc_tui_keeper_chat_projection.ml{,i}` — `classify_sse_line` gains `Sse_id of int` (an `id:` line whose value is an int; a non-int `id:` stays `Sse_ignored`) and `Sse_frame_end` (the empty line); the strict decoder's loop treats both as before (ignored).
- Modify: `bin/masc_tui_keeper_chat_live.ml{,i}` — `t` gains `mutable pending_seq : int option`; `feed` returns `(int option * delta) list`: `Sse_id n` sets `pending_seq`, `Sse_data` tags every delta of that payload with `pending_seq`, `Sse_frame_end` clears it. A frame's `id:` may arrive in an earlier chunk than its `data:` — the state is on `t`, not local to one `feed`.
- Modify: every caller of `feed` (`bin/masc_tui.ml` inside `post_keeper_chat_watching`, and tests) — the handler passes seq through to Task 5's log; until Task 5 lands it discards it (`List.map snd`).
- Test: `test/test_tui_keeper_chat_live.ml` (extend), `test/test_tui_keeper_chat_projection.ml` (extend: `id:` line still ignored by the strict decode; a body with `id:` lines decodes to the same `response` as without).

- [ ] Failing tests first: (a) `"id: 7\ndata: {TEXT_MESSAGE_CONTENT}\n\n"` → `[(Some 7, Text "…")]`; (b) `id:` split across two `feed` calls; (c) an ACCEPTED frame after a seq-tagged frame carries `None`, not the previous seq; (d) `id: x` (non-int) → `None`; (e) strict decoder byte-equal outcome with and without `id:` lines.
- [ ] Implement; static review; commit:

```
feat(tui): the live chat decoder reads each frame's journal seq

Every projected SSE frame carries id: <seq> since #33103; the shared
line classifier threw it away. The live decoder now tags each delta
with the seq of its frame (None for frames that never went through the
bus: acceptance, the settle-time run_error), holding the id across a
chunk boundary and dropping it at the frame end so a later id-less
frame cannot inherit it. The strict decoder keeps ignoring id lines;
its outcome is pinned equal with and without them.
```

---

## Task 3: `Masc_tui_keeper_chat_log` — the per-operation event log

**Files:**
- Create: `bin/masc_tui_keeper_chat_log.ml{,i}`; dune stanza `(library (name masc_tui_keeper_chat_log) (wrapped false) (modules masc_tui_keeper_chat_log) (libraries masc masc_tui_keeper_chat_live masc_tui_keeper_chat_projection yojson))`; add to the `masc_tui` executable's `(libraries ...)`.
- Modify: `bin/masc_tui_keeper_chat_live.ml{,i}` — `delta` gains `Reply_details of { reply : string; turn_outcome : Masc.Keeper_turn_outcome.t; turn_ref : string }` decoded from `KEEPER_REPLY_DETAILS` (the strict decoder already validates the shape at `_projection.ml:883-888`; reuse its field reads).
- Test: `test/test_tui_keeper_chat_log.ml` (new; register like its siblings; links `masc_test_deps` so `Server_keeper_chat_agui_projection` and `Ag_ui` are available for the golden test).

```ocaml
(* masc_tui_keeper_chat_log.mli *)
type entry =
  { seq : int option   (** journal position; None for bus-less frames *)
  ; attempt : int      (** 0-based runtime attempt this entry belongs to *)
  ; delta : Masc_tui_keeper_chat_live.delta
  }

type t
val create : keeper_name:string -> request_id:string -> started_at:float -> t
val keeper_name : t -> string
val request_id : t -> string
val started_at : t -> float

(** Appends unless [seq] is [Some n] and an entry with seq [n] is already
    held. A [Runtime_attempt_started] delta advances [attempt] before it is
    stored (it is the first entry of the new attempt). Returns [true] when
    the entry was added. *)
val add : t -> seq:int option -> Masc_tui_keeper_chat_live.delta -> bool

(** Every entry from a v2 page, in journal order, each through
    {!delta_of_journaled}; entries already held by seq are skipped. *)
val add_journaled : t -> Masc.Keeper_chat_event_log.journaled_event list -> unit

val delta_of_journaled :
  Masc.Keeper_chat_events.keeper_chat_event -> Masc_tui_keeper_chat_live.delta list
(** Total: one arm per constructor, no wildcard. Adapter-only blocks
    ([Link_block], [Image_block], [Status_block], [Audio_block],
    [Tool_context_block]) and stream bookkeeping the live view does not draw
    map to [[]] — the same set the server projection maps to [None]. *)

val entries : t -> entry list          (** in insertion order *)
val last_seq : t -> int                (** highest seq held, or -1 *)
val attempt : t -> int                 (** current attempt *)
val commit : t -> unit
val committed : t -> bool
val revision : t -> int                (** bumped by every mutation; memo key *)
val decode_events_page :
  Yojson.Safe.t -> (Masc.Keeper_chat_event_log.journaled_event list * bool * int, string) result
(** [events, has_more, next_since_seq] of a masc.keeper_chat_events.v2 body. *)
```

- [ ] Failing tests: seq dedup (`add` with a held seq returns `false`, revision unchanged); `None` seqs never dedupe; `Runtime_attempt_started` bumps attempt and the entry carries the new attempt; `last_seq` with gaps; `commit` is idempotent and bumps revision once; `decode_events_page` on the fixture envelope from `test/test_keeper_chat_operation_http.ml`; `delta_of_journaled` covers all 33 constructors (iterate `test/test_keeper_chat_event_log.ml`'s `all_events` list and assert the arm set is total by matching each constructor to an expected delta list).
- [ ] **Golden**: fold the stage-1 `golden_events` through `Server_keeper_chat_agui_projection.project` → `Ag_ui.event_to_sse ~id:seq` → concatenate → `Keeper_chat_live.feed` (Task 2) and compare with `List.concat_map delta_of_journaled` over the same events tagged with their seqs: the delta lists and the seqs must be equal element-wise (entries that project to `None` are absent on both sides). This is the TUI-side twin of the stage-1 golden replay.
- [ ] Commit:

```
feat(tui): a per-operation event log for the keeper chat pane

One seq-ordered log per operation, fed by the live decoder's tagged
deltas and by v2 journal pages through a total decoder from the journal
event type; seq dedup, an attempt counter that supersedes instead of
wipes, a committed flag, and a revision for memo keys. The golden test
pins that a journal page and the live wire decode to the same deltas.
```

---

## Task 4: The transcript re-folds from the log; retry supersedes

**Files:**
- Modify: `bin/masc_tui_keeper_chat_transcript.ml{,i}` — `of_log : now:float -> Masc_tui_keeper_chat_log.t -> t` (create + apply every entry in order); `trail_item` gains `Trail_superseded of trail_item list` (the closed text/thinking/tool items of an attempt that a later `Runtime_attempt_started` superseded) and `Trail_reply of { reply : string; turn_outcome : Masc.Keeper_turn_outcome.t }` (from `Reply_details`); `apply` on `Runtime_attempt_started` moves the current trail into a superseded block instead of clearing buffers/popping the head; `apply` on `Reply_details` records it.
- Modify: `bin/masc_tui_render.ml` `live_projection` (the `match state.msg_live with` block, ~`:8406-8507`) — draw a `Trail_superseded` block's stretches in place with their own styles, each label ending in " ↺N" (N = the superseded try's number; at the tail because `fit_name` keeps a label's tail when it overruns). Dimming waits for 3b: the layout has no dim variant per style. `Reply_details` is recorded on the transcript (`reply`), not drawn — the server streams the reply as text deltas, chunked at the end when nothing streamed, so a trail item would draw the words twice; Task 5 derives the status row for non-visible outcomes from `reply`, and replaces the final attempt's text stretches with the canonical reply when they differ (the server strips control tokens from the visible reply).
- Test: `test/test_tui_keeper_chat_transcript.ml` (rewrite the A-cases from Appendix B that pin the wipe; add: re-fold equals incremental; superseded attempt keeps its text; reply row appears once from `Reply_details`).

- [ ] Failing tests → implement → commit:

```
feat(tui): a runtime retry marks the earlier attempt superseded, and the
transcript re-folds from the log

Runtime_attempt_started used to clear both buffers and pop the trail
head, so what the operator was reading vanished. The prior attempt's
trail is now kept as a superseded block; the new attempt appends after
it. The transcript can be rebuilt from a log in one fold, pinned equal
to the incremental apply, and Reply_details is a trail item so the
reply row is projected, not appended.
```

---

## Task 5: Settle is a committed flag; the live turn is drawn from the log

**As built (PR #33133).** The plan below said: keep `inflight.log : Log.t` and a projection cache keyed on `Log.revision`, re-folding with `of_log` when the revision moves. Built instead: `turn_log = { tl_log; tl_transcript }` in `masc_tui_types.ml` with one writer, `turn_log_add ~now`, which appends to the log and folds the same delta into the transcript exactly when the log accepted it (not a duplicate seq). The transcript is therefore always the fold of the log (`of_log` equality, pinned by test) with each delta folded at its arrival time. A revision-keyed re-fold would have dated every tool call to the re-fold (the progress row's ages and oldest-open-call choice go wrong — the F5 problem, now confined to Task 7's journal fill) and cost O(n) per frame on a long turn. Other deviations, each with its reason:

- **Completeness decides whether a log holds its turn.** `turn_log_holds_the_turn` = committed and (transcript phase `Stream_failed _`, or `Stream_ended` with a recorded reply). A finish without a reply is a cancelled turn (the server ends a cancelled stream with RUN_FINISHED and no KEEPER_REPLY_DETAILS) whose ending the log cannot draw; a log whose stream never told it how the turn ended (the no-Eio-clock path posts without a live view; a cut stream with nothing replayed) holds part of the turn at most. In both the loaded rows keep drawing the turn and the strict decode's reply row is appended as before. The same predicate gates the suppression rule, the reply row, and which settled blocks the renderer draws — one function, three callers (`completed_turn_row` and `settle_turn_log` in `masc_tui_types.ml` are the two decisions, tested directly).
- **The suppression rule is per held turn** (`held_turn = { ht_request_id; ht_reasoning }`, `log_draws_row`): `Message_keeper | Message_autonomous | Message_tool | Message_skill _` rows of a held request leave; `Message_thinking` leaves only when the log carries reasoning (a runtime that streams none leaves the durable "content withheld" row as the only record that the keeper thought); `Message_user | Message_status | Message_local | Message_error | Message_memory` stay. The wire carries neither a call's outcome nor its duration, so before a held turn's tool row leaves, what it knew is folded into the log's transcript by execution id (`Transcript.note_tool_outcome`, `enrich_held_logs_from_rows`, run where loaded rows arrive and where a journal log is held). RFC-0412 stage 4 puts those facts on the wire; until then this is the bridge.
- **`Transcript.drawn`** is the one projection step: it flattens superseded blocks (tagged with their attempt) and reconciles the recorded reply by outcome. The recorded reply is the terminal message's text (`text_of_content result.response.content`, normalized), not the whole turn's, so only the current attempt's last text stretch is compared (trimmed): equal, the trail stays; different, that one stretch is replaced by one `Drawn_reply` (appended when nothing streamed); earlier stretches — the turn's earlier rounds — stay. A blank `Visible_reply` or a control outcome appends one `Drawn_status`. `Transcript.reply` became a record carrying `turn_ref`, which the status sentence needs. `turn_status_text` is the shared sentence; `chat_status_text` in `masc_tui.ml` delegates to it.
- **Reasoning visibility rule** is `reasoning_drawn : reasoning_visibility -> bool`, not the two-armed `[`Row | `Trail]` version: both sites ask the same question, so one argument was enough. Folding stays a local `= Reasoning_folded` at both sites.
- **A log with no entries is not kept at settle** (`Keeper_chat_dispatch_blocked`, or a stream that never opened): nothing to draw.
- **Placement and corners**: a settled block goes after its request's last committed row of any phase before output (`chat_settled_insertion_index`), so a failed turn's words sit above its own error row and above the turns that ran in between; the live block goes after every committed row of its request. Corners are set once over the merged order — a request's first row opens, its last closes, a live block's turn stays open — replacing the per-block edge computation and the separate rail patch pass. A block with nothing drawn (all reasoning, hidden; a log of bookkeeping frames only) is no block.
- **Memo**: settled blocks are memoized per (keeper, request) on the transcript's revision (`Transcript.revision`, bumped by `apply`, `note_interrupt`, `note_tool_outcome`), the committed timeline's identity, the reasoning/tool knobs and the width; while no block is live the merged list is reused whole, so `row_counts_for` keeps its counts and an idle pane holding settled turns costs what it did before they were logs.
- **Scroll pin**: `rows_since_pin` is 0 only while a live block exists. Taking the pin records the settled logs then held (`msg_scroll_pin_settled`); a settled block's rows count as arrived since the pin only when its log was held later.
- **Lookups are keeper-scoped** (`settled_log_for_request state ~keeper_name`), like every other reading of the settled logs.

**Files (as built):**
- `bin/masc_tui_types.ml` — `turn_log`, `turn_log_create`, `turn_log_add`, `turn_log_keeper_name`, `turn_log_request_id`, `turn_log_holds_the_turn`; `inflight.log : turn_log`; `msg_live : turn_log option`; `msg_settled_logs : turn_log list` (oldest first, all keepers); `settled_log_for_request`, `settled_logs_for_keeper`; `reasoning_drawn`; `log_draws_role`, `rows_the_logs_do_not_draw` applied to both loaded and session rows in `compute_chat_rows_for`; the rows memo keys on `msg_settled_logs` by physical identity.
- `bin/masc_tui.ml` — `Keeper_chat_stream_deltas of request * (int option * delta) list` (the watch loop no longer drops the seq); the handler calls `turn_log_add`; `settle_live_turn` commits and moves the log; `apply_keeper_chat_result` appends the reply row only when no settled log holds the turn; `append_chat_history` lost its `?tool_block`/`?skill_activity` arguments (no caller left); `chat_status_text` delegates to `Transcript.turn_status_text`; every `msg_live`/`entry.live` reader takes the transcript from `.tl_transcript` or the identity from `turn_log_*`.
- `bin/masc_tui_render.ml` — `log_projection ~committed` builds one block from a `turn_log` through `Transcript.drawn`; settled blocks (filtered by `turn_log_holds_the_turn`) then the live one are merged into the committed rows at each block's own `chat_live_insertion_index`, ties keeping block order; the rail correction covers every block's request; `reasoning_drawn` at both filters.
- `bin/masc_tui_keeper_chat_transcript.ml{,i}` — `reply` record, `turn_status_text`, `drawn`/`drawn_item`.
- Tests: `test_tui_keeper_chat_transcript` (six `drawn` cases, `turn_status_text`); `test_tui_chat_queue_wiring` (turn_log folds each accepted delta once; settle commits and copies nothing — AST; the reply row defers to a holding log — AST; a settled log holds its turn in the timeline and a reload does not bring the rows back; an unfinished log suppresses nothing; per-keeper reading); `test_tui_chat_timeline_assembly` (the rule by role); `test_tui_chat_rows_memo` (settled logs are a key).

**Files (as planned, kept for the record):**
- Modify: `bin/masc_tui_types.ml` — `inflight.live : Masc_tui_keeper_chat_transcript.t` → `log : Masc_tui_keeper_chat_log.t` plus a `mutable projection : (int * Masc_tui_keeper_chat_transcript.t) option` cache keyed on `Log.revision`; `msg_live : Masc_tui_keeper_chat_log.t option`; a new `msg_settled_logs : Masc_tui_keeper_chat_log.t list` per keeper (committed logs of this session, newest last) — the "same document" the render continues from.
- Modify: `bin/masc_tui.ml` — `Keeper_chat_stream_deltas` → `Log.add`; `settle_live_turn` → `Log.commit` + move the log to `msg_settled_logs`; delete the `Trail_skill`/`Trail_tools` copy into `msg_history`; `apply_keeper_chat_result` stops appending the reply row for a request the log holds (the log has `Reply_details`); `forget_session_rows_the_transcript_holds` unchanged for the rows it still governs (user/error); the committed timeline gains the suppression rule: rows of a request id held by a settled log are dropped unless `Message_user | Message_status | Message_local` (one function in `masc_tui_types.ml`, applied where `compute_chat_rows_for` filters by keeper).
- Modify: `bin/masc_tui_render.ml` — the live block draws every settled log of the shown keeper followed by the live one, each through the cached projection; a settled log's rows are the committed styling; reasoning visibility for log rows goes through one function `reasoning_visible : reasoning_visibility -> [`Row | `Trail] -> bool` also called at `:7660`. **The reply row comes from `Transcript.reply`, by outcome** (Task 4 review, F4): `Visible_reply` with a nonblank reply → the final attempt's `Trail_text` stretches are replaced by one keeper row carrying the canonical reply when their concatenation differs from it (the server strips control tokens from the visible reply), otherwise drawn as they are; the four control outcomes (`Continuation_checkpoint`, `Terminal_effect_settled`, `Awaiting_gate_approval`, `No_visible_reply`) → one `Message_status` row built the way `chat_status_text` builds it today, since nothing was chunked for them and the reply text exists only in `reply`. Test each outcome.
- Test: `test/test_tui_chat_queue_wiring.ml` (rewrite the A-cases that pin settle-copies-rows and settle-clears-live; add: after settle the log is committed and still drawn; a reload does not remove it; the timeline suppresses the loaded rows of a log-held request); `test/test_tui_chat_timeline_assembly.ml` (suppression rule).

- [ ] Failing tests → implement → commit:

```
feat(tui): settle commits the turn's log instead of swapping representations

The live trail used to be copied into session rows and cleared on
settle, then replaced again by the next history load — three
representations, two replace-flickers, reasoning lost at the first.
A settled turn now stays the log it was, drawn by the same projection
with committed styling; the loaded transcript's rows for that request
are suppressed so the turn has one source. Reasoning stays on screen
after settle; the two visibility sites call one rule.
```

---

## Task 6: Reconnect resumes with `since_seq`

**As built (PR #33133).** The position rides beside the request in the POST body — `request_body ~since_seq` / `request_to_yojson ~since_seq` — not as a field of `request`: the request is the operator's words and keeps one identity across resends, `same_request_identity` never had to learn to ignore anything, and no literal construction of the record changed (the trap `record-field-grep-misses-the-factory` names). `post_keeper_chat_streaming ~since_seq` carries it; the first POST passes `None` and its body is byte-identical to before. The watcher takes the request's `Log.t` as an argument (`~log`, from the inflight entry's `turn_log`) and re-POSTs from the larger of `Log.last_seq` and the highest seq it has itself handed to the mailbox (the log is folded by the main loop and may be behind at that moment; the overlap either way is absorbed by seq dedup); each (re)connect still opens a fresh decoder. The acceptance is read by the transcript and not kept in the log, so a re-POST adds no entry. Pinned: the body with and without a position (and `-1` for an empty log), a fresh decoder after a cut `id:` line, the watcher reading `last_seq` and creating decoders (AST), and replayed seqs at or below the last held being folded once.

**Files (as planned):**
- Modify: `bin/masc_tui_keeper_chat_projection.ml{,i}` — `request` gains `since_seq : int option`; `request_to_yojson` emits it when `Some`; `same_request_identity` ignores it; `create_request` defaults `None`.
- Modify: `bin/masc_tui.ml:2074-2120` (`post_keeper_chat_watching`) — the LOG is what carries across the reconnect, not the decoder: a stream cut right after an `id:` line leaves `pending_seq` armed and the partial bytes in `pending`, and the next stream's first frame is the id-less acceptance, which would inherit the seq while the leftover bytes glue onto the next chunk and are dropped as an unknown line (Task 2 review, L2). So each (re)connect still creates a fresh `Keeper_chat_live.create ()`; the re-POST sends `{ request with since_seq = Some (Log.last_seq log) }` (the log is reachable through the inflight entry); the acceptance frame of the new stream has no seq and is not deduplicated (decision 5). Pin with a test that feeds `"id: 9\n"` then reconnects and checks the acceptance is tagged `None`.
- Test: `test/test_tui_keeper_chat_projection.ml` (request body with/without `since_seq`; identity unaffected); `test/test_tui_chat_queue_wiring.ml` (a reconnect after seq 5 sends `since_seq: 5`; replayed seq ≤ 5 frames are not added twice — drive `Log.add` with the replayed tagged deltas).

- [ ] Failing tests → implement → commit:

```
feat(tui): a dropped chat stream resumes from the last journal seq

The watch loop re-POSTed the same request with a fresh decoder and no
position, so the server sent the whole turn again and the pane drew it
twice or not at all. It now sends since_seq = the log's last seq, keeps
its decoder, and the log's seq dedup absorbs the overlap the server's
replay-then-live window produces.
```

---

## Task 7: Reload rebuilds journaled turns from `/chat/events`

**As built (PR #33133).** The F5 prerequisite is met without a `ts` on log entries: `turn_log_add_journaled` folds each journal line at the line's own `ts` (the journal already carries it), so a rebuilt turn's tool calls keep their real start times; the live wire keeps folding at arrival time, and `Log.entry` is unchanged. `Log.hold_seq` is the one place an undrawn position is held (`add_journaled` and the turn-log fold both use it). The typed fetch error lives in the log module (`events_error`, `decode_events_error` by envelope code) so it is unit-tested without HTTP; `Masc_tui_http.fetch_keeper_chat_events` checks the page's `operation_id` against the one asked for. The history row's `operation_id` is set from the delivery key only when it is an operation, on every row of a direct turn (threaded through the tool fold), `None` on autonomous, trace, skill and journal rows. Target choice is the pure `journal_fetch_targets` (each operation once, newest first by its earliest row, minus settled logs that hold their turn and inflight requests, minus `msg_journal_unavailable`, cap `reload_journal_fetch_cap = 20`), run when a history page loads; one fiber per target pages the endpoint at the server's ceiling (`journal_reload_page_limit = 2000`, following `has_more` only while `next_since_seq` advances). A read starts after what the session already holds of the turn (`journal_resume_position`: a cut stream's partial log, or an earlier read of a turn then still running) and the lines join that log; an operation being read is in `msg_journal_inflight` and not asked for again until the read returns. The handler commits and holds the log (`hold_settled_log` inserts by start time and never replaces a log that stands for its turn); a log that stands for the turn (`turn_log_holds_the_turn`) is enriched from the loaded rows; one read whole that still does not, when the loaded transcript says the turn is over (a reply or failure row), is remembered as not worth asking again — the settle-time failure is never journaled (#33108), so such a journal never gains a terminal line. `Unknown_operation`/`Journal_pruned`/`Journal_unavailable`/`Events_undecodable` are remembered per operation for the session; a 401/403 is `Events_refused`, said once, after which no journal is asked for this session; `Events_transport` is not remembered. The page loop is `Log.read_whole_journal ~fetch`, pure over the fetch and tested. The journal-loaded message is not generation-guarded: a log is the turn's record whichever keeper the pane shows. PTY needles for the withheld-reasoning row (Appendix B) were left as they are: the fake server has no `/chat/events` route, so the client's typed error keeps the v1 rows.

**Files (as planned):**
- Modify: `bin/masc_tui_http.ml` — `fetch_keeper_chat_events ~host ~port ~keeper_name ~operation_id ~since_seq ~limit : (Yojson.Safe.t, error) result` where `error = Unknown_operation | Journal_pruned | Journal_unavailable of string | Transport of string` decoded from the envelope's `error` code (404/410/503) — typed, no string matching on messages. Check the page's `operation_id` against the request before adding it to a log.
- Prerequisite (Task 4 review, F5): `Masc_tui_keeper_chat_log.entry` gains `ts : float option` — the journal line's `ts` for a page, the AG-UI event's `timestamp` for a live frame (the live decoder reads it from the event JSON; since #33109 it is the bus stamp, the same value the journal holds) — and `Transcript.of_log` applies each entry with `~now:ts`, so a re-folded turn's tool calls carry their real start times and the progress row's ages and oldest-open-call choice equal the live fold's. Until then a re-folded transcript is equal in trail, totals, attempt, phase, tool rows and reply only, and a settled turn's status rows are not drawn from a re-fold.
- Modify: `bin/masc_tui.ml` — in `Keeper_chat_history_loaded`, collect the operation ids of loaded turns (`row.turn_id` when it came from `Delivery_identity.Operation` — expose that provenance from `masc_tui_keeper_chat_history.ml:338-346` as a typed field `operation_id : string option` on `row` rather than reusing the overloaded `turn_id`), newest-first, minus those already in `msg_settled_logs`, capped at `reload_journal_fetch_cap = 20`; launch one fiber per id (bounded by the cap) that pages the endpoint (`limit = 2000`, follow `has_more`) and enqueues `Keeper_chat_journal_loaded (keeper, operation_id, journaled_event list)`; the handler builds a committed `Log` with `add_journaled`, appends it to `msg_settled_logs` in transcript order (order by the loaded row's `me_at`), so the suppression rule from Task 5 hides the v1 rows and the projection draws the turn with its reasoning. `Unknown_operation`/`Journal_pruned`/`Journal_unavailable` leave the v1 rows drawn and are remembered per operation id for the session so the reload does not refetch them.
- Test: `test/test_tui_keeper_chat_history.ml` (operation id provenance is typed); `test/test_tui_chat_queue_wiring.ml` or a new `test/test_tui_keeper_chat_journal_reload.ml` (journal-loaded turn suppresses v1 rows and draws reasoning; 410 keeps v1 rows; the cap; already-held operations are not refetched).

- [ ] Failing tests → implement → commit:

```
feat(tui): a reloaded turn is rebuilt from its journal, so reasoning survives restart

Trace thinking steps in the v1 history are content-withheld by design,
so a TUI restart lost every turn's reasoning. For loaded turns that
carry an operation id the pane now fetches /chat/events (CanAdmin,
which the TUI's token already is), builds the same committed log a live
turn settles into, and draws it through the same projection; the v1
rows of that turn are suppressed. Pruned, unknown or unreadable
journals leave the v1 rows as they were. At most 20 turns per load, and
only operations the session does not already hold.
```

---

## Verification (stage-level)

- CI `@check` per task (`ci.yml`); `test.yml` at the end of each task that touches `bin/masc_tui.ml` (the behavioural suite is the only lane that runs Alcotest).
- PTY: `test/test_capture_tui_keeper_chat.py` / `test_tui_keyboard_input.py` scenarios that touch settle (`reasoning`, `THINKING`, `Ctrl-R` needles) — rewrite per Appendix B; confirm their lane is wired in `test/dune` before claiming them verified.
- Manual on the live server after merge: send a turn with a reasoning-capable Agent_core runtime, watch settle keep the THINKING block; kill the TUI's connection mid-turn (`kill -STOP` the server for 3 s) and confirm resume without duplicate rows; restart the TUI and confirm the last turns show reasoning.

## Appendix A: RFC §3.3 bullets → sub-stage

| §3.3 bullet | sub-stage |
|---|---|
| single ordered event log (seq) + one projection | 3a (live + settled turns), 3b (loaded transcript) |
| settle = committed flag, reload = continuation, no replace flicker | 3a |
| reasoning as its own category, kept after settle | 3a |
| Ctrl-R visibility rule in one place; runtime differences only as event presence | 3a (one rule, two call sites), 3c (one call site) |
| physical-identity memo chain → seq/revision keys | 3a for the log projection; 3b for `chat_rows`/timeline/layout memos |
| ATTEMPT_STARTED = superseded marking | 3a |
| journal as a typed lane; summary/full/hidden as a projection parameter | 3c |

## Appendix B: Test triage (Task 1)

Method: every `test_case` in the 13 OCaml suites and the 2 PTY suites was matched against the markers of the behaviour 3a deletes (`settle_live_turn`, `msg_live`, `forget_session_rows_the_transcript_holds`, `Runtime_attempt_started`, `Trail_thinking`/`Message_thinking`, `msg_loaded`, `Reasoning_*`), and each hit was read at its enclosing test. Counts are `test_case` occurrences on main `e6983e357e`.

| suite | cases | A (deleted by 3a) | C (decision) | B (survives) |
|---|---|---|---|---|
| test_tui_keeper_chat_transcript | 55 | `test_runtime_attempt_reset_keeps_finished_speech_in_the_trail` (:270), `test_runtime_attempt_reset_discards_only_unfinished_narrative` (:301) — both pin the wipe; Task 4 rewrites them as "the earlier attempt is kept, marked superseded" | — | 53, incl. the trail-order cases (`:1099`, `:1144`) that keep passing because the trail's order is unchanged |
| test_tui_chat_queue_wiring | 59 | — | `test_concurrent_turns_keep_request_owned_transcripts` (:674, an AST test naming the `settle_live_turn` binding — the name stays, the body changes; keep, re-read after Task 5); `test_a_transcript_reload_replaces_only_an_exact_user_row` (:1184 — `forget_session_rows_the_transcript_holds` keeps governing user/error rows in 3a; keep, and add the suppression-rule case beside it) | 57, incl. the visibility state/cycle cases (:808, :882, :946) — storage of the toggle is untouched in 3a |
| test_tui_keeper_chat_live | 23 | — | — | 23; `feed`'s return type changes in Task 2, so every call site takes `List.map snd` or asserts the seq — mechanical |
| test_tui_keeper_chat_projection | 40 | — | — | 40; the `request` record gains `since_seq` in Task 6 — literal constructions take `since_seq = None` |
| test_tui_keeper_chat_history | 52 | — | — | 52; Task 7 adds a typed `operation_id` field, constructors unchanged |
| test_tui_chat_rows_memo | 5 | — | — | 5 — they pin the physical-identity memo, which 3a leaves alone; they become A in 3b |
| test_tui_message_layout | 77 | — | — | 77 |
| test_tui_chat_timeline_assembly | 16 | — | — | 16, plus new cases for the suppression rule (Task 5) |
| test_tui_keeper_chat_diff, _queue, chat_gate_row, chat_surface_mirror, memory_fold | 31+16+4+2+5 | — | — | all |
| **total** | **385** | **2** | **2** | **381** |

PTY (`test/test_tui_keyboard_input.py`, lane wired at `test/dune:3551-3578`): the needles `2 reasoning steps, content withheld` and `· THINKING` (:5764-5767) draw a reloaded turn's reasoning from v1 trace blocks. Under Task 7 the fake server in that scenario answers `/chat/events` with nothing (no route → the client's typed error → v1 rows stay), so the needles still hold; if the scenario's server gains the route, the expected screen becomes the real reasoning text. Decide at Task 7. `test_capture_tui_keeper_chat.py` touches only `last_runtime_attempt` (:103) — B.

So the RFC's expectation ("some pin the merge behaviour") is true but small for 3a: two cases pin the wipe, two need a re-read after Task 5, and the memo suite moves to 3b. The larger rewrite the RFC anticipated belongs to 3b (timeline/memo chain).
