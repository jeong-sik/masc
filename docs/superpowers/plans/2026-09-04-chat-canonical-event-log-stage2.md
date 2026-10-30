# Chat Canonical Event Log — Stage 2 (Serving Cutover) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve keeper chat from the canonical per-turn event journal: a dual-write consistency auditor first, then seq on the SSE wire, since_seq replay, a v2 events endpoint carrying reasoning, and finally the v1 history re-implementation with the fail-open→fail-closed flip.

**Architecture:** RFC-0412 stage 2 (`docs/rfc/RFC-0412-chat-is-one-canonical-event-log.md`, §3.2/§3.5/§4/§6). The stage-1 journal (`lib/keeper/keeper_chat_event_log.ml`) is the future record of record; stage 2 proves it equals the legacy `keeper_chat_store` (auditor soak gate), exposes `seq` on the wire, then switches reads over. v1 response bytes stay frozen until the gate passes.

**Tech Stack:** OCaml 5.5 / Eio / Alcotest. No local dune (constitution execution protocol) — static review + ocamlformat + CI (`gh workflow run ci.yml --ref <branch>`).

---

## Context (read first)

### Stage-1 artifacts this stage builds on

- `lib/keeper/keeper_chat_event_log.ml{,i}` — journal. `journaled_event = { seq:int; ts:float; event: Keeper_chat_events.keeper_chat_event }` (`.mli:8-12`). `open_journal ~base_dir ~keeper_name ~operation_id` → `<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl` (sanitized segments). `append` is **fail-open** (logs, never raises except `Eio.Cancel.Cancelled`). `read_journal` (`.mli:69-72`) is a strict full-file decode that **raises `Invalid_argument` on a corrupt line and `Sys_error` when the file is missing** — every production caller must handle both.
- `lib/keeper/keeper_chat_events.ml{,i}` — the bus. Abstract `type t`; `create ?on_publish`; `publish` assigns the 0-based seq and runs the journal hook BEFORE `Eio.Stream.add` (single publisher fiber ⇒ journal order == seq order == bus order). `subscribe : t -> keeper_chat_event` blocks. `take_nonblocking` is drain/test support only.
- `lib/server/server_keeper_chat_agui_projection.ml{,i}` — pure fold. `project : timestamp:float -> redact_text -> redact_json -> t -> keeper_chat_event -> t * Ag_ui.event option`. `is_terminal = Event_error _ | Run_finished _`. Golden test (`test/test_keeper_chat_event_log.ml` "golden replay") proves: folding journaled entries from `initial` while feeding `entry.ts` as `~timestamp` reproduces the live SSE bytes exactly.
- `lib/ag_ui/ag_ui.mli:110` — `event_to_sse : ?id:int -> event -> string`. The `?id` parameter exists but no caller uses it yet.
- Retention: `keeper_chat_events` is pruned (mtime, `MASC_JSONL_RETENTION_DAYS` default 30) via `prune_shared_jsonl_stores` (`lib/server/server_runtime_startup_maintenance.ml:221-228`). Any stage-2 reader must tolerate a pruned journal.

### Production wiring (verified)

- Only `Keeper_chat_events.create` site in `lib/`: `lib/server/server_routes_http_keeper_stream.ml:2616-2630` (`operation_executor`), journal opened at :2619-2625.
- Dashboard adapter fiber (`:2655-2688`): loops `subscribe` → `Projection.project` → fans out to `Keeper_chat_broadcast.operation_event` (`:2678-2681`) and `publish_operation_live_event` (`:2682`), stops on `is_terminal`.
- SSE handler `handle_keeper_chat_stream` (`:2963-3099`): responds 200 SSE immediately, sends `retry: 1500\n\n` frame (`:2992-2994`), registers a live sink per `operation_id` (`register_operation_live_sink`, `:80-107`), submits to the Owner FIFO (`:3057-3074`), sends `CUSTOM/KEEPER_CHAT_OPERATION_ACCEPTED` with a `buffered` ref (`:2999-3023`) absorbing the submit race, finishes on terminal event.
- SSE frames are written by `keeper_stream_send_event` calling `Ag_ui.event_to_sse` **without** `?id` (`:1017-1018`).
- `run_id` in the journal's `run_started` = `"keeper-operation-run-" ^ operation_id` (`:2852`) — the journal is self-describing.
- Terminal event order on success: `Reply_details → (External_effect_completed/Status_block) → Text_message_end → Run_finished` (`:2525-2557`). On error: `Text_message_end → Event_error` (`:2494-2496, 2564-2572`).
- `Reply_details = { reply : string; turn_outcome : Keeper_turn_outcome.t; turn_ref : Ids.Turn_ref.t }` (`keeper_chat_events.mli:68-72, 91`) — the journal's carrier of final text + store join key.

### Store side (auditor comparison target)

- `lib/keeper/keeper_chat_store.ml{,i}` — rows at `<base>/.masc/keeper_chat/<name>.jsonl`. `chat_message` fields include `role`, `content`, `ts`, `kind : Row_kind.t` (`Utterance|Transport_failure`), `turn_ref option`, `stream_lifecycle : stream_lifecycle_event list option` (`Run_started|Text_message_start|Text_message_end|Run_finished|Run_error`), `delivery_provenance option`, `execution_id option` (tool rows).
- Readers: `load` is capped (100 primary / 400 lines / 4 MiB tail) — **wrong for audit**. `load_all` (`.mli:497-498`) is uncapped, "reserved for durable acknowledgement scans" — the auditor's reader.
- `transcript_of_messages msgs ~turn_ref` (`.mli:545-553`) implements the exact join: assistant rows by `turn_ref`, user rows by `turn_ref` OR `Accepted_user` delivery provenance, tool rows excluded.
- Delivery-key join: `queue_delivery_key` (`server_routes_http_keeper_stream.ml:1678-1684`) = `Keeper_chat_delivery_identity.Operation (Request_id.of_string operation_id)`; slots include `Accepted_user`, `Tool_call { execution_id; ordinal }`, `Terminal_assistant` (`keeper_chat_delivery_identity.mli:13-50`).
- `turn_ref` minted once per turn (`lib/keeper/keeper_turn.ml:480-484`), wire form `"<trace_id>#<absolute_turn>"`.

### Known semantic skews (the auditor must encode, not discover)

1. **Surface-post mid-turn rows have no join keys** — `keeper_tool_in_process_runtime.ml:1273,1340,1534` call `append_assistant_message_result` with no `?turn_ref`/delivery_key. They land inside the turn's time window. Explicit exclusion class, never a mismatch.
2. **Reply inversion**: on `Terminal_effect_settled` + surface post, the tool's row carries the user-facing answer while the settle path persists the harness `reply` text (often trailing narration) as a second assistant row (`control_turn_delivery`, `server_routes_http_keeper_stream.ml:1513-1521`). The journal's `Reply_details.reply` equals the settle row's content, not the surface-post row's.
3. **Outcome-dependent row shapes** (`:2099-2166`): `Visible_reply` → one assistant row; `No_visible_reply`+blocks → assistant row with `content=""`; tool-calls-only continuation → tool rows and NO assistant row; `Continuation_checkpoint`/`Terminal_effect_settled` → assistant row from `control_turn_delivery`.
4. **Text_delta count ≠ row count** — `split_keeper_reply_chunks` (`:2522-2524`) splits; compare mapped classes only.
5. **Crash → truncated journal** (no terminal event) + operation settled `Interrupted_by_restart` (`keeper_chat_operation_store.ml:1014-1037`). Verdict class, not mismatch.
6. **Redaction boundary**: `Keeper_chat_store.load*` returns the redacted view; journal terminal text is already `redact_text`'d before publish. Compare on the redacted side.

### Serving side (v1, byte-frozen until the gate passes)

- `/chat/history`: `server_dashboard_http_keeper_api.ml` — dispatcher `:868-883`; body `keeper_chat_history_json` (`:575-601`): `Keeper_chat_store.load` + trace blocks (`keeper_chat_trace_blocks :406-422`, from trajectory, 200-step cap) + `to_json_array` (`keeper_chat_store.ml:2798-2868`) + autonomous rows (`:384-404`) + skill-activation rewrite. 30s `Dashboard_cache` (`:653-686`).
- `/chat/history/page?before=<ts>`: `:841-867`, envelope `{schema:"masc.keeper_chat_history.page.v1", messages, has_more, next_before}`.
- Dashboard valibot union (`dashboard/src/api/schemas/keeper-chat-history.ts:136-233`) already accepts block variants `thinking` and `trace`; unknown `blocks[].t` drops the whole row silently (#28407).
- Tests pinning v1: `test/test_keeper_chat_store.ml` (heaviest), `test/test_server_dashboard_http_keeper_chat_page.ml`, `test/test_keeper_autonomous_turn_source.ml:534`, `test/test_keeper_skill_activation_projection.ml:255`, `test/test_server_dashboard_http_keeper_api_trace.ml`, plus dashboard `keeper-chat-history.test.ts` and `test/test_tui_keyboard_input.py` fixtures.

### Reasoning trajectory today

- `lib/keeper/keeper_agent_run_thinking_trajectory.ml` writes metadata-only `Withheld_thinking` entries (`{ts; turn; block_index; reasoning_kind; char_count}`) via the AGENT_CORE `after_turn` hook (`lib/keeper/keeper_hooks_agent_core.ml:445-447`) to `trajectories/<keeper>/<trace_id>.jsonl`.
- Readers: `server_dashboard_http_keeper_api_trace.ml` (`dedupe_thinking_lines` :11-28, step conversion :30-66, `chat_trace_block_by_turn_ref` :89-139). Join key differs from the journal: trajectory = `(trace_id, absolute_turn)`; journal = `operation_id`. Bridge: `Reply_details.turn_ref` = `"<trace_id>#<absolute_turn>"`.

### Repo rules (binding)

- Whole tree `-warn-error +a`: every new `.ml` val needs the `.mli`; no unused bindings.
- `lib/server` is `masc_server` with `(wrapped false)`: flat module names (`Server_keeper_chat_agui_projection`, NOT `Masc.Server_*`). `lib/keeper` modules surface as `Masc.Keeper_*` through wrapped `lib/masc`. `Common` is flat (from `masc_core`).
- Commits: lowercase conventional, long body, `git commit -F /tmp/<file>` (macOS bash 3.2 breaks heredoc-in-$()).
- New metrics: `Keeper_metrics.t` is a closed `ppx_enumerate` sum — add a constructor near `ChatStoreFailures` (`keeper_metrics.mli:132`), then use `Otel_metric_store.inc_counter Keeper_metrics.(to_string X) ~labels`.
- Periodic server work precedent: `server_bootstrap_maintenance.ml` — 60s tick fiber (`:14`), 24h guard (`:965-967`), `fork_logged_fiber`, per-tick try/with that never cancels the loop.

---

## Task 1: Consistency auditor (the stage-2 gate)

RFC-0412 §3.5: the auditor is stage 2's FIRST task; the read-path cutover (Task 5) is gated on it reporting zero unexplained divergence over a soak window.

**Files:**
- Create: `lib/keeper/keeper_chat_journal_audit.ml`
- Create: `lib/keeper/keeper_chat_journal_audit.mli`
- Modify: `lib/keeper_metrics/keeper_metrics.mli` (one constructor) and `.ml` (ppx-enumerated; check whether the .ml needs a matching arm — it is derived)
- Modify: `lib/server/server_bootstrap_maintenance.ml:960-1015` (hook into the existing periodic pass)
- Test: `test/test_keeper_chat_journal_audit.ml` (new; register in `test/dune` next to `test_keeper_chat_event_log`)

The auditor is a **pure comparison core** + a **sweep driver**:

```ocaml
(* keeper_chat_journal_audit.mli *)

(** RFC-0412 stage 2 consistency auditor: proves the stage-1 journal and the
    legacy keeper_chat_store record the same turns, before any read path
    switches to the journal. Pure core + IO shell; the sweep is driven from
    the server maintenance fiber. *)

type mismatch_kind =
  | Terminal_outcome  (** journal ended Run_finished but the store row's
                          stream_lifecycle ends Run_error, or vice versa *)
  | Assistant_text    (** the Terminal_assistant row's content differs from
                          the journal's Reply_details.reply *)
  | Tool_rows         (** a Tool_result_ready execution_id has no tool row,
                          or a joined tool row has no Tool_result_ready *)
  | Seq_gap           (** journal seqs are not contiguous 0..n-1: a swallowed
                          hook exception consumed a seq without a line *)
  | Missing_terminal_row  (** terminal events present, no joined store rows *)
[@@deriving show, eq]

type verdict =
  | Match
  | Mismatch of mismatch_kind list
  | Journal_missing        (** fail-open append may never have created it *)
  | Journal_truncated      (** no terminal event; crash/interrupted turn *)
  | Journal_corrupt of string  (** read_journal raised Invalid_argument *)
[@@deriving show, eq]

(** The exclusion class: assistant rows written mid-turn by the surface-post
    tool carry neither turn_ref nor delivery provenance
    (keeper_tool_in_process_runtime.ml:1273,1340,1534). They are identifiable
    only by landing in the turn's ts window, and are never a mismatch. *)
val is_surface_post_row :
  first_ts:float -> last_ts:float -> Masc.Keeper_chat_store.chat_message -> bool

(** Pure: compare one operation's journaled events against the store rows
    already joined to that operation (delivery-key / turn_ref join performed
    by the caller via [transcript_of_messages]). *)
val compare :
     Masc.Keeper_chat_event_log.journaled_event list
  -> Masc.Keeper_chat_store.chat_message list
  -> verdict

(** IO shell: audit one operation. Reads the journal (handles missing /
    corrupt) and [load_all]s the store, joins, compares. *)
val audit_operation :
     base_dir:string
  -> keeper_name:string
  -> operation_id:string
  -> verdict

(** Sweep every journal file under <base>/.masc/keeper_chat_events/ seen in
    the last [window_sec] seconds (mtime), audit each, and return
    (keeper, operation_id, verdict) triples. Never raises: per-file failures
    become Journal_corrupt verdicts. *)
val sweep :
  base_dir:string -> window_sec:float -> unit -> (string * string * verdict) list
```

Comparison rules for `compare` (encode the skews explicitly):

```ocaml
(* compare core sketch — full case analysis, no wildcards *)

(* 1. seq contiguity: entries' seq must be exactly 0..n-1 in order. *)
let seq_ok entries =
  List.for_all2 (fun i (e : L.journaled_event) -> e.seq = i)
    (List.init (List.length entries) Fun.id) entries

(* 2. terminal outcome: last terminal event vs stream_lifecycle of the joined
   Terminal_assistant/Transport_failure row. *)
(* journal Run_finished  <-> row lifecycle ends Run_finished
   journal Event_error   <-> row kind = Transport_failure (lifecycle ends Run_error)
   no terminal event     -> Journal_truncated (checked before compare) *)

(* 3. assistant text: the row with delivery slot Terminal_assistant (or the
   single joined assistant row) must have content = Reply_details.reply,
   both sides post-redaction. control_turn_delivery skew: on
   Terminal_effect_settled the row content is the harness reply — which IS
   Reply_details.reply, so equality still holds; the surface-post answer row
   is excluded by is_surface_post_row. *)

(* 4. tool rows: bijection on execution_id between Tool_result_ready events
   and joined tool rows. *)

(* 5. no joined rows at all while terminal events exist -> Missing_terminal_row. *)
```

- [ ] **Step 1: Write the failing tests** (`test/test_keeper_chat_journal_audit.ml`)

Cover each verdict class with hand-built event lists and store rows (build `chat_message` values directly — the type's fields are all exposed in the `.mli`; reuse constructors from `test/test_keeper_chat_store.ml`):

- `match`: run_started → text deltas → tool_call → tool_result_ready(execution_id E) → reply_details(reply R, turn_ref T) → text_message_end → run_finished; store rows: user row (Accepted_user provenance), assistant row (turn_ref T, content R, lifecycle [Run_started;Text_message_start;Text_message_end;Run_finished], Terminal_assistant slot), tool row (execution_id E).
- `terminal_outcome_mismatch`: same journal but store row lifecycle ends `Run_error`.
- `assistant_text_mismatch`: store row content ≠ R.
- `tool_row_missing`: journal has Tool_result_ready E, no tool row.
- `seq_gap`: entries with seq [0;1;3].
- `truncated`: no terminal event → `Journal_truncated` regardless of rows.
- `surface_post_exclusion`: an extra assistant row with no turn_ref/provenance and ts inside the window does NOT turn Match into Mismatch.
- `audit_operation` IO: temp base dir, write a real journal file via `Keeper_chat_event_log` (scripted clock idiom from `test/test_keeper_chat_event_log.ml:203-218`), write store rows via `Keeper_chat_store` append functions, assert verdict; and missing journal file → `Journal_missing`.

- [ ] **Step 2: Run test to verify it fails** — FORBIDDEN locally. Static check: the test references `Masc.Keeper_chat_journal_audit` which does not exist yet; CI would fail. Proceed.

- [ ] **Step 3: Implement `keeper_chat_journal_audit.ml{,i}`**

Pure core first (`compare`, `is_surface_post_row`), then the IO shell. `sweep` walks `keeper_chat_events/<keeper>/*.jsonl` with `Sys.readdir`, filters by `Unix.stat` mtime within `window_sec`, calls `audit_operation` per file inside `try/with` (re-raise only `Eio.Cancel.Cancelled`). Journal filename → operation_id: the sanitized filename stem; note sanitization is lossy only for exotic ids, and TUI/dashboard ids (`tui-<uuidv7>`, `kmsg-<uuidv4>`) survive it unchanged — assert `journal_path` round-trips for such ids in a test.

- [ ] **Step 4: Wire the sweep into the maintenance fiber**

`lib/server/server_bootstrap_maintenance.ml`, next to the 24h prune (`:965-996`), add an hourly-gated pass (new `last_audit` ref, `3600.` interval — hourly, comfortably shorter than the 30-day retention):

```ocaml
(* RFC-0412 stage 2: dual-write consistency audit. Runs hourly — far more
   often than the 30d journal retention prune, so the audit window is never
   silently clipped. Mismatches are metrics + logs; nothing here raises. *)
if now -. !last_chat_journal_audit >= 3600. then begin
  last_chat_journal_audit := now;
  (try
     let results =
       Keeper_chat_journal_audit.sweep ~base_dir ~window_sec:(2. *. 3600.) ()
     in
     List.iter
       (fun (keeper, operation_id, verdict) ->
          match verdict with
          | Keeper_chat_journal_audit.Match -> ()
          | v ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string Chat_journal_audit_mismatches)
              ~labels:[ "keeper", keeper
                      ; "verdict", Keeper_chat_journal_audit.show_verdict v ]
              ();
            Log.Keeper.error
              "chat-journal-audit keeper=%s op=%s verdict=%s"
              keeper operation_id (Keeper_chat_journal_audit.show_verdict v))
       results
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn -> Log.Server.warn "chat journal audit sweep failed: %s" (Printexc.to_string exn))
end
```

(Add `Chat_journal_audit_mismatches` to `keeper_metrics.mli` next to `ChatStoreFailures`, `:132`. Check the `.ml`: with `ppx_enumerate` the list is derived; if there is a hand-written `to_string` match, add the arm. Grep `ChatStoreFailures` for every site that must change.)

Module spelling in `server_bootstrap_maintenance.ml`: `masc_server` is `(wrapped false)` but the keeper modules come from the wrapped `masc` library — check how this file already references keeper-side modules (e.g. `Schedule_service`, `Keeper_metrics`) and use the same spelling (`Masc.Keeper_chat_journal_audit` vs bare). Match the file, not this sketch.

`base_dir` availability in the maintenance fiber: check how the prune pass obtains `masc_root`/base at `:970-996` and use the same source.

- [ ] **Step 5: Verify** — static review; `ocamlformat --check` on touched files (repo `.ocamlformat` has `disable = true`, standalone binary is a no-op gate); CI dispatch.

- [ ] **Step 6: Commit**

```
fix(keeper): dual-write consistency auditor for the chat event journal

RFC-0412 stage 2 gate: before any read path serves from the journal,
prove it matches keeper_chat_store per turn — terminal outcome, assistant
text (Reply_details.reply vs Terminal_assistant row), tool-row bijection
on execution_id, seq contiguity. Surface-post mid-turn rows (no join
keys) are an explicit exclusion class; truncated journals (crashed turns)
are their own verdict. Hourly sweep from the maintenance fiber, metric +
error log per mismatch; the cutover task is gated on a clean soak.
```

---

## Task 2: seq on the SSE wire

Every projected SSE frame gets `id: <seq>` so clients can cursor. Clients that ignore `id:` are unaffected (SSE spec: unknown fields are ignored; the dashboard's `parseSseFrames` must be checked — see step 3).

**Files:**
- Modify: `lib/keeper/keeper_chat_events.ml` + `.mli` (`subscribe_with_seq`)
- Modify: `lib/server/server_routes_http_keeper_stream.ml` (adapter fiber :2655-2688; send path :1017-1018; live-sink event record :80-126)
- Test: `test/test_keeper_chat_events.ml` (extend; the file exists from earlier work — if not, create+register) and `test/test_keeper_chat_event_log.ml`

- [ ] **Step 1: failing test** — `subscribe_with_seq` returns `(seq, event)` pairs in publish order, seqs 0-based contiguous:

```ocaml
let test_subscribe_with_seq () =
  let t = Events.create () in
  Events.publish t (make_run_started ());  (* reuse existing test constructors *)
  Events.publish t (make_text_message_end ());
  let s0, _ = Events.subscribe_with_seq t in
  let s1, _ = Events.subscribe_with_seq t in
  Alcotest.(check int) "first seq" 0 s0;
  Alcotest.(check int) "second seq" 1 s1
```

- [ ] **Step 2: implement**

```ocaml
(* keeper_chat_events.ml, next to subscribe *)
let subscribe_with_seq t =
  let event = Eio.Stream.take t.stream in
  (* The seq is the arrival order on this single-publisher bus. Track a read
     cursor per bus: subscribe_with_seq is only called by the one adapter
     fiber, mirroring the single-consumer subscribe contract. *)
  let seq = !(t.read_seq) in
  t.read_seq := seq + 1;
  (seq, event)
```

Add `read_seq : int ref` to the record (`create` initializes `ref 0`), and to the `.mli`:

```ocaml
(** [subscribe_with_seq t] blocks until an event is available, then returns
    it with its 0-based publish-order sequence number. Same single-consumer
    contract as [subscribe] — the seq is the bus read cursor, valid because
    exactly one fiber drains the bus. *)
val subscribe_with_seq : t -> int * keeper_chat_event
```

NOTE for the implementer: verify against the actual record definition at `keeper_chat_events.ml:161-167` and keep `subscribe`/`take_nonblocking` semantics untouched (they must not advance the cursor in a way that breaks `subscribe_with_seq` — document that mixing them forfeits seq accuracy for skipped events; the adapter fiber uses only `subscribe_with_seq` after this task).

- [ ] **Step 3: thread seq to the wire**

In the adapter fiber (`server_routes_http_keeper_stream.ml:2655-2688`): switch `subscribe` → `subscribe_with_seq`, pass seq into `publish_operation_live_event` / the sink event record, and in `keeper_stream_send_event` call `Ag_ui.event_to_sse ~id:seq`. The broadcast path (`Keeper_chat_broadcast.operation_event`, `:2678-2681`) gains a `seq` field in its payload JSON — check `dashboard/src/sse.ts:535-542` tolerates extra fields (valibot `object()` is tolerant per the history schema precedent; verify the broadcast schema).

Read `dashboard/src/api/keeper.ts:493-563` `parseSseFrames`: confirm `id:` lines don't break parsing (standard SSE parsers store/ignore them). If it breaks, scope this task to the broadcast payload only and leave frames bare — do NOT ship a breaking frame change.

- [ ] **Step 4: tests + verify + commit**

Test at the frame level: `keeper_stream_send_event` path is HTTP-bound, so test the pure part — extend the golden replay test's machinery to assert `event_to_sse ~id:3 evt` contains `"id: 3\n"`. Then:

```
feat(keeper): every chat SSE frame carries its journal seq

event_to_sse gains ~id at the send path; the adapter fiber reads the bus
with subscribe_with_seq so the frame id IS the journal seq. Clients that
ignore SSE id: are unaffected; the dashboard broadcast payload carries
seq alongside. Foundation for since_seq replay (next task).
```

---

## Task 3: since_seq replay on the stream endpoint

A reconnecting client re-POSTs the same `operation_id` with `since_seq: N`; the server replays journaled events `seq > N` through the projection, then attaches the live sink — no lost deltas.

**Files:**
- Modify: `lib/server/server_routes_http_keeper_stream.ml` (`parse_keeper_chat_stream_request`, `handle_keeper_chat_stream` :2963-3099)
- Create: `lib/server/server_keeper_chat_replay.ml{,i}` (pure, testable replay)
- Test: `test/test_keeper_chat_replay.ml` (new, register in `test/dune`)

- [ ] **Step 1: failing test** for the pure replay core:

```ocaml
(* server_keeper_chat_replay.mli *)
(** Replay a journal through the AG-UI projection, emitting only the output
    of entries with seq > [since_seq]. The fold still starts at
    [Projection.initial] — projection state is cumulative, so earlier entries
    are folded and their output discarded. Byte-identical to the live stream
    suffix (golden-test guarantee) as long as [entry.ts] feeds [~timestamp]. *)
val replay_sse_frames :
     redact_text:(string -> string)
  -> redact_json:(Yojson.Safe.t -> Yojson.Safe.t)
  -> since_seq:int
  -> Masc.Keeper_chat_event_log.journaled_event list
  -> string list  (** ready-to-write SSE frames, id: set to seq *)
```

Test: journal the golden-test event list (reuse the 35-event fixture construction from `test/test_keeper_chat_event_log.ml`), replay with `since_seq=10`, assert the frames equal the live-fold frames 11..34 byte-for-byte, each prefixed `id: <seq>\n`.

- [ ] **Step 2: implement the pure core** (fold all, emit suffix; use `Ag_ui.event_to_sse ~id:entry.seq`).

- [ ] **Step 3: wire into the handler**

`parse_keeper_chat_stream_request` gains an optional `since_seq : int option` (JSON body field; absent = today). In `handle_keeper_chat_stream`, after acceptance (`:3026-3055`) and before waiting on `finished`:

```ocaml
(* Replay before live attach: read the journal (may be absent — a queued
   operation has none yet; may be corrupt — treat as no replay, the live
   sink still attaches). Events arriving during the read land in the
   existing [buffered] ref and flush after, same as the submit race. *)
(match since_seq with
 | None -> ()
 | Some n ->
   (match read_journal_safe ~base_path ~keeper_name ~operation_id with
    | None -> ()   (* missing/corrupt: live-only, same as today *)
    | Some entries ->
      List.iter send_raw_frame
        (Server_keeper_chat_replay.replay_sse_frames ~redact_text ~redact_json
           ~since_seq:n entries)))
```

Dedup guard: entries replayed must be excluded when the buffered/live sink later delivers the same seq — the sink path now knows seq (Task 2), so track `last_sent_seq` in the handler and drop live events with `seq <= last_sent_seq`.

- [ ] **Step 4: verify + commit**

```
feat(keeper): since_seq replay on the chat stream endpoint

A reconnecting client re-POSTs operation_id with since_seq and receives
the journaled suffix — replayed through the same pure projection, so
bytes equal the live stream (stage-1 golden guarantee) — then the live
sink attaches with seq-based dedup against the buffered race window.
Missing/corrupt journals degrade to today's live-only behavior.
```

---

## Task 4: v2 events endpoint

`GET /api/v1/keepers/:name/chat/events?operation_id=<id>&since_seq=<n>&limit=<n>` — the journal, raw, paged, reasoning included. This is the TUI's stage-3 source.

**Files:**
- Modify: `lib/server/server_dashboard_http_keeper_api.ml` (subroute, near :841-883)
- Modify: `lib/server/server_dashboard_http_keeper_api_types.ml:195-219` (permission gate)
- Test: `test/test_server_dashboard_http_keeper_chat_events.ml` (new, register)

Decisions (locked):
- **Permission**: reasoning full text leaves the process here. Gate like `/trajectory?include_thinking` does — `CanAdmin` (`server_dashboard_http_keeper_api_types.ml:196-197` precedent). The TUI's stage-3 switch will carry the same credentials it already uses for admin routes.
- **Payload**: raw journaled envelopes — reuse the stage-1 codec encoder so the response is exactly the journal lines, wrapped in an envelope:

```json
{ "schema": "masc.keeper_chat_events.v2",
  "operation_id": "tui-…",
  "events": [ {"v":1,"seq":0,"ts":…,"event":{…}} ],
  "has_more": false,
  "next_since_seq": 34 }
```

- `limit` default 500, max 2000; `since_seq` default -1 (from the start).
- Missing journal → 404 `{error: "unknown_operation"}`; corrupt → 503 `{error: "journal_corrupt"}` (fail-loud: this endpoint exists to serve the log, so the log's failure must surface — RFC §3.5 posture for v2 from day one).

- [ ] **Steps**: failing test (envelope shape, paging across limit, since_seq filter, 404, permission denial) → handler (read_journal + slice + encode; reuse `Keeper_chat_event_log`'s line encoder — if the encoder is internal, expose a `journaled_event_to_json` on the `.mli`) → register route → verify → commit:

```
feat(keeper): v2 chat events endpoint serves the journal, reasoning included

GET /api/v1/keepers/:name/chat/events paged over seq, CanAdmin-gated
(reasoning full text), missing journal 404 / corrupt 503 — the first
read path where journal failure is loud, per the RFC-0412 §3.5 flip
rule. The TUI switches to this in stage 3 so reasoning survives reload.
```

---

## Task 5: v1 history from the journal + fail-closed flip

**GATE: do not start until the Task-1 auditor has soaked clean** (RFC §3.5: zero unexplained mismatches over a multi-day window of real turns).

**Files:**
- Create: `lib/server/server_keeper_chat_history_v1_projection.ml{,i}` — journal → v1 row JSON
- Modify: `lib/server/server_dashboard_http_keeper_api.ml:575-601` (dispatch on a config flag)
- Modify: `lib/keeper/keeper_chat_event_log.ml` (fail-closed switch) + `keeper_chat_events.ml` publish hook policy
- Test: `test/test_keeper_chat_history_v1_projection.ml` (new) — byte-compat fixtures

Design:
- Row mapping from the auditor's table: assistant row from `Reply_details` (+ lifecycle from terminal events, turn_ref, blocks from the existing trace path — trace blocks keep their trajectory source in this task); tool rows from `Tool_result_ready`/`Tool_call_args_snapshot`; user rows keep coming from the store (the journal starts at run_started; user rows are out of journal scope in stage 2).
- **Flag-gated, dark-shipped**: `keeper_chat_history.source = "store"|"journal"` (registry knob precedent: `keeper_runtime_setting_registry.ml:226-234`), default `"store"`. The PR lands the projection + fixtures; the flip is an ops action after deploy.
- **Byte-compat test**: for each fixture turn in `test/test_keeper_chat_store.ml`'s pinned shapes, build the equivalent journal and assert the projected row JSON equals the store-derived row JSON for the mapped classes. Known structural difference to handle, not hide: the surface-post inversion — journal-projection order is the TRUE order (answer row after reasoning narration rows). v1 schema-wise both orders are legal (rows are ts-ordered client-side); pin the new mapping with its own fixtures and note the deliberate order fix in the commit message.
- **Fail-closed flip**: in the same PR, `Keeper_chat_event_log.append`'s failure policy gains a config-gated escalation: when `keeper_chat_events.fail_closed = true`, append failure raises `Keeper_chat_event_log.Journal_write_failed`, and `Keeper_chat_events.publish` lets it propagate (today it swallows — change the catch to re-raise `Journal_write_failed`), turning the turn into an error instead of a silently unrecorded one. Default stays `false` until the flag flips.

- [ ] **Steps**: failing byte-compat tests → projection module → flag wiring → fail-closed switch → verify (CI + dashboard contract smoke `scripts/harness_dashboard_keeper_chat_contract_smoke.sh`) → commit:

```
feat(keeper): v1 chat history can serve from the canonical journal

Dark-shipped behind keeper_chat_history.source=store|journal. Row
projection covers assistant (Reply_details + lifecycle), tool
(execution_id), and trace blocks (trajectory source unchanged); user
rows still come from the store. Surface-post ordering follows the
journal's true order — the settle-time inversion is fixed here, not
preserved. Adds keeper_chat_events.fail_closed: when set, a journal
append failure fails the turn instead of being swallowed (RFC-0412
§3.5). Flag flips only after the auditor soak.
```

---

## Task 6: reasoning trajectory replacement

With the journal holding full reasoning and v2 serving it, the withheld-thinking trajectory stops being the reasoning record.

**Files:**
- Modify: `lib/server/server_dashboard_http_keeper_api_trace.ml` (trace blocks: for turns with a journal, thinking steps come from journaled `Agent_core_thinking_delta`s joined via `Reply_details.turn_ref` → `(trace_id, absolute_turn)`; trajectory fallback stays for pre-journal turns)
- Modify: `lib/keeper/keeper_agent_run_thinking_trajectory.ml` + `lib/keeper/keeper_hooks_agent_core.ml:445-447` (stop writing once journal coverage is total — keep the writer until then)
- Test: `test/test_server_dashboard_http_keeper_api_trace.ml` (extend)

- [ ] **Steps**: failing test (journal-derived thinking steps render as `Trace_think` with real text for journaled turns; withheld markers for old turns) → implement join (operation_id → turn_ref → trace join) → wire → verify → commit:

```
feat(keeper): trace thinking steps come from the canonical journal

Turns covered by a journal render real thinking text in trace blocks
(joined operation_id → turn_ref → trajectory coordinates); pre-journal
turns keep withheld markers. The withheld-thinking writer stays until
journal coverage is total, then the after_turn hook stops calling it.
```

---

## Verification (stage-level, RFC §6)

- Task 5: v1 response byte regression on existing fixtures + dashboard contract smoke.
- Auditor soak gate before the Task-5 flag flip: zero unexplained mismatches over a multi-day window.
- All tasks: CI green (`dune build @check`); remember CI does not run tests — call that out in each PR body.
