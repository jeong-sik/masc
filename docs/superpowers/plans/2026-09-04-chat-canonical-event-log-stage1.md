# RFC-0412 Stage 1: Canonical Keeper Chat Event Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a versioned JSON codec, `seq`/`ts` attachment, and a fail-open per-operation JSONL journal for `Keeper_chat_events.keeper_chat_event`, dual-written alongside the existing `keeper_chat_store`, with a golden test proving journal replay through the AG-UI projection reproduces the live SSE byte stream.

**Architecture:** The journal hooks the single choke point every turn event passes through — `Keeper_chat_events.publish` — which gains an optional `on_publish` callback receiving a bus-assigned 0-based `seq`. A new module `Keeper_chat_event_log` (codec + journal writer/reader) stamps `ts` via an injectable clock and appends an envelope `{"v":1,"seq":N,"ts":F,"event":{...}}` per line to `<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl` using the existing `Fs_compat.append_private_jsonl_durable_locked_result` idiom (fsync + truncate-rollback). Journaling is synchronous and fail-open: any failure is logged via `Log.Keeper.error` and the live turn continues. Read paths, `keeper_chat_store` writes, and the 24-kind protocol-error type / 33-constructor event type are unchanged.

**Tech Stack:** OCaml 5 (single unqualified `masc` library via `lib/dune (include_subdirs unqualified)`), Eio (`Eio.Stream` bus, capacity 512), Yojson, Alcotest, Dune (CI-only; see verification constraints below).

---

## Verification constraints (constitution `<execution_protocol>`)

- **No local `dune build` / `dune runtest` is permitted.** Every task verifies by:
  1. Static review (read the diff; the grep checks listed in each task).
  2. ocamlformat overlap check in a temp dir (exact commands in each task).
  3. CI: `gh workflow run ci.yml --ref rfc/chat-canonical-log` (Task 6).
- TDD ordering still applies — tests are written before the implementation in
  each task — but "run the test" steps are phrased as *write the test, verify
  statically, CI validates*. The expected failure mode is stated so CI output
  can be checked against it.
- The repo-root `.ocamlformat` contains `disable = true` (RFC-0010). The
  overlap check therefore formats in `/tmp/rfc0412-fmt` whose `.ocamlformat`
  matches the repo config minus `disable`:

  ```bash
  mkdir -p /tmp/rfc0412-fmt
  printf 'version = 0.29.0\nprofile = janestreet\n' > /tmp/rfc0412-fmt/.ocamlformat
  ```

- Commits: lowercase conventional titles, long bodies, message via a `/tmp`
  file + `git commit -F` (macOS bash 3.2 breaks heredoc-inside-`$()`;
  heredoc-to-file is safe). Work happens in this worktree
  (`.worktrees/rfc/chat-canonical-log`, branch `rfc/chat-canonical-log`);
  never in the main checkout.

## Stage-1 non-goals (per RFC-0412 §4.1 and §5)

- No read-path changes: `/chat/history`, SSE, and all consumers are untouched.
- No changes to `keeper_chat_store` writes (the persist site at
  `lib/server/server_routes_http_keeper_stream.ml:2076-2083` stays as-is;
  the journal is an *additional* write — that is the dual-write).
- No reasoning persistence into `keeper_chat_store`, no retention, no
  `?since_seq=` replay endpoint, no v2 events endpoint (stage 2+).
- Redaction posture unchanged: the journal stores post-bridge text (the
  bridge applies `redact_text` at
  `lib/keeper/keeper_chat_agent_core_stream_bridge.ml:793,812`).

## File structure

**New files:**

- `lib/keeper/keeper_chat_event_log.ml` / `.mli` — versioned codec
  (`keeper_chat_event_to_json` / `keeper_chat_event_of_json`, envelope
  `journaled_event_to_json` / `journaled_event_of_json`) plus the journal
  (`journal_path`, `open_journal`, `append`, `read_journal`). Placement:
  sibling of `keeper_chat_events.ml`; `lib/dune` has
  `(include_subdirs unqualified)`, so no dune edit is needed. All
  dependencies (`Keeper_chat_events`, `Keeper_surface_post`,
  `Keeper_turn_outcome`, `Ids`, `Keeper_chat_blocks`, `Agent_core.Types`,
  `Fs_compat`, `Common`, `Workspace_utils_backend_setup`, `Time_compat`,
  `Log`) are modules of the same `masc` library.
- `test/test_keeper_chat_event_log.ml` — codec round-trip, journal,
  hook-ordering, bus↔journal integration, and the golden replay test.

**Modified files:**

- `lib/keeper/keeper_chat_blocks.mli` — expose the two existing label
  helpers `status_kind_to_label` / `status_kind_of_label` (Task 1).
- `lib/keeper/keeper_chat_events.ml` / `.mli` — abstract `type t` wrapping
  the `Eio.Stream`, optional `on_publish` hook, `next_seq` counter (Task 3).
- `lib/server/server_routes_http_keeper_stream.ml` — type annotation at
  `:1542` (Task 3); journal wiring at `:2613-2616` (Task 4).
- `lib/server/server_routes_http_keeper_stream.mli:255` — signature (Task 3).
- `lib/keeper/keeper_chat_slack.ml:527`, `lib/keeper/keeper_chat_slack.mli:76,159`,
  `lib/keeper/keeper_chat_discord.mli:42,107` — signature updates for the
  abstract bus type (Task 3).
- `test/dune` — register `test_keeper_chat_event_log` in the giant
  `(tests ...)` stanza (both the `(names ...)` list at ~line 232 and the
  `(modules ...)` list at ~line 578, after `test_keeper_chat_blocks`) (Task 1).

## Design decisions

1. **Envelope, not type surgery.** `seq`/`ts` live on
   `Keeper_chat_event_log.journaled_event = { seq : int; ts : float; event : keeper_chat_event }`.
   The 33-constructor `keeper_chat_event` type and the 24-kind
   `stream_protocol_error` type are not touched. Envelope JSON:
   `{"v":1,"seq":0,"ts":1762300000.0,"event":{"type":"text_delta","delta":"hi"}}`.
   `v` is checked on decode; unknown versions/tags are a decode `Error`
   (strict v1; additive evolution introduces new tags, breaking evolution
   bumps `v`).
2. **Choke point: `Keeper_chat_events.publish`.** Every producer (route
   lifecycle at `server_routes_http_keeper_stream.ml:1548-1551`, bridge-
   translated deltas and terminal paths at `:2435-2571`) funnels through
   `publish`. The alternative — journaling in the consumer — fails because
   consumption is per-channel (three adapter loops: Dashboard at `:2652`,
   Discord at `:2736`, Slack at `:2779`, plus `drain_events` at `:2625`), so
   it would triple the code and miss events on paths that drain without an
   adapter. `publish` captures 100% of events, including the five adapter-
   only block events (`Link_block | Image_block | Status_block | Audio_block
   | Tool_context_block`) that project to `None` at
   `lib/server/server_keeper_chat_agui_projection.ml:260-264`.
3. **`seq` is owned by the bus** (0-based, incremented per `publish`), so seq
   order == publish order == bus order. `ts` is stamped by the journal via an
   injectable `~now` clock (default `Time_compat.now`), which keeps
   `Keeper_chat_events` free of a clock dependency and makes the golden test
   deterministic.
4. **Ordering: journal before bus add.** The hook runs before
   `Eio.Stream.add`, so even when a full bus suspends the writer fiber
   waiting for a free slot (Eio backpressure — `add` blocks, it does not
   raise), the canonical log already holds the event.
5. **Backpressure.** The append is synchronous blocking Unix I/O inside
   `publish` (fsync + truncate-rollback via
   `Fs_compat.append_private_jsonl_durable_locked_result`,
   `lib/fs_compat/fs_compat.ml:3439`). On a local disk this is sub-ms to a
   few ms per line; provider delta rates (tens to low hundreds per second)
   are far below that, and the 512-slot bus absorbs bursts. The blocking I/O
   is offloaded via `Fs_compat.run_blocking_private_file_transaction`
   (`Eio_unix.run_in_systhread` when called from an Eio fiber), which
   suspends only the calling fiber; the seq-assign → append → add sequence
   needs no extra lock because every `publish` for a given bus runs in the
   single publisher fiber.
   Failure policy is fail-open at two layers: `Keeper_chat_event_log.append`
   matches every `private_file_transaction_outcome` arm and only logs;
   `Keeper_chat_events.publish` additionally catches any hook exception
   (re-raising `Eio.Cancel.Cancelled`). A journal failure must never break
   the live turn — during stage 1 `keeper_chat_store` remains the durable
   record of record.
6. **Codec shapes.** Journal payload field names are snake_case and mirror
   constructor labels. Exceptions, deliberate:
   - `Agent_core_stream_protocol_error` reuses the existing
     `Keeper_chat_events.stream_protocol_error_to_json` verbatim as its
     `"error"` payload (single source of truth for the wire shape); its
     nested occurrence is camelCase (`toolStreamScope`,
     `toolCallBlockIndex`, `providerMessageId`), so the codec carries a
     separate decode-side `occurrence_of_wire_json` for it. The
     journal-native occurrence codec used by `Tool_call_*` is snake_case.
   - `usage` payloads reuse `Keeper_chat_events.api_usage_to_json` /
     `delta_usage_to_json` for encode; the decoders ignore the derived
     `"total_tokens"` field (recomputed by `Agent_core.Types.total_tokens`).
   - `Agent_core_thinking_signature_delta.signature_bytes` is an `int` byte
     **count** (`lib/keeper/keeper_chat_events.ml:92`), not bytes — encoded
     as `` `Int ``, no base64 anywhere in this codec.
   - `Agent_core_media_delta.media_ref` is the reader-facing URL string
     (RFC-0301) — plain `` `String ``.
   - `stop_reason` round-trips via the total
     `Agent_core.Types.stop_reason_to_string` / `stop_reason_of_string`
     pair (decode cannot fail; unknown tokens decode to the raw-token
     variant). `source_type` via `media_source_kind_to_string` /
     `media_source_kind_of_string` (option-returning, decode can fail).
   - `External_effect_completed.target` via
     `Keeper_surface_post.delivery_target_to_yojson` / `_of_yojson`.
   - `Reply_details`: `turn_outcome` via `Keeper_turn_outcome.to_label` /
     `of_label` (option), `turn_ref` via `Ids.Turn_ref.to_string` /
     `of_string` (option).
   - `Tool_result_ready.execution_id` via `Ids.Execution_id.to_string` /
     `of_string` (total).
   - `Status_block.kind` via `Keeper_chat_blocks.status_kind_to_label` /
     `status_kind_of_label` (exposed in Task 1), keeping the same labels the
     chat store already persists (`"continuation_checkpoint"`,
     `"external_effect_pending"`).
7. **Filename sanitization.** Both `keeper_name` and `operation_id` pass
   through `Workspace_utils_backend_setup.sanitize_namespace_segment` (the
   `keeper_chat_store.ml:25-29` precedent). `operation_id` is ultimately
   client-supplied (`request_id`), so it is sanitized too; the sanitizer
   maps unsafe chars to `-` and appends a 16-hex digest, killing `/` and
   `..` traversal.
8. **Golden test time control.** The test journals with a scripted clock
   (`~now` popping scripted timestamps) and computes "live" bytes by folding
   the same in-memory events through
   `Server_keeper_chat_agui_projection.project ~timestamp:<scripted>`
   (mirroring the real call site at
   `server_routes_http_keeper_stream.ml:2655`, which injects
   `Time_compat.now ()`), then `Ag_ui.event_to_sse` (the exact serializer the
   live path uses via `keeper_stream_send_event` at
   `server_routes_http_keeper_stream.ml:1017-1018`). Replay folds the decoded
   journal with the journaled `ts`. Timestamps are exact binary fractions
   (`1762300000.0 + 0.25 * i`) so float→JSON→float round-trips byte-exactly;
   a per-line `ts` assertion catches any drift explicitly. No registry-init
   idiom is needed — no prompts are involved.

---

---

### Task 1: Versioned JSON codec for `keeper_chat_event`

**Files:**
- Create: `lib/keeper/keeper_chat_event_log.ml`
- Create: `lib/keeper/keeper_chat_event_log.mli`
- Modify: `lib/keeper/keeper_chat_blocks.mli` (expose two existing helpers; `.ml` unchanged — `status_kind_to_label` at `keeper_chat_blocks.ml:294-297`, `status_kind_of_label` at `:299-303`)
- Test: `test/test_keeper_chat_event_log.ml`
- Modify: `test/dune` (register the test)

- [ ] **Step 1: Write the failing codec round-trip test**

Create `test/test_keeper_chat_event_log.ml`:

```ocaml
(* RFC-0412 stage 1 — canonical keeper chat event log: codec, journal, and
   golden replay tests. *)

module E = Masc.Keeper_chat_events
module L = Masc.Keeper_chat_event_log
module Blocks = Masc.Keeper_chat_blocks
module Surface = Masc.Keeper_surface_post
module Outcome = Masc.Keeper_turn_outcome
module Projection = Masc.Server_keeper_chat_agui_projection

let occurrence : E.tool_stream_occurrence =
  { stream_scope = 7; provider_message_id = Some "pm-1"; block_index = 2 }

let occurrence_anon : E.tool_stream_occurrence =
  { stream_scope = 0; provider_message_id = None; block_index = 0 }

let usage_full : Agent_core.Types.api_usage =
  { input_tokens = 10
  ; output_tokens = 4
  ; cache_creation_input_tokens = 1
  ; cache_read_input_tokens = 2
  ; cost_usd = Some 0.001
  }

let delta_usage_partial : Agent_core.Types.delta_usage =
  { input_tokens = Some 10
  ; output_tokens = None
  ; cache_creation_input_tokens = Some 1
  ; cache_read_input_tokens = None
  }

let protocol_error_full : E.stream_protocol_error =
  { kind = E.Tool_args_without_start
  ; quarantined_occurrence = Some occurrence
  ; index = Some 2
  ; tool_call_id = Some "tc-1"
  ; event_type = Some "content_block_delta"
  ; reason = Some "args before start"
  ; raw_bytes = Some 128
  }

let protocol_error_sparse : E.stream_protocol_error =
  { kind = E.Sse_stream_repeating
  ; quarantined_occurrence = None
  ; index = None
  ; tool_call_id = None
  ; event_type = None
  ; reason = None
  ; raw_bytes = None
  }

(* One instance per [keeper_chat_event] constructor (33 total), covering both
   population variants of every option field. *)
let all_events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-1"; thread_id = "thread-1" }
  ; E.Text_message_start { message_id = "msg-1"; role = E.User }
  ; E.Text_message_start { message_id = "msg-2"; role = E.Assistant }
  ; E.Text_delta "hello"
  ; E.Text_message_end
  ; E.External_effect_completed
      { target =
          Surface.Delivered_to_slack { channel_id = "C123"; thread_ts = Some "1700.5" }
      }
  ; E.External_effect_completed { target = Surface.Delivered_to_dashboard }
  ; E.Run_finished { run_id = "run-1" }
  ; E.Event_error { message = "boom" }
  ; E.Reply_details
      { reply = "done"
      ; turn_outcome = Outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:3
      }
  ; E.Continuation_checkpoint { message = "paused"; request_id = Some "req-9" }
  ; E.Continuation_checkpoint { message = "paused"; request_id = None }
  ; E.Agent_core_stream_connected
  ; E.Agent_core_runtime_attempt_started
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-1"; model = "kimi-for-coding"; usage = Some usage_full }
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-2"; model = "m"; usage = None }
  ; E.Agent_core_stream_message_delta
      { stop_reason = Some Agent_core.Types.EndTurn
      ; usage = Some delta_usage_partial
      }
  ; E.Agent_core_stream_message_delta { stop_reason = None; usage = None }
  ; E.Agent_core_stream_message_stop
  ; E.Agent_core_stream_ping
  ; E.Agent_core_content_block_start
      { index = 0
      ; content_type = "tool_use"
      ; tool_call_id = Some "tc-1"
      ; tool_call_name = Some "read_file"
      }
  ; E.Agent_core_content_block_start
      { index = 1; content_type = "text"; tool_call_id = None; tool_call_name = None }
  ; E.Agent_core_content_block_stop { index = 0 }
  ; E.Agent_core_thinking_delta { index = 3; delta = "pondering" }
  ; E.Agent_core_thinking_signature_delta { index = 3; signature_bytes = 42 }
  ; E.Agent_core_media_delta
      { index = 4
      ; media_type = "image/png"
      ; source_type = Agent_core.Types.Base64
      ; media_ref = "/api/v1/media/tok-1"
      }
  ; E.Agent_core_stream_protocol_error protocol_error_full
  ; E.Agent_core_stream_protocol_error protocol_error_sparse
  ; E.Tool_call_start
      { occurrence; tool_call_id = Some "tc-1"; tool_call_name = "read_file" }
  ; E.Tool_call_args
      { occurrence = occurrence_anon; tool_call_id = None; delta = "{\"path\":" }
  ; E.Tool_call_args_snapshot
      { occurrence; tool_call_id = None; snapshot = "{\"path\":\"/tmp\"}" }
  ; E.Tool_call_end { occurrence; tool_call_id = Some "tc-1" }
  ; E.Tool_approval_requested
      { tool_call_id = "tc-2"
      ; tool_call_name = "bash"
      ; args = "{\"cmd\":\"ls\"}"
      ; question = "allow?"
      ; because = "policy"
      }
  ; E.Tool_approval_settled { tool_call_id = "tc-2"; outcome = "approved" }
  ; E.Tool_result_ready
      { occurrence
      ; tool_call_id = Some "tc-1"
      ; execution_id = Ids.Execution_id.of_string "exec-1"
      }
  ; E.Link_block
      { url = "https://example.com"
      ; title = "Example"
      ; description = Some "desc"
      ; image = None
      }
  ; E.Image_block { url = "https://example.com/i.png"; caption = Some "cap" }
  ; E.Image_block { url = "https://example.com/j.png"; caption = None }
  ; E.Status_block { kind = Blocks.Continuation_checkpoint }
  ; E.Status_block { kind = Blocks.Awaiting_gate_approval }
  ; E.Audio_block
      { token = "aud-1"
      ; mime = "audio/ogg"
      ; message_text = "hi"
      ; duration_sec = Some 1.5
      }
  ; E.Audio_block { token = "aud-2"; mime = "audio/mp3"; message_text = "yo"; duration_sec = None }
  ; E.Tool_context_block
      { tool_call_id = "tc-3"
      ; name = "grep"
      ; args_summary = "pat x"
      ; result_summary = Some "3 hits"
      }
  ]

(* [keeper_chat_event] has no [equal]; JSON-level round-trip is the equality
   oracle: decode(encode(e)) re-encoded must be byte-identical to encode(e). *)
let test_codec_round_trip_all_constructors () =
  List.iteri
    (fun i event ->
       let encoded = L.keeper_chat_event_to_json event in
       match L.keeper_chat_event_of_json encoded with
       | Error detail ->
         Alcotest.failf "constructor %d failed to decode: %s\njson: %s"
           i detail (Yojson.Safe.to_string encoded)
       | Ok decoded ->
         Alcotest.(check string)
           (Printf.sprintf "constructor %d round-trips" i)
           (Yojson.Safe.to_string encoded)
           (Yojson.Safe.to_string (L.keeper_chat_event_to_json decoded)))
    all_events

let test_envelope_round_trip () =
  let entry : L.journaled_event =
    { seq = 3; ts = 1_762_300_000.25; event = E.Text_delta "hi" }
  in
  let encoded = L.journaled_event_to_json entry in
  match L.journaled_event_of_json encoded with
  | Error detail -> Alcotest.failf "envelope decode failed: %s" detail
  | Ok decoded ->
    Alcotest.(check int) "seq" 3 decoded.seq;
    Alcotest.(check (float 0.0)) "ts" 1_762_300_000.25 decoded.ts;
    Alcotest.(check string)
      "event"
      (Yojson.Safe.to_string (L.keeper_chat_event_to_json entry.event))
      (Yojson.Safe.to_string (L.keeper_chat_event_to_json decoded.event))

let test_envelope_rejects_unknown_version () =
  let json =
    `Assoc
      [ "v", `Int 99
      ; "seq", `Int 0
      ; "ts", `Float 1.0
      ; "event", `Assoc [ "type", `String "text_delta"; "delta", `String "x" ]
      ]
  in
  match L.journaled_event_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown codec version must be rejected"

let test_codec_rejects_unknown_tag () =
  match L.keeper_chat_event_of_json (`Assoc [ "type", `String "nope" ]) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown event tag must be rejected"

let () =
  Alcotest.run
    "keeper_chat_event_log"
    [ ( "codec"
      , [ Alcotest.test_case
            "round trip all constructors"
            `Quick
            test_codec_round_trip_all_constructors
        ; Alcotest.test_case "envelope round trip" `Quick test_envelope_round_trip
        ; Alcotest.test_case
            "envelope rejects unknown version"
            `Quick
            test_envelope_rejects_unknown_version
        ; Alcotest.test_case
            "codec rejects unknown tag"
            `Quick
            test_codec_rejects_unknown_tag
        ] )
    ]
```

Register the test in `test/dune`: in the giant `(tests ...)` stanza (starts at
`test/dune:82`), add `test_keeper_chat_event_log` immediately after
`test_keeper_chat_blocks` in **both** the `(names ...)` list (~line 232) and
the `(modules ...)` list (~line 578). The stanza's libraries
(`masc_test_deps ...` at `test/dune:775-781`) already re-export `alcotest`,
`masc`, `masc.ag_ui`, `masc.agent_core`, `yojson`, `unix`.

- [ ] **Step 2: Verify the test fails (statically)**

Expected failure mode if compiled now: `Unbound module Masc.Keeper_chat_event_log`.
Confirm by inspection that no such module exists:

```bash
ls lib/keeper/keeper_chat_event_log.ml 2>&1 || echo "module does not exist yet — test would fail to compile"
```

CI is the executor; no local build.

- [ ] **Step 3: Expose the status-kind label helpers**

In `lib/keeper/keeper_chat_blocks.mli`, after the `status_kind_connector_text`
declaration (currently at `:109`), add:

```ocaml
val status_kind_to_label : status_kind -> string
val status_kind_of_label : string -> status_kind option
(** Stable persistence labels shared by the chat store and the RFC-0412
    canonical event journal. *)
```

- [ ] **Step 4: Implement the codec**

Create `lib/keeper/keeper_chat_event_log.ml`:

```ocaml
(** Versioned JSON codec and per-operation JSONL journal for
    [Keeper_chat_events.keeper_chat_event] (RFC-0412 §4.1).

    Stage 1 is dual-write only: read paths are unchanged, and the journal is
    fail-open — a journal failure must never break the live turn. *)

open Keeper_chat_events

let codec_version = 1

let json_opt key value =
  match value with
  | None -> []
  | Some value -> [ key, value ]
;;

let type_tag tag fields = `Assoc (("type", `String tag) :: fields)

let role_to_json = function
  | User -> `String "user"
  | Assistant -> `String "assistant"
;;

let role_of_json json =
  match json with
  | `String "user" -> Ok User
  | `String "assistant" -> Ok Assistant
  | other ->
    Error
      (Printf.sprintf
         "role: expected \"user\"|\"assistant\", got %s"
         (Yojson.Safe.to_string other))
;;

(* Journal-native occurrence shape (snake_case). Used by the Tool_call_*
   family. *)
let occurrence_to_json (o : tool_stream_occurrence) =
  `Assoc
    ([ "stream_scope", `Int o.stream_scope
     ; "block_index", `Int o.block_index
     ]
     @ json_opt "provider_message_id"
         (Option.map (fun value -> `String value) o.provider_message_id))
;;

let occurrence_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { stream_scope = json |> member "stream_scope" |> to_int
      ; provider_message_id = json |> member "provider_message_id" |> to_string_option
      ; block_index = json |> member "block_index" |> to_int
      }
  with
  | Type_error (message, _) -> Error ("tool_stream_occurrence: " ^ message)
;;

(* Decode-side companion for the occurrence nested inside
   [stream_protocol_error_to_json], whose shape is the AG-UI wire shape
   (camelCase) — the encoder is reused verbatim, so this decoder must match
   it. *)
let occurrence_of_wire_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { stream_scope = json |> member "toolStreamScope" |> to_int
      ; provider_message_id = json |> member "providerMessageId" |> to_string_option
      ; block_index = json |> member "toolCallBlockIndex" |> to_int
      }
  with
  | Type_error (message, _) -> Error ("tool_stream_occurrence(wire): " ^ message)
;;

(* [api_usage_to_json] writes a derived [total_tokens]; decoding recomputes it
   via [Agent_core.Types.total_tokens], so it is intentionally not read back. *)
let api_usage_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { Agent_core.Types.input_tokens = json |> member "input_tokens" |> to_int
      ; output_tokens = json |> member "output_tokens" |> to_int
      ; cache_creation_input_tokens =
          json |> member "cache_creation_input_tokens" |> to_int
      ; cache_read_input_tokens = json |> member "cache_read_input_tokens" |> to_int
      ; cost_usd = json |> member "cost_usd" |> to_float_option
      }
  with
  | Type_error (message, _) -> Error ("api_usage: " ^ message)
;;

let delta_usage_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { Agent_core.Types.input_tokens = json |> member "input_tokens" |> to_int_option
      ; output_tokens = json |> member "output_tokens" |> to_int_option
      ; cache_creation_input_tokens =
          json |> member "cache_creation_input_tokens" |> to_int_option
      ; cache_read_input_tokens =
          json |> member "cache_read_input_tokens" |> to_int_option
      }
  with
  | Type_error (message, _) -> Error ("delta_usage: " ^ message)
;;

let opt_member json key decode =
  match Yojson.Safe.Util.member key json with
  | `Null -> Ok None
  | value -> Result.map (fun decoded -> Some decoded) (decode value)
;;

let stream_protocol_error_of_json json =
  let open Yojson.Safe.Util in
  try
    let kind_raw = json |> member "kind" |> to_string in
    match stream_protocol_error_kind_of_string kind_raw with
    | None ->
      Error (Printf.sprintf "stream_protocol_error: unknown kind %S" kind_raw)
    | Some kind ->
      let quarantined_occurrence =
        match json |> member "quarantined_occurrence" with
        | `Null -> Ok None
        | occurrence_json ->
          Result.map
            (fun occurrence -> Some occurrence)
            (occurrence_of_wire_json occurrence_json)
      in
      Result.map
        (fun quarantined_occurrence ->
           { kind
           ; quarantined_occurrence
           ; index = json |> member "index" |> to_int_option
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; event_type = json |> member "event_type" |> to_string_option
           ; reason = json |> member "reason" |> to_string_option
           ; raw_bytes = json |> member "raw_bytes" |> to_int_option
           })
        quarantined_occurrence
  with
  | Type_error (message, _) -> Error ("stream_protocol_error: " ^ message)
;;

let keeper_chat_event_to_json event =
  match event with
  | Run_started { run_id; thread_id } ->
    type_tag "run_started" [ "run_id", `String run_id; "thread_id", `String thread_id ]
  | Text_message_start { message_id; role } ->
    type_tag
      "text_message_start"
      [ "message_id", `String message_id; "role", role_to_json role ]
  | Text_delta delta -> type_tag "text_delta" [ "delta", `String delta ]
  | Text_message_end -> type_tag "text_message_end" []
  | External_effect_completed { target } ->
    type_tag
      "external_effect_completed"
      [ "target", Keeper_surface_post.delivery_target_to_yojson target ]
  | Run_finished { run_id } -> type_tag "run_finished" [ "run_id", `String run_id ]
  | Event_error { message } -> type_tag "event_error" [ "message", `String message ]
  | Reply_details { reply; turn_outcome; turn_ref } ->
    type_tag
      "reply_details"
      [ "reply", `String reply
      ; "turn_outcome", `String (Keeper_turn_outcome.to_label turn_outcome)
      ; "turn_ref", `String (Ids.Turn_ref.to_string turn_ref)
      ]
  | Continuation_checkpoint { message; request_id } ->
    type_tag
      "continuation_checkpoint"
      ([ "message", `String message ]
       @ json_opt "request_id" (Option.map (fun value -> `String value) request_id))
  | Agent_core_stream_connected -> type_tag "agent_core_stream_connected" []
  | Agent_core_runtime_attempt_started ->
    type_tag "agent_core_runtime_attempt_started" []
  | Agent_core_stream_message_start { provider_message_id; model; usage } ->
    type_tag
      "agent_core_stream_message_start"
      ([ "provider_message_id", `String provider_message_id; "model", `String model ]
       @ json_opt "usage" (Option.map api_usage_to_json usage))
  | Agent_core_stream_message_delta { stop_reason; usage } ->
    type_tag
      "agent_core_stream_message_delta"
      (json_opt
         "stop_reason"
         (Option.map
            (fun reason -> `String (Agent_core.Types.stop_reason_to_string reason))
            stop_reason)
       @ json_opt "usage" (Option.map delta_usage_to_json usage))
  | Agent_core_stream_message_stop -> type_tag "agent_core_stream_message_stop" []
  | Agent_core_stream_ping -> type_tag "agent_core_stream_ping" []
  | Agent_core_content_block_start { index; content_type; tool_call_id; tool_call_name }
    ->
    type_tag
      "agent_core_content_block_start"
      ([ "index", `Int index; "content_type", `String content_type ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id)
       @ json_opt
           "tool_call_name"
           (Option.map (fun value -> `String value) tool_call_name))
  | Agent_core_content_block_stop { index } ->
    type_tag "agent_core_content_block_stop" [ "index", `Int index ]
  | Agent_core_thinking_delta { index; delta } ->
    type_tag "agent_core_thinking_delta" [ "index", `Int index; "delta", `String delta ]
  | Agent_core_thinking_signature_delta { index; signature_bytes } ->
    (* [signature_bytes] is a byte COUNT (int), not payload bytes. *)
    type_tag
      "agent_core_thinking_signature_delta"
      [ "index", `Int index; "signature_bytes", `Int signature_bytes ]
  | Agent_core_media_delta { index; media_type; source_type; media_ref } ->
    type_tag
      "agent_core_media_delta"
      [ "index", `Int index
      ; "media_type", `String media_type
      ; "source_type", `String (Agent_core.Types.media_source_kind_to_string source_type)
      ; "media_ref", `String media_ref
      ]
  | Agent_core_stream_protocol_error error ->
    type_tag
      "agent_core_stream_protocol_error"
      [ "error", stream_protocol_error_to_json error ]
  | Tool_call_start { occurrence; tool_call_id; tool_call_name } ->
    type_tag
      "tool_call_start"
      ([ "occurrence", occurrence_to_json occurrence
       ; "tool_call_name", `String tool_call_name
       ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_call_args { occurrence; tool_call_id; delta } ->
    type_tag
      "tool_call_args"
      ([ "occurrence", occurrence_to_json occurrence; "delta", `String delta ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_call_args_snapshot { occurrence; tool_call_id; snapshot } ->
    type_tag
      "tool_call_args_snapshot"
      ([ "occurrence", occurrence_to_json occurrence; "snapshot", `String snapshot ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_call_end { occurrence; tool_call_id } ->
    type_tag
      "tool_call_end"
      ([ "occurrence", occurrence_to_json occurrence ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_approval_requested { tool_call_id; tool_call_name; args; question; because } ->
    type_tag
      "tool_approval_requested"
      [ "tool_call_id", `String tool_call_id
      ; "tool_call_name", `String tool_call_name
      ; "args", `String args
      ; "question", `String question
      ; "because", `String because
      ]
  | Tool_approval_settled { tool_call_id; outcome } ->
    type_tag
      "tool_approval_settled"
      [ "tool_call_id", `String tool_call_id; "outcome", `String outcome ]
  | Tool_result_ready { occurrence; tool_call_id; execution_id } ->
    type_tag
      "tool_result_ready"
      ([ "occurrence", occurrence_to_json occurrence
       ; "execution_id", `String (Ids.Execution_id.to_string execution_id)
       ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Link_block { url; title; description; image } ->
    type_tag
      "link_block"
      ([ "url", `String url; "title", `String title ]
       @ json_opt "description" (Option.map (fun value -> `String value) description)
       @ json_opt "image" (Option.map (fun value -> `String value) image))
  | Image_block { url; caption } ->
    type_tag
      "image_block"
      ([ "url", `String url ]
       @ json_opt "caption" (Option.map (fun value -> `String value) caption))
  | Status_block { kind } ->
    type_tag
      "status_block"
      [ "kind", `String (Keeper_chat_blocks.status_kind_to_label kind) ]
  | Audio_block { token; mime; message_text; duration_sec } ->
    type_tag
      "audio_block"
      ([ "token", `String token
       ; "mime", `String mime
       ; "message_text", `String message_text
       ]
       @ json_opt "duration_sec" (Option.map (fun value -> `Float value) duration_sec))
  | Tool_context_block { tool_call_id; name; args_summary; result_summary } ->
    type_tag
      "tool_context_block"
      ([ "tool_call_id", `String tool_call_id
       ; "name", `String name
       ; "args_summary", `String args_summary
       ]
       @ json_opt
           "result_summary"
           (Option.map (fun value -> `String value) result_summary))
;;

let keeper_chat_event_of_json json =
  let open Yojson.Safe.Util in
  let ( let* ) = Result.bind in
  try
    let tag = json |> member "type" |> to_string in
    match tag with
    | "run_started" ->
      Ok
        (Run_started
           { run_id = json |> member "run_id" |> to_string
           ; thread_id = json |> member "thread_id" |> to_string
           })
    | "text_message_start" ->
      let* role = role_of_json (json |> member "role") in
      Ok
        (Text_message_start
           { message_id = json |> member "message_id" |> to_string; role })
    | "text_delta" -> Ok (Text_delta (json |> member "delta" |> to_string))
    | "text_message_end" -> Ok Text_message_end
    | "external_effect_completed" ->
      let* target =
        Keeper_surface_post.delivery_target_of_yojson (json |> member "target")
      in
      Ok (External_effect_completed { target })
    | "run_finished" ->
      Ok (Run_finished { run_id = json |> member "run_id" |> to_string })
    | "event_error" ->
      Ok (Event_error { message = json |> member "message" |> to_string })
    | "reply_details" ->
      let outcome_label = json |> member "turn_outcome" |> to_string in
      let* turn_outcome =
        match Keeper_turn_outcome.of_label outcome_label with
        | Some outcome -> Ok outcome
        | None ->
          Error (Printf.sprintf "reply_details: unknown turn_outcome %S" outcome_label)
      in
      let turn_ref_raw = json |> member "turn_ref" |> to_string in
      let* turn_ref =
        match Ids.Turn_ref.of_string turn_ref_raw with
        | Some turn_ref -> Ok turn_ref
        | None ->
          Error (Printf.sprintf "reply_details: malformed turn_ref %S" turn_ref_raw)
      in
      Ok
        (Reply_details
           { reply = json |> member "reply" |> to_string; turn_outcome; turn_ref })
    | "continuation_checkpoint" ->
      Ok
        (Continuation_checkpoint
           { message = json |> member "message" |> to_string
           ; request_id = json |> member "request_id" |> to_string_option
           })
    | "agent_core_stream_connected" -> Ok Agent_core_stream_connected
    | "agent_core_runtime_attempt_started" -> Ok Agent_core_runtime_attempt_started
    | "agent_core_stream_message_start" ->
      let* usage = opt_member json "usage" api_usage_of_json in
      Ok
        (Agent_core_stream_message_start
           { provider_message_id = json |> member "provider_message_id" |> to_string
           ; model = json |> member "model" |> to_string
           ; usage
           })
    | "agent_core_stream_message_delta" ->
      let stop_reason_raw = json |> member "stop_reason" |> to_string_option in
      let* usage = opt_member json "usage" delta_usage_of_json in
      Ok
        (Agent_core_stream_message_delta
           { stop_reason =
               Option.map Agent_core.Types.stop_reason_of_string stop_reason_raw
           ; usage
           })
    | "agent_core_stream_message_stop" -> Ok Agent_core_stream_message_stop
    | "agent_core_stream_ping" -> Ok Agent_core_stream_ping
    | "agent_core_content_block_start" ->
      Ok
        (Agent_core_content_block_start
           { index = json |> member "index" |> to_int
           ; content_type = json |> member "content_type" |> to_string
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; tool_call_name = json |> member "tool_call_name" |> to_string_option
           })
    | "agent_core_content_block_stop" ->
      Ok (Agent_core_content_block_stop { index = json |> member "index" |> to_int })
    | "agent_core_thinking_delta" ->
      Ok
        (Agent_core_thinking_delta
           { index = json |> member "index" |> to_int
           ; delta = json |> member "delta" |> to_string
           })
    | "agent_core_thinking_signature_delta" ->
      Ok
        (Agent_core_thinking_signature_delta
           { index = json |> member "index" |> to_int
           ; signature_bytes = json |> member "signature_bytes" |> to_int
           })
    | "agent_core_media_delta" ->
      let source_raw = json |> member "source_type" |> to_string in
      let* source_type =
        match Agent_core.Types.media_source_kind_of_string source_raw with
        | Some kind -> Ok kind
        | None ->
          Error
            (Printf.sprintf "agent_core_media_delta: unknown source_type %S" source_raw)
      in
      Ok
        (Agent_core_media_delta
           { index = json |> member "index" |> to_int
           ; media_type = json |> member "media_type" |> to_string
           ; source_type
           ; media_ref = json |> member "media_ref" |> to_string
           })
    | "agent_core_stream_protocol_error" ->
      let* error = stream_protocol_error_of_json (json |> member "error") in
      Ok (Agent_core_stream_protocol_error error)
    | "tool_call_start" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_start
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; tool_call_name = json |> member "tool_call_name" |> to_string
           })
    | "tool_call_args" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_args
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; delta = json |> member "delta" |> to_string
           })
    | "tool_call_args_snapshot" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_args_snapshot
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; snapshot = json |> member "snapshot" |> to_string
           })
    | "tool_call_end" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_end
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           })
    | "tool_approval_requested" ->
      Ok
        (Tool_approval_requested
           { tool_call_id = json |> member "tool_call_id" |> to_string
           ; tool_call_name = json |> member "tool_call_name" |> to_string
           ; args = json |> member "args" |> to_string
           ; question = json |> member "question" |> to_string
           ; because = json |> member "because" |> to_string
           })
    | "tool_approval_settled" ->
      Ok
        (Tool_approval_settled
           { tool_call_id = json |> member "tool_call_id" |> to_string
           ; outcome = json |> member "outcome" |> to_string
           })
    | "tool_result_ready" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_result_ready
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; execution_id =
               Ids.Execution_id.of_string (json |> member "execution_id" |> to_string)
           })
    | "link_block" ->
      Ok
        (Link_block
           { url = json |> member "url" |> to_string
           ; title = json |> member "title" |> to_string
           ; description = json |> member "description" |> to_string_option
           ; image = json |> member "image" |> to_string_option
           })
    | "image_block" ->
      Ok
        (Image_block
           { url = json |> member "url" |> to_string
           ; caption = json |> member "caption" |> to_string_option
           })
    | "status_block" ->
      let kind_raw = json |> member "kind" |> to_string in
      let* kind =
        match Keeper_chat_blocks.status_kind_of_label kind_raw with
        | Some kind -> Ok kind
        | None ->
          Error (Printf.sprintf "status_block: unknown kind %S" kind_raw)
      in
      Ok (Status_block { kind })
    | "audio_block" ->
      Ok
        (Audio_block
           { token = json |> member "token" |> to_string
           ; mime = json |> member "mime" |> to_string
           ; message_text = json |> member "message_text" |> to_string
           ; duration_sec = json |> member "duration_sec" |> to_float_option
           })
    | "tool_context_block" ->
      Ok
        (Tool_context_block
           { tool_call_id = json |> member "tool_call_id" |> to_string
           ; name = json |> member "name" |> to_string
           ; args_summary = json |> member "args_summary" |> to_string
           ; result_summary = json |> member "result_summary" |> to_string_option
           })
    | unknown ->
      Error (Printf.sprintf "keeper_chat_event: unknown type %S" unknown)
  with
  | Type_error (message, _) -> Error ("keeper_chat_event: " ^ message)
;;

type journaled_event =
  { seq : int
  ; ts : float
  ; event : keeper_chat_event
  }

let journaled_event_to_json { seq; ts; event } =
  `Assoc
    [ "v", `Int codec_version
    ; "seq", `Int seq
    ; "ts", `Float ts
    ; "event", keeper_chat_event_to_json event
    ]
;;

let journaled_event_of_json json =
  let open Yojson.Safe.Util in
  try
    let version = json |> member "v" |> to_int in
    if version <> codec_version
    then
      Error
        (Printf.sprintf
           "journaled_event: unsupported version %d (codec v%d)"
           version
           codec_version)
    else
      Result.map
        (fun event ->
           { seq = json |> member "seq" |> to_int
           ; ts = json |> member "ts" |> to_float
           ; event
           })
        (keeper_chat_event_of_json (json |> member "event"))
  with
  | Type_error (message, _) -> Error ("journaled_event: " ^ message)
;;
```

Create `lib/keeper/keeper_chat_event_log.mli`:

```ocaml
(** Versioned JSON codec and per-operation JSONL journal for
    [Keeper_chat_events.keeper_chat_event] (RFC-0412 §4.1, stage 1:
    dual-write only; read paths unchanged). *)

(** One journaled event: the bus-assigned sequence number, the publish-time
    timestamp (Unix epoch seconds), and the event itself. *)
type journaled_event =
  { seq : int  (** 0-based, monotonically increasing within one operation. *)
  ; ts : float
  ; event : Keeper_chat_events.keeper_chat_event
  }

val codec_version : int
(** Current envelope version. Written as ["v"]; decode rejects any other. *)

val keeper_chat_event_to_json : Keeper_chat_events.keeper_chat_event -> Yojson.Safe.t
(** Tagged-object encoding: [{"type": <snake_case tag>, ...payload}]. *)

val keeper_chat_event_of_json :
  Yojson.Safe.t -> (Keeper_chat_events.keeper_chat_event, string) result
(** Strict inverse of {!keeper_chat_event_to_json}. Unknown tags are an
    [Error]. *)

val journaled_event_to_json : journaled_event -> Yojson.Safe.t
val journaled_event_of_json : Yojson.Safe.t -> (journaled_event, string) result
```

- [ ] **Step 5: Verify statically + ocamlformat overlap check**

```bash
# Codec coverage: the event type has 33 constructors; the decoder must have
# 33 tag arms (plus the unknown-tag fallback). Eyeball the tags side by side
# with the type at lib/keeper/keeper_chat_events.ml:60-158.
sed -n '60,158p' lib/keeper/keeper_chat_events.ml | grep -c '^  | [A-Z]'   # expect 33
grep -c '^    | "' lib/keeper/keeper_chat_event_log.ml                     # expect 33

# ocamlformat overlap check (temp dir .ocamlformat set up per the header)
for f in lib/keeper/keeper_chat_event_log.ml lib/keeper/keeper_chat_event_log.mli \
         test/test_keeper_chat_event_log.ml lib/keeper/keeper_chat_blocks.mli \
         test/dune; do
  case "$f" in
    *.ml|*.mli)
      cp "$f" /tmp/rfc0412-fmt/
      ocamlformat "/tmp/rfc0412-fmt/$(basename "$f")" > "/tmp/rfc0412-fmt/$(basename "$f").fmt" \
        && git diff --no-index -U0 "$f" "/tmp/rfc0412-fmt/$(basename "$f").fmt" || true
      ;;
  esac
done
```

Expected: ocamlformat parses all four OCaml files without errors (syntax
check), and each diff is empty or shows only stylistic nits inside regions
this task touched. `lib/keeper/keeper_chat_blocks.mli` must show no
reformatting outside the two added declarations. CI compiles and runs
`test_keeper_chat_event_log`.

- [ ] **Step 6: Commit**

```bash
cat > /tmp/rfc0412-task1-msg.txt <<'MSG'
feat(keeper): versioned JSON codec for keeper_chat_event (RFC-0412 stage 1)

Add Keeper_chat_event_log with a strict, versioned ("v":1) JSON codec for
all 33 keeper_chat_event constructors plus the journaled_event envelope
{seq; ts; event}. The codec reuses the existing wire encoders
(stream_protocol_error_to_json, api_usage_to_json, delta_usage_to_json,
delivery_target_to_yojson) as its encode-side source of truth and adds
matching strict decoders. Keeper_chat_blocks.status_kind_to_label/of_label
are exposed so Status_block persists with the same labels the chat store
already uses. No read-path changes; nothing calls the codec yet.
MSG
git add lib/keeper/keeper_chat_event_log.ml lib/keeper/keeper_chat_event_log.mli \
  lib/keeper/keeper_chat_blocks.mli test/test_keeper_chat_event_log.ml test/dune
git commit -F /tmp/rfc0412-task1-msg.txt
```

---

### Task 2: Per-operation journal writer and reader

**Files:**
- Modify: `lib/keeper/keeper_chat_event_log.ml` (append the journal section)
- Modify: `lib/keeper/keeper_chat_event_log.mli`
- Test: `test/test_keeper_chat_event_log.ml`

- [ ] **Step 1: Write the failing journal tests**

Append to `test/test_keeper_chat_event_log.ml`, before the `let () = Alcotest.run ...` block:

```ocaml
(* --- temp-dir idiom (same as test_keeper_chat_store_append_result.ml) --- *)

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let scripted_clock timestamps =
  let remaining = ref timestamps in
  fun () ->
    match !remaining with
    | ts :: rest ->
      remaining := rest;
      ts
    | [] -> failwith "scripted clock exhausted"

let test_journal_round_trip () =
  let base_dir = temp_base_path "keeper-chat-event-log" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let clock = scripted_clock [ 1_762_300_000.0; 1_762_300_000.25 ] in
       let journal =
         L.open_journal ~now:clock ~base_dir ~keeper_name:"golden-keeper" ~operation_id:"op-1" ()
       in
       L.append journal ~seq:0 (E.Text_delta "hello");
       L.append journal ~seq:1 (E.Agent_core_thinking_delta { index = 0; delta = "hmm" });
       let journaled = L.read_journal journal in
       Alcotest.(check int) "two lines" 2 (List.length journaled);
       List.iteri
         (fun i (entry : L.journaled_event) ->
            Alcotest.(check int) "seq" i entry.seq)
         journaled;
       Alcotest.(check (float 0.0))
         "ts of first line"
         1_762_300_000.0
         (List.nth journaled 0).ts;
       Alcotest.(check string)
         "event payload round-trips through the journal"
         (Yojson.Safe.to_string (L.keeper_chat_event_to_json (E.Text_delta "hello")))
         (Yojson.Safe.to_string
            (L.keeper_chat_event_to_json (List.nth journaled 0).event)))

let test_journal_append_is_fail_open () =
  let file_path = temp_base_path "keeper-chat-event-log-file" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file_path with _ -> ())
    (fun () ->
       let oc = open_out file_path in
       close_out oc;
       (* base_dir nested under a regular file: directory creation and the
          append both fail with ENOTDIR, and neither may raise. *)
       let journal =
         L.open_journal
           ~base_dir:(Filename.concat file_path "under-a-file")
           ~keeper_name:"k"
           ~operation_id:"op"
           ()
       in
       L.append journal ~seq:0 (E.Text_delta "dropped, logged, live path unaffected");
       Alcotest.(check bool) "append did not raise" true true)

let test_journal_path_sanitizes_segments () =
  let path =
    L.journal_path ~base_dir:"/tmp/base" ~keeper_name:"keeper/x" ~operation_id:"op/../../escape"
  in
  let stem = Filename.remove_extension (Filename.basename path) in
  let keeper_segment = Filename.basename (Filename.dirname path) in
  Alcotest.(check bool)
    "operation segment is traversal-free"
    true
    (stem <> ".."
     && (not (String.contains stem '/'))
     && not (String.contains stem '.'));
  Alcotest.(check bool)
    "keeper segment is traversal-free"
    true
    (keeper_segment <> ".."
     && (not (String.contains keeper_segment '/'))
     && not (String.contains keeper_segment '.'));
  Alcotest.(check string)
    "journal root is <base>/.masc/keeper_chat_events"
    (Filename.concat
       (Masc.Common.masc_dir_from_base_path ~base_path:"/tmp/base")
       "keeper_chat_events")
    (Filename.dirname (Filename.dirname path))
```

Replace the `Alcotest.run` block with:

```ocaml
let () =
  Alcotest.run
    "keeper_chat_event_log"
    [ ( "codec"
      , [ Alcotest.test_case
            "round trip all constructors"
            `Quick
            test_codec_round_trip_all_constructors
        ; Alcotest.test_case "envelope round trip" `Quick test_envelope_round_trip
        ; Alcotest.test_case
            "envelope rejects unknown version"
            `Quick
            test_envelope_rejects_unknown_version
        ; Alcotest.test_case
            "codec rejects unknown tag"
            `Quick
            test_codec_rejects_unknown_tag
        ] )
    ; ( "journal"
      , [ Alcotest.test_case "round trip" `Quick test_journal_round_trip
        ; Alcotest.test_case
            "append is fail-open"
            `Quick
            test_journal_append_is_fail_open
        ; Alcotest.test_case
            "path sanitizes both segments"
            `Quick
            test_journal_path_sanitizes_segments
        ] )
    ]
```

- [ ] **Step 2: Verify the test fails (statically)**

Expected failure mode if compiled now: `Unbound value L.open_journal` /
`L.journal_path` / `L.append` / `L.read_journal`. Confirmed by inspection —
the Task 1 `.mli` declares only the codec. CI is the executor.

- [ ] **Step 3: Implement the journal**

Append to `lib/keeper/keeper_chat_event_log.ml`:

```ocaml
(** {1 Journal} *)

type journal =
  { path : string
  ; now : unit -> float
  }

let sanitize_segment = Workspace_utils_backend_setup.sanitize_namespace_segment

let events_dir ~base_dir =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path:base_dir)
    "keeper_chat_events"
;;

let journal_path ~base_dir ~keeper_name ~operation_id =
  Filename.concat
    (Filename.concat (events_dir ~base_dir) (sanitize_segment keeper_name))
    (sanitize_segment operation_id ^ ".jsonl")
;;

(* Fail-open at construction too: a directory we cannot create must not abort
   the turn; the per-event append below then logs each failure. *)
let open_journal ?(now = Time_compat.now) ~base_dir ~keeper_name ~operation_id () =
  let path = journal_path ~base_dir ~keeper_name ~operation_id in
  (try Fs_compat.mkdir_p (Filename.dirname path) with
   | exn ->
     Log.Keeper.error
       "keeper_chat_event_log: journal directory creation failed path=%s: %s"
       path
       (Printexc.to_string exn));
  { path; now }
;;

(* Fail-open by contract: stage 1 dual-writes next to keeper_chat_store, which
   remains the durable record of record. A journal failure is logged, never
   raised into the live path. *)
let append journal ~seq event =
  let line =
    Yojson.Safe.to_string
      (journaled_event_to_json { seq; ts = journal.now (); event })
    ^ "\n"
  in
  match Fs_compat.append_private_jsonl_durable_locked_result journal.path line with
  | Fs_compat.Private_file_succeeded () -> ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure
      { value = (); cleanup_failure } ->
    Log.Keeper.error
      "keeper_chat_event_log: append succeeded with descriptor settlement failure path=%s: %s"
      journal.path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Fs_compat.Private_file_failed error ->
    Log.Keeper.error
      "keeper_chat_event_log: journal append failed path=%s: %s"
      journal.path
      (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Log.Keeper.error
      "keeper_chat_event_log: journal append failed path=%s: %s; descriptor settlement failed: %s"
      journal.path
      (Fs_compat.private_jsonl_append_error_to_string error)
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
;;

(* Strict read: a corrupt line raises [Invalid_argument]. Stage 1 has no
   consumer for this beyond tests; replay serving (stage 2) decides the
   production corrupt-line policy then. *)
let read_journal journal =
  let ic = open_in_bin journal.path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         match input_line ic with
         | exception End_of_file -> List.rev acc
         | line ->
           if String.equal (String.trim line) ""
           then loop acc
           else begin
             match journaled_event_of_json (Yojson.Safe.from_string line) with
             | Ok journaled -> loop (journaled :: acc)
             | Error detail ->
               raise
                 (Invalid_argument
                    (Printf.sprintf
                       "keeper_chat_event_log: corrupt journal line path=%s: %s"
                       journal.path
                       detail))
           end
       in
       loop [])
;;
```

Append to `lib/keeper/keeper_chat_event_log.mli`:

```ocaml
(** {1 Journal} *)

type journal
(** An open per-operation journal: a resolved path plus the clock. *)

val journal_path :
  base_dir:string -> keeper_name:string -> operation_id:string -> string
(** [<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl], with both
    segments passed through
    [Workspace_utils_backend_setup.sanitize_namespace_segment] (the
    [Keeper_chat_store.sanitize_name] precedent); [operation_id] is
    client-derived, so it is sanitized too. *)

val open_journal :
  ?now:(unit -> float) ->
  base_dir:string ->
  keeper_name:string ->
  operation_id:string ->
  unit ->
  journal
(** Resolves the path and creates the parent directory. Fail-open: directory
    creation failure is logged, not raised. [now] defaults to
    [Time_compat.now] and is injectable for deterministic tests. *)

val append : journal -> seq:int -> Keeper_chat_events.keeper_chat_event -> unit
(** Synchronously appends one envelope line (fsync + truncate-rollback via
    [Fs_compat.append_private_jsonl_durable_locked_result]). Fail-open: every
    failure is logged via [Log.Keeper.error] and swallowed, so journaling
    never breaks the live turn. *)

val read_journal : journal -> journaled_event list
(** Reads and strictly decodes every line. Raises [Invalid_argument] on a
    corrupt line. Test support in stage 1. *)
```

- [ ] **Step 4: Verify statically + ocamlformat overlap check**

```bash
# The outcome constructors and error renderers must match fs_compat.mli.
grep -n "Private_file_succeeded\|Private_file_failed\|private_jsonl_append_error_to_string\|private_jsonl_operation_failure_to_string" \
  lib/fs_compat/fs_compat.mli | head -8

# ocamlformat overlap check on the two touched files
for f in lib/keeper/keeper_chat_event_log.ml lib/keeper/keeper_chat_event_log.mli \
         test/test_keeper_chat_event_log.ml; do
  cp "$f" /tmp/rfc0412-fmt/
  ocamlformat "/tmp/rfc0412-fmt/$(basename "$f")" > "/tmp/rfc0412-fmt/$(basename "$f").fmt" \
    && git diff --no-index -U0 "$f" "/tmp/rfc0412-fmt/$(basename "$f").fmt" || true
done
```

Expected: ocamlformat parses without errors; diffs confined to this task's
regions. CI compiles and runs the `journal` test group.

- [ ] **Step 5: Commit**

```bash
cat > /tmp/rfc0412-task2-msg.txt <<'MSG'
feat(keeper): per-operation JSONL journal for keeper chat events

Keeper_chat_event_log gains the journal half of RFC-0412 stage 1:
journal_path under <base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl
with sanitize_namespace_segment on both segments, open_journal with an
injectable clock, a synchronous fail-open append built on
Fs_compat.append_private_jsonl_durable_locked_result (fsync +
truncate-rollback), and a strict read_journal used by tests. Nothing calls
it yet; the bus hook lands next.
MSG
git add lib/keeper/keeper_chat_event_log.ml lib/keeper/keeper_chat_event_log.mli \
  test/test_keeper_chat_event_log.ml
git commit -F /tmp/rfc0412-task2-msg.txt
```

---

### Task 3: `seq` attachment and publish hook on the event bus

**Files:**
- Modify: `lib/keeper/keeper_chat_events.ml:160-164` (stream operations)
- Modify: `lib/keeper/keeper_chat_events.mli:199-210` (stream operations)
- Modify: `lib/server/server_routes_http_keeper_stream.ml:1542` (annotation)
- Modify: `lib/server/server_routes_http_keeper_stream.mli:255` (signature)
- Modify: `lib/keeper/keeper_chat_slack.ml:527` (annotation)
- Modify: `lib/keeper/keeper_chat_slack.mli:76,159` (signatures)
- Modify: `lib/keeper/keeper_chat_discord.mli:42,107` (signatures)
- Test: `test/test_keeper_chat_event_log.ml`

- [ ] **Step 1: Write the failing hook tests**

Append to `test/test_keeper_chat_event_log.ml`, before the
`let () = Alcotest.run ...` block:

```ocaml
let test_on_publish_hook_receives_monotonic_seq () =
  let seen = ref [] in
  let bus =
    Masc.Keeper_chat_events.create
      ~on_publish:(fun ~seq event -> seen := (seq, event) :: !seen)
      ()
  in
  List.iter
    (Masc.Keeper_chat_events.publish bus)
    [ E.Text_delta "a"; E.Text_delta "b"; E.Text_message_end ];
  Alcotest.(check (list int))
    "seq is 0-based and monotonic"
    [ 0; 1; 2 ]
    (List.rev_map fst !seen);
  (* publish order == subscribe order, hook or no hook *)
  (match Masc.Keeper_chat_events.subscribe bus with
   | E.Text_delta "a" -> ()
   | _ -> Alcotest.fail "first subscribed event mismatch")

let test_on_publish_hook_failure_does_not_break_publish () =
  let bus =
    Masc.Keeper_chat_events.create
      ~on_publish:(fun ~seq:_ _ -> failwith "journal exploded")
      ()
  in
  Masc.Keeper_chat_events.publish bus (E.Text_delta "still delivered");
  match Masc.Keeper_chat_events.subscribe bus with
  | E.Text_delta "still delivered" -> ()
  | _ -> Alcotest.fail "event lost after hook failure"
```

Add a `"bus hook"` group to the `Alcotest.run` block:

```ocaml
    ; ( "bus hook"
      , [ Alcotest.test_case
            "hook receives monotonic seq"
            `Quick
            test_on_publish_hook_receives_monotonic_seq
        ; Alcotest.test_case
            "hook failure does not break publish"
            `Quick
            test_on_publish_hook_failure_does_not_break_publish
        ] )
```

- [ ] **Step 2: Verify the test fails (statically)**

Expected failure mode if compiled now: `Error: Unbound value Masc.Keeper_chat_events.create ~on_publish ...`
(labeled argument `~on_publish` does not exist) — confirmed by inspection of
`keeper_chat_events.mli:203`. CI is the executor.

- [ ] **Step 3: Make the bus type abstract and add the hook**

In `lib/keeper/keeper_chat_events.ml`, replace the three stream operations
(currently `:160-164`):

```ocaml
let create () = Eio.Stream.create 512

let publish stream event = Eio.Stream.add stream event

let subscribe stream = Eio.Stream.take stream
```

with:

```ocaml
type t =
  { stream : keeper_chat_event Eio.Stream.t
  ; on_publish : (seq:int -> keeper_chat_event -> unit) option
  ; mutable next_seq : int
  }

let create ?on_publish () =
  { stream = Eio.Stream.create 512; on_publish; next_seq = 0 }
;;

(* [publish] is the single choke point every turn event passes through — route
   lifecycle, bridge-translated deltas, and terminal paths all call it. The
   hook runs BEFORE the bus add so the canonical journal records what the turn
   produced even when a full bus suspends the add. The ordering guarantee
   rests on one invariant: every [publish] for a given bus runs in the single
   publisher fiber, so seq assignment → hook → bus add executes sequentially
   within that fiber and journal order == seq order == bus order with no extra
   lock. The journal hook's blocking Unix I/O is offloaded via
   Fs_compat.run_blocking_private_file_transaction
   (Eio_unix.run_in_systhread when called from an Eio fiber), which suspends
   only the calling fiber — that keeps sibling fibers responsive but is not
   what makes the ordering safe. *)
let publish t event =
  (match t.on_publish with
   | None -> ()
   | Some hook ->
     let seq = t.next_seq in
     t.next_seq <- seq + 1;
     (try hook ~seq event with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.error
          "keeper_chat_events: on_publish hook failed seq=%d: %s"
          seq
          (Printexc.to_string exn)));
  Eio.Stream.add t.stream event
;;

let subscribe t = Eio.Stream.take t.stream
```

In `lib/keeper/keeper_chat_events.mli`, replace the "Stream operations"
section (`:199-210`):

```ocaml
(** {1 Stream operations} *)

(** [create ()] returns a new bounded event stream.
    Each turn should create its own stream instance. *)
val create : unit -> keeper_chat_event Eio.Stream.t

(** [publish stream event] adds [event] to the stream.
    Non-blocking; raises if the stream is full (backpressure). *)
val publish : keeper_chat_event Eio.Stream.t -> keeper_chat_event -> unit

(** [subscribe stream] blocks until an event is available, then returns it. *)
val subscribe : keeper_chat_event Eio.Stream.t -> keeper_chat_event
```

with:

```ocaml
(** {1 Stream operations} *)

type t
(** Bounded per-turn event stream plus its optional journal hook (RFC-0412
    stage 1). *)

(** [create ?on_publish ()] returns a new bounded event stream. Each turn
    should create its own stream instance. [on_publish], when given, is
    invoked synchronously with a 0-based per-stream sequence number BEFORE the
    event enters the bus; hook exceptions are logged and swallowed (except
    cancellation, which is re-raised) so a journal failure can never break the
    live turn. *)
val create : ?on_publish:(seq:int -> keeper_chat_event -> unit) -> unit -> t

(** [publish t event] runs the journal hook (if any) and adds [event] to the
    stream. With a journal hook installed, the hook performs brief blocking
    Unix I/O (fsync + rollback per line); hook-free buses are non-blocking
    until full. A full stream suspends the writer fiber until a reader frees
    a slot (Eio backpressure) — the hook has already run by then, so the
    journal still holds the event. *)
val publish : t -> keeper_chat_event -> unit

(** [subscribe t] blocks until an event is available, then returns it. *)
val subscribe : t -> keeper_chat_event

(** [take_nonblocking t] returns the next queued event, or [None] when the
    bus is empty. Drain/test support: it bypasses the blocking [subscribe]
    contract and must not sit on a live read path. *)
val take_nonblocking : t -> keeper_chat_event option
```

Update the five signature/annotation sites that name the old concrete type —
in each case replace
`Keeper_chat_events.keeper_chat_event Eio.Stream.t` with `Keeper_chat_events.t`:

- `lib/server/server_routes_http_keeper_stream.ml:1542`:
  `~(events : Keeper_chat_events.keeper_chat_event Eio.Stream.t)` →
  `~(events : Keeper_chat_events.t)`
- `lib/server/server_routes_http_keeper_stream.mli:255`:
  `events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->` →
  `events:Keeper_chat_events.t ->`
- `lib/keeper/keeper_chat_slack.ml:527`:
  `~(events : Keeper_chat_events.keeper_chat_event Eio.Stream.t)` →
  `~(events : Keeper_chat_events.t)`
- `lib/keeper/keeper_chat_slack.mli:76` and `:159`: same replacement
- `lib/keeper/keeper_chat_discord.mli:42` and `:107`: same replacement

`test/test_keeper_chat_slack.ml:245-246` and
`test/test_keeper_chat_discord.ml:12-13` call `Masc.Keeper_chat_events.create ()`
and `Masc.Keeper_chat_events.publish stream …` — both still typecheck
unchanged (optional argument; `publish` takes the abstract `t`). No edits.

- [ ] **Step 4: Verify statically + ocamlformat overlap check**

```bash
# No remaining references to the old concrete type anywhere.
grep -rn "keeper_chat_event Eio.Stream.t" lib bin test || echo "clean"

# No code bypasses the abstract API with raw Eio.Stream ops on the bus.
grep -rn "Eio.Stream.take events\|Eio.Stream.add events" lib bin || echo "clean"

# ocamlformat overlap check on the touched files
for f in lib/keeper/keeper_chat_events.ml lib/keeper/keeper_chat_events.mli \
         lib/server/server_routes_http_keeper_stream.ml \
         lib/server/server_routes_http_keeper_stream.mli \
         lib/keeper/keeper_chat_slack.ml lib/keeper/keeper_chat_slack.mli \
         lib/keeper/keeper_chat_discord.mli test/test_keeper_chat_event_log.ml; do
  cp "$f" /tmp/rfc0412-fmt/"$(echo "$f" | tr / _)"
  ocamlformat "/tmp/rfc0412-fmt/$(echo "$f" | tr / _)" \
    > "/tmp/rfc0412-fmt/$(echo "$f" | tr / _).fmt" \
    && git diff --no-index -U0 "$f" "/tmp/rfc0412-fmt/$(echo "$f" | tr / _).fmt" || true
done
```

Expected: both greps print `clean` (the second grep may match unrelated
`events` variables, e.g. `lib/gate/discord_wss_connection.ml` — those are a
different stream and are fine; check paths). ocamlformat diffs are confined
to the edited regions of the five pre-existing files (zero churn elsewhere).
CI compiles everything and runs the `bus hook` group.

- [ ] **Step 5: Commit**

```bash
cat > /tmp/rfc0412-task3-msg.txt <<'MSG'
feat(keeper): attach seq and a publish hook to the keeper chat event bus

Keeper_chat_events gains an abstract t wrapping the Eio.Stream plus an
optional on_publish hook that receives a bus-assigned 0-based seq before the
event enters the bus. publish is the single choke point every turn event
passes through (route lifecycle, bridge deltas, terminal paths), so the hook
sees 100% of events, including the five adapter-only block events that
project to None on the AG-UI surface. Hook exceptions are logged and
swallowed (cancellation re-raised); hook-before-add ordering means a full
bus cannot lose a journaled event. Signature sites in the Slack/Discord
adapters and the stream route move from the concrete stream type to
Keeper_chat_events.t; all publish/subscribe call sites are unchanged.
MSG
git add lib/keeper/keeper_chat_events.ml lib/keeper/keeper_chat_events.mli \
  lib/server/server_routes_http_keeper_stream.ml \
  lib/server/server_routes_http_keeper_stream.mli \
  lib/keeper/keeper_chat_slack.ml lib/keeper/keeper_chat_slack.mli \
  lib/keeper/keeper_chat_discord.mli test/test_keeper_chat_event_log.ml
git commit -F /tmp/rfc0412-task3-msg.txt
```

---

### Task 4: Dual-write wiring at the operation runner

**Files:**
- Modify: `lib/server/server_routes_http_keeper_stream.ml:2613-2616` (the sole
  production `Keeper_chat_events.create` call site)
- Test: `test/test_keeper_chat_event_log.ml`

- [ ] **Step 1: Write the failing integration test**

Append to `test/test_keeper_chat_event_log.ml`, before the
`let () = Alcotest.run ...` block:

```ocaml
let test_bus_journal_integration_records_all_events () =
  let base_dir = temp_base_path "keeper-chat-event-log-bus" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let journal =
         L.open_journal ~base_dir ~keeper_name:"k" ~operation_id:"op-9" ()
       in
       let bus =
         Masc.Keeper_chat_events.create ~on_publish:(L.append journal) ()
       in
       List.iter (Masc.Keeper_chat_events.publish bus) all_events;
       let journaled = L.read_journal journal in
       Alcotest.(check int)
         "every published event is journaled"
         (List.length all_events)
         (List.length journaled);
       List.iteri
         (fun i (entry : L.journaled_event) ->
            Alcotest.(check int) "seq" i entry.seq)
         journaled;
       (* The adapter-only block events are journaled even though they
          project to None on the AG-UI surface. [all_events] carries 8 such
          instances across the five kinds: 1 Link + 2 Image (caption
          populated/absent) + 2 Status + 2 Audio + 1 Tool_context. *)
       let adapter_blocks =
         List.filter
           (fun (entry : L.journaled_event) ->
              match entry.event with
              | E.Link_block _
              | E.Image_block _
              | E.Status_block _
              | E.Audio_block _
              | E.Tool_context_block _ -> true
              | _ -> false)
           journaled
       in
       Alcotest.(check int)
         "all adapter-only block instances are journaled"
         8
         (List.length adapter_blocks))
```

Add to the `Alcotest.run` block:

```ocaml
    ; ( "integration"
      , [ Alcotest.test_case
            "bus journal records every published event"
            `Quick
            test_bus_journal_integration_records_all_events
        ] )
```

- [ ] **Step 2: Verify the test fails (statically)**

Expected failure mode if compiled now: none — the test compiles and passes
against Task 3's hook alone, because it wires the journal by hand. Its role
is pinning the exact wiring shape that Step 3 installs in the route; it is
written in this task so the route edit and its pin land together. CI is the
executor.

- [ ] **Step 3: Wire the journal into the operation runner**

In `lib/server/server_routes_http_keeper_stream.ml`, replace `:2613-2616`:

```ocaml
            let operation_id =
              Keeper_owner.Chat_operation.Operation_id.to_string operation.operation_id
            in
            let events = Keeper_chat_events.create () in
```

with:

```ocaml
            let operation_id =
              Keeper_owner.Chat_operation.Operation_id.to_string operation.operation_id
            in
            (* RFC-0412 stage 1 dual-write: every event published on this bus
               is also appended to the per-operation canonical journal.
               Fail-open — a journal failure never breaks the live turn. *)
            let journal =
              Keeper_chat_event_log.open_journal
                ~base_dir:(Mcp_server.workspace_config state).base_path
                ~keeper_name
                ~operation_id
                ()
            in
            let events =
              Keeper_chat_events.create
                ~on_publish:(Keeper_chat_event_log.append journal)
                ()
            in
```

`keeper_name` is already in scope (used at `:2604`), as is `state`. This is
the only production `Keeper_chat_events.create` call site (the other two are
in `test/test_keeper_chat_slack.ml` / `test/test_keeper_chat_discord.ml`), so
this one edit covers every live turn regardless of continuation channel
(Dashboard / Discord / Slack).

- [ ] **Step 4: Verify statically + ocamlformat overlap check**

```bash
# Exactly one production create site, and it now carries the hook.
grep -n "Keeper_chat_events.create" lib bin

# keeper_chat_store dual-write partner is untouched.
git diff origin/main...HEAD -- lib/keeper/keeper_chat_store.ml | wc -l   # expect 0

# ocamlformat overlap check
f=lib/server/server_routes_http_keeper_stream.ml
cp "$f" /tmp/rfc0412-fmt/stream.ml
ocamlformat /tmp/rfc0412-fmt/stream.ml > /tmp/rfc0412-fmt/stream.ml.fmt \
  && git diff --no-index -U0 "$f" /tmp/rfc0412-fmt/stream.ml.fmt || true
```

Expected: the grep shows `create ~on_publish` at the operation-runner site
and bare `create ()` only in the two adapter test files. The ocamlformat
diff touches only the wired region (`:2613-2629`). CI compiles and runs the
`integration` group.

- [ ] **Step 5: Commit**

```bash
cat > /tmp/rfc0412-task4-msg.txt <<'MSG'
feat(keeper): dual-write keeper chat turns to the canonical event journal

Wire Keeper_chat_event_log into the operation runner's sole
Keeper_chat_events.create call site, so every event of every live turn —
any continuation channel — is synchronously journaled to
<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl next to the
existing keeper_chat_store writes, which are unchanged. Journaling is
fail-open at two layers (append logs every Fs_compat outcome; publish
catches hook exceptions), and the append runs before the bus add so a full
bus cannot lose a journaled event. Read paths are untouched.
MSG
git add lib/server/server_routes_http_keeper_stream.ml test/test_keeper_chat_event_log.ml
git commit -F /tmp/rfc0412-task4-msg.txt
```

---

### Task 5: Golden replay test — journal replay reproduces the live SSE bytes

**Files:**
- Test: `test/test_keeper_chat_event_log.ml`

- [ ] **Step 1: Write the golden test**

Append to `test/test_keeper_chat_event_log.ml`, before the
`let () = Alcotest.run ...` block:

```ocaml
(* A well-formed turn exercising every constructor that produces SSE output
   plus the five adapter-only blocks (which must be journaled but project to
   [None]). [Event_error] is omitted: it is the alternative terminal, already
   covered by the codec round-trip. *)
let golden_events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-golden"; thread_id = "keeper:golden" }
  ; E.Agent_core_stream_connected
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-1"; model = "kimi-for-coding"; usage = Some usage_full }
  ; E.Agent_core_stream_ping
  ; E.Text_message_start { message_id = "msg-1"; role = E.Assistant }
  ; E.Agent_core_content_block_start
      { index = 0
      ; content_type = "thinking"
      ; tool_call_id = None
      ; tool_call_name = None
      }
  ; E.Agent_core_thinking_delta { index = 0; delta = "let me think" }
  ; E.Agent_core_thinking_signature_delta { index = 0; signature_bytes = 128 }
  ; E.Agent_core_content_block_stop { index = 0 }
  ; E.Text_delta "Hello"
  ; E.Text_delta ", world"
  ; E.Agent_core_content_block_start
      { index = 1
      ; content_type = "tool_use"
      ; tool_call_id = Some "tc-1"
      ; tool_call_name = Some "read_file"
      }
  ; E.Tool_call_start
      { occurrence; tool_call_id = Some "tc-1"; tool_call_name = "read_file" }
  ; E.Tool_call_args { occurrence; tool_call_id = Some "tc-1"; delta = "{\"path\":" }
  ; E.Tool_call_args_snapshot
      { occurrence; tool_call_id = Some "tc-1"; snapshot = "{\"path\":\"/tmp/x\"}" }
  ; E.Tool_call_end { occurrence; tool_call_id = Some "tc-1" }
  ; E.Agent_core_content_block_stop { index = 1 }
  ; E.Tool_approval_requested
      { tool_call_id = "tc-1"
      ; tool_call_name = "read_file"
      ; args = "{\"path\":\"/tmp/x\"}"
      ; question = "allow read?"
      ; because = "policy: fs read"
      }
  ; E.Tool_approval_settled { tool_call_id = "tc-1"; outcome = "approved" }
  ; E.Tool_result_ready
      { occurrence
      ; tool_call_id = Some "tc-1"
      ; execution_id = Ids.Execution_id.of_string "exec-golden-1"
      }
  ; E.Agent_core_media_delta
      { index = 2
      ; media_type = "image/png"
      ; source_type = Agent_core.Types.Url
      ; media_ref = "/api/v1/media/tok-golden"
      }
  ; E.Agent_core_stream_protocol_error protocol_error_full
  ; E.Agent_core_runtime_attempt_started
  ; E.Agent_core_stream_message_delta
      { stop_reason = Some Agent_core.Types.EndTurn
      ; usage = Some delta_usage_partial
      }
  ; E.Agent_core_stream_message_stop
  ; E.Text_message_end
  ; E.Link_block
      { url = "https://example.com"
      ; title = "Example"
      ; description = Some "desc"
      ; image = Some "https://example.com/i.png"
      }
  ; E.Image_block { url = "https://example.com/i.png"; caption = Some "cap" }
  ; E.Status_block { kind = Blocks.Awaiting_gate_approval }
  ; E.Audio_block
      { token = "aud-1"
      ; mime = "audio/ogg"
      ; message_text = "voice"
      ; duration_sec = Some 1.5
      }
  ; E.Tool_context_block
      { tool_call_id = "tc-1"
      ; name = "read_file"
      ; args_summary = "path /tmp/x"
      ; result_summary = Some "42 bytes"
      }
  ; E.Continuation_checkpoint { message = "checkpoint"; request_id = Some "req-golden" }
  ; E.External_effect_completed
      { target =
          Surface.Delivered_to_slack { channel_id = "C123"; thread_ts = Some "1700.5" }
      }
  ; E.Reply_details
      { reply = "Hello, world"
      ; turn_outcome = Outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-golden" ~absolute_turn:1
      }
  ; E.Run_finished { run_id = "run-golden" }
  ]

(* The exact fold the live Dashboard adapter performs
   (server_routes_http_keeper_stream.ml:2646-2668): project with a per-event
   injected timestamp, serialize projected events with Ag_ui.event_to_sse —
   the same serializer keeper_stream_send_event uses at :1017-1018 — and skip
   None projections. *)
let projected_sse_bytes timed_events =
  let _, rev_bytes =
    List.fold_left
      (fun (projection, acc) (ts, event) ->
         let projection, projected =
           Projection.project
             ~timestamp:ts
             ~redact_text:Fun.id
             ~redact_json:Fun.id
             projection
             event
         in
         ( projection
         , match projected with
           | Some ag_event -> Ag_ui.event_to_sse ag_event :: acc
           | None -> acc ))
      (Projection.initial, [])
      timed_events
  in
  String.concat "" (List.rev rev_bytes)

let test_golden_replay_matches_live_stream_bytes () =
  let base_dir = temp_base_path "keeper-chat-event-log-golden" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       (* Exact binary fractions: float -> JSON -> float is byte-exact for
          these values, and the per-line ts assert below catches drift. *)
       let timestamps =
         List.mapi (fun i _ -> 1_762_300_000.0 +. (float_of_int i *. 0.25)) golden_events
       in
       (* Live path: fold the in-memory events with scripted injected time. *)
       let live_bytes = projected_sse_bytes (List.combine timestamps golden_events) in
       (* Journal the whole turn through the real bus with a scripted clock. *)
       let clock = scripted_clock timestamps in
       let journal =
         L.open_journal ~now:clock ~base_dir ~keeper_name:"golden" ~operation_id:"op-golden" ()
       in
       let bus =
         Masc.Keeper_chat_events.create ~on_publish:(L.append journal) ()
       in
       List.iter (Masc.Keeper_chat_events.publish bus) golden_events;
       (* Replay: decode the journal, re-fold from [initial] with the
          journaled ts. *)
       let journaled = L.read_journal journal in
       Alcotest.(check int)
         "journal holds the whole turn"
         (List.length golden_events)
         (List.length journaled);
       List.iter2
         (fun scripted_ts (entry : L.journaled_event) ->
            Alcotest.(check (float 0.0))
              "ts survives the journal"
              scripted_ts
              entry.ts)
         timestamps
         journaled;
       let replay_bytes =
         projected_sse_bytes
           (List.map (fun (entry : L.journaled_event) -> entry.ts, entry.event) journaled)
       in
       Alcotest.(check string)
         "replay reproduces the live SSE byte stream"
         live_bytes
         replay_bytes;
       (* The five adapter-only block events are invisible in the byte
          comparison (they project to None); pin their journal presence
          separately so the byte-equality green can never mask a journal
          gap. *)
       let adapter_blocks =
         List.filter
           (fun (entry : L.journaled_event) ->
              match entry.event with
              | E.Link_block _
              | E.Image_block _
              | E.Status_block _
              | E.Audio_block _
              | E.Tool_context_block _ -> true
              | _ -> false)
           journaled
       in
       Alcotest.(check int)
         "five adapter-only block events journaled"
         5
         (List.length adapter_blocks))
```

Add to the `Alcotest.run` block:

```ocaml
    ; ( "golden"
      , [ Alcotest.test_case
            "journal replay reproduces the live SSE byte stream"
            `Quick
            test_golden_replay_matches_live_stream_bytes
        ] )
```

- [ ] **Step 2: Verify statically + ocamlformat overlap check**

Expected failure mode if compiled without Tasks 1–4: unbound `L.open_journal`
etc. With Tasks 1–4 in place, the only untyped names are local. Static
checks:

```bash
# Projection signature matches the test's call shape.
sed -n '1,30p' lib/server/server_keeper_chat_agui_projection.mli

# ocamlformat overlap check
f=test/test_keeper_chat_event_log.ml
cp "$f" /tmp/rfc0412-fmt/golden.ml
ocamlformat /tmp/rfc0412-fmt/golden.ml > /tmp/rfc0412-fmt/golden.ml.fmt \
  && git diff --no-index -U0 "$f" /tmp/rfc0412-fmt/golden.ml.fmt || true
```

Expected: `Projection.project` takes
`timestamp:float -> redact_text:(string -> string) -> redact_json:(Yojson.Safe.t -> Yojson.Safe.t) -> t -> Keeper_chat_events.keeper_chat_event -> t * Ag_ui.event option`
and `Ag_ui.event_to_sse : ?id:int -> event -> string`. CI runs the `golden`
group; the byte-equality assert is the RFC §6 stage-1 acceptance criterion
("로그 리플레이 == 라이브 스트림 바이트 동등").

- [ ] **Step 3: Commit**

```bash
cat > /tmp/rfc0412-task5-msg.txt <<'MSG'
test(keeper): golden replay of the chat event journal through the AG-UI projection

Pin the RFC-0412 §6 stage-1 acceptance criterion: a scripted 35-event turn
is journaled through the real bus with a scripted clock, read back, decoded,
and re-folded through Server_keeper_chat_agui_projection.project from
initial with the journaled timestamps; the resulting Ag_ui.event_to_sse byte
stream must equal the live-path fold byte for byte. The five adapter-only
block events (Link/Image/Status/Audio/Tool_context) are pinned present in
the journal separately, since they project to None and are invisible to the
byte comparison.
MSG
git add test/test_keeper_chat_event_log.ml
git commit -F /tmp/rfc0412-task5-msg.txt
```

---

### Task 6: CI validation

**Files:** none.

- [ ] **Step 1: Trigger CI on the branch**

```bash
gh workflow run ci.yml --ref rfc/chat-canonical-log
gh run list --workflow ci.yml --branch rfc/chat-canonical-log --limit 1
```

Per the constitution `<build_and_ci>`: do not poll or watch the run. This is
a work boundary, so before the stage-1 PR chain is considered done, check
the completed run once:

```bash
gh run view --log-failed <run-id>   # only if the run failed
```

Expected: `test_keeper_chat_event_log` runs green (all five groups: codec,
journal, bus hook, integration, golden), and the full suite shows no
regression in the adapter tests (`test_keeper_chat_slack`,
`test_keeper_chat_discord`) that consume `Keeper_chat_events`.

If CI is red on files this plan touched: fix, re-run the task's static
verification, amend-or-new-commit per review norms, and re-trigger CI. If CI
is red on unrelated pre-existing failures, note them in the PR body and move
on — do not sink into unrelated CI repair (constitution `<build_and_ci>`).

---

## Spec coverage map (RFC-0412 §4.1 → tasks)

- Versioned JSON codec for `keeper_chat_event` → Task 1.
- `seq`/`ts` attachment → Task 3 (seq, bus-assigned) + Task 2 (ts, journal
  clock), envelope in Task 1.
- Journal at `<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl`
  → Task 2 (writer) + Task 4 (wiring).
- Dual-write; `keeper_chat_store` writes and read paths unchanged → Task 4
  (verified by the `git diff main...HEAD -- keeper_chat_store.ml` check).
- Golden test: journal replay through the AG-UI projection reproduces live
  stream bytes → Task 5.
- Journaling must not block/break the live path (bus capacity 512) → design
  decision 5; fail-open enforced in Tasks 2 (`append`) and 3 (`publish`).
