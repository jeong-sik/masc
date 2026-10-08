(* RFC-0412 stage 3a — the per-operation event log behind the keeper chat
   pane. Seq dedup, the attempt counter, the committed flag and revision, the
   v2 page decoder, and the golden case: a journal decoded through
   [delta_of_journaled] equals the same journal projected by the server to
   AG-UI, encoded as SSE, and read by the live decoder. *)

open Alcotest
module Live = Masc_tui_keeper_chat_live

(* Most fixtures compare stream content and sequence only; timestamp parity is
   exercised separately through the observed-delta API. *)
let feed decoder chunk =
  Live.feed decoder chunk
  |> List.map (fun (item : Live.observed_delta) -> item.seq, item.delta)

module Log = Masc_tui_keeper_chat_log
module E = Masc.Keeper_chat_events
module Journal = Masc.Keeper_chat_event_log
module Outcome = Masc.Keeper_turn_outcome
module Projection = Server_keeper_chat_agui_projection

let position =
  testable
    (fun formatter position ->
      Format.pp_print_string formatter (Journal.replay_position_to_string position))
    ( = )

let occurrence_to_string (o : Live.tool_occurrence) =
  Printf.sprintf "%d/%d/%s/%s" o.stream_scope o.block_index
    (Option.value ~default:"-" o.provider_message_id)
    (Option.value ~default:"-" o.tool_call_id)

let token_count = function Some value -> string_of_int value | None -> "none"

let delta_to_string : Live.delta -> string = function
  | Live.Batch_bound {operation_id; execution_id} -> Printf.sprintf "batch(%s,%s)" operation_id execution_id
  | Live.Run_started -> "run_started"
  | Live.Runtime_attempt_started { runtime_id; attempt_index } ->
      Printf.sprintf "runtime_attempt_started(%s,%s)"
        (Option.value ~default:"none" runtime_id)
        (match attempt_index with Some i -> string_of_int i | None -> "none")
  | Live.Stream_model_started { model; _ } -> Printf.sprintf "stream_model_started(%s)" model
  | Live.Stream_details { usage; stop_reason } ->
      Printf.sprintf "stream_details(%s,stop=%s)"
        (match usage with
         | None -> "no usage"
         | Some usage ->
             Printf.sprintf "in=%s,out=%s,cache_read=%s,cache_write=%s"
               (token_count usage.Live.input_tokens)
               (token_count usage.Live.output_tokens)
               (token_count usage.Live.cache_read_input_tokens)
               (token_count usage.Live.cache_creation_input_tokens))
        (Option.value ~default:"none" stop_reason)
  | Live.Text text -> "text(" ^ text ^ ")"
  | Live.Thinking text -> "thinking(" ^ text ^ ")"
  | Live.Native_tool_started { occurrence; tool_name } ->
      Printf.sprintf "native_tool_started(%s,%s)" (occurrence_to_string occurrence)
        (Option.value ~default:"unnamed" tool_name)
  | Live.Native_tool_ended { occurrence; _ } ->
      Printf.sprintf "native_tool_ended(%s)" (occurrence_to_string occurrence)
  | Live.Tool_started { occurrence; tool_name } ->
      Printf.sprintf "tool_started(%s,%s)" (occurrence_to_string occurrence) tool_name
  | Live.Tool_args { occurrence; fragment = Live.Args_delta delta } ->
      Printf.sprintf "tool_args_delta(%s,%s)" (occurrence_to_string occurrence) delta
  | Live.Tool_args { occurrence; fragment = Live.Args_snapshot snapshot } ->
      Printf.sprintf "tool_args_snapshot(%s,%s)" (occurrence_to_string occurrence) snapshot
  | Live.Tool_ended { occurrence } ->
      Printf.sprintf "tool_ended(%s)" (occurrence_to_string occurrence)
  | Live.Tool_result { occurrence; execution_id } ->
      Printf.sprintf "tool_result(%s,%s)" (occurrence_to_string occurrence) execution_id
  | Live.Stream_protocol_error { quarantined_occurrence; detail } ->
      Printf.sprintf "stream_protocol_error(%s,%s)"
        (Option.fold ~none:"-" ~some:occurrence_to_string quarantined_occurrence)
        detail
  | Live.Approval_requested { call_id; tool_name; args; question; because } ->
      Printf.sprintf "approval_requested(%s,%s,%s,%s,%s)" call_id tool_name args
        question because
  | Live.Approval_settled { call_id; outcome } ->
      Printf.sprintf "approval_settled(%s,%s)" call_id outcome
  | Live.Accepted { admission; queue_length; _ } ->
      Printf.sprintf "accepted(%s,%d)"
        (match admission with
         | Live.Queued -> "queued"
         | Live.Running -> "running"
         | Live.Settled -> "settled")
        queue_length
  | Live.Checkpoint -> "checkpoint"
  | Live.External_effect_completed -> "external_effect_completed"
  | Live.Reply_details { reply; turn_outcome; turn_ref } ->
      Printf.sprintf "reply_details(%s,%s,%s)" reply (Outcome.to_label turn_outcome) turn_ref
  | Live.Run_failed { message } -> "run_failed(" ^ message ^ ")"
  | Live.Run_finished -> "run_finished"
  | Live.Undecodable detail -> "undecodable(" ^ detail ^ ")"

let delta = testable (Fmt.of_to_string delta_to_string) ( = )
let tagged = pair (option int) delta

let log () = Log.create ~keeper_name:"keeper.one" ~request_id:"tui-req-1" ~started_at:10.0

(* ── Log mechanics ────────────────────────────────────────────────── *)

let test_seq_dedup_and_none_never_dedupes () =
  let t = log () in
  check bool "first add" true (Log.add t ~seq:(Some 0) Live.Run_started);
  check bool "same seq is a duplicate" false (Log.add t ~seq:(Some 0) (Live.Text "again"));
  let revision = Log.revision t in
  check bool "duplicate leaves the revision alone" true (Log.revision t = revision);
  check bool "an id-less delta is added" true (Log.add t ~seq:None (Live.Accepted { admission = Live.Running; queue_length = 1; interactive = None }));
  check bool "and again: None never dedupes" true (Log.add t ~seq:None (Live.Accepted { admission = Live.Running; queue_length = 1; interactive = None }));
  check int "three entries" 3 (List.length (Log.entries t));
  check position "resume position" (Journal.After_seq 0) (Log.resume_position t)

let test_resume_position_follows_the_highest_held () =
  let t = log () in
  check position "empty log: the whole turn" Journal.Whole_turn (Log.resume_position t);
  ignore (Log.add t ~seq:(Some 4) (Live.Text "a") : bool);
  ignore (Log.add t ~seq:(Some 2) (Live.Text "b") : bool);
  check position "gaps do not matter, order does not matter" (Journal.After_seq 4)
    (Log.resume_position t)

let test_attempt_advances_on_runtime_attempt_started () =
  let t = log () in
  ignore (Log.add t ~seq:(Some 0) Live.Run_started : bool);
  ignore (Log.add t ~seq:(Some 1) (Live.Text "first try") : bool);
  ignore (Log.add t ~seq:(Some 2) (Live.Runtime_attempt_started { runtime_id = None; attempt_index = None }) : bool);
  ignore (Log.add t ~seq:(Some 3) (Live.Text "second try") : bool);
  check int "current attempt" 1 (Log.attempt t);
  check (list int) "each entry keeps the attempt it arrived in"
    [ 0; 0; 1; 1 ]
    (List.map (fun (entry : Log.entry) -> entry.attempt) (Log.entries t))

let test_commit_is_idempotent_and_bumps_once () =
  let t = log () in
  check bool "starts uncommitted" false (Log.committed t);
  let before = Log.revision t in
  Log.commit t;
  Log.commit t;
  check bool "committed" true (Log.committed t);
  check int "one bump for two commits" (before + 1) (Log.revision t)

(* ── v2 page ──────────────────────────────────────────────────────── *)

let line seq ts event : Journal.journaled_event = { seq; ts; event }

let page_json ?(schema = "masc.keeper_chat_events.v2") ?(next_since_offset = `Int 0)
    ~has_more ~next_since_seq lines =
  `Assoc
    [ "schema", `String schema
    ; "operation_id", `String "tui-req-1"
    ; "events", `List (List.map Journal.journaled_event_to_json lines)
    ; "has_more", `Bool has_more
    ; "next_since_seq", Journal.replay_position_to_yojson next_since_seq
    ; "next_since_offset", next_since_offset
    ]

let test_operation_and_journal_read_order () =
  let open Keeper_chat_operation in
  List.iter (fun next ->
    let calls = ref [] and states = ref [Queued; next] in
    let read_operation () =
      calls := !calls @ ["operation"];
      match !states with
      | value :: rest -> states := rest; Ok (Some value)
      | [] -> fail "unexpected operation reread" in
    let read_journal () = calls := !calls @ ["journal"]; Ok [] in
    let observed, _, replay = Log.read_with_operation_state ~read_operation ~read_journal in
    check bool "terminal replay requires a terminal record" (is_terminal next)
      (replay = Log.Replayed_after_terminal);
    check bool "claim between reads is observed" true (observed = Ok (Some next));
    check (list string) "journal follows the newest operation observation"
      ["operation";"journal";"operation";"journal"] !calls)
    [Running {started_at=2.}; Succeeded {completed_at=3.;outcome_ref="result"}];
  List.iter (fun initial ->
    let terminal = Succeeded {completed_at=3.;outcome_ref="result"} in
    let states = ref [initial; terminal] in
    let first = [line 0 1.0 (E.Text_delta "retained partial output")] in
    let journals = ref [Ok first; Error Log.Journal_pruned] in
    let read_operation () = match !states with
      | x :: xs -> states := xs; Ok (Some x)
      | [] -> fail "unexpected extra operation read" in
    let read_journal () = match !journals with
      | x :: xs -> journals := xs; x
      | [] -> fail "unexpected extra journal read" in
    let observed, journal, replay = Log.read_with_operation_state ~read_operation ~read_journal in
    check bool "operation settling during the journal read is observed" true (observed = Ok (Some terminal));
    check bool "fallback page does not retire replay" true (replay = Log.Replay_pending);
    check bool "failed terminal reread preserves the first successful journal" true (journal = Ok first);
    check int "the terminal journal was retried" 0 (List.length !journals))
    [Queued; Running {started_at=2.}];
  let terminal = Failed {completed_at=3.;failure={kind=Interrupted_by_restart;
    detail="server restarted";outcome_ref=None}} in
  let observed, journal, replay = Log.read_with_operation_state
    ~read_operation:(fun () -> Ok (Some terminal))
    ~read_journal:(fun () -> Error Log.Journal_pruned) in
  check bool "failed post-terminal read remains eligible" true (replay = Log.Replay_pending);
  let _, _, success = Log.read_with_operation_state
    ~read_operation:(fun () -> Ok (Some terminal)) ~read_journal:(fun () -> Ok []) in
  check bool "successful post-terminal replay retires even an empty journal" true
    (success = Log.Replayed_after_terminal);
  check bool "journal absence cannot erase the exact failure" true
    (observed = Ok (Some terminal) && journal = Error Log.Journal_pruned)

let test_failed_operation_recheck_keeps_the_working_observation () =
  let open Keeper_chat_operation in
  List.iter (fun refreshed ->
    List.iter (fun initial ->
      let states = ref [Ok (Some initial); refreshed] in
      let first = [line 0 1.0 (E.Text_delta "retained working output")] in
      let reads = ref 0 in
      let read_operation () = match !states with
        | x :: xs -> states := xs; x
        | [] -> fail "unexpected operation read" in
      let read_journal () = incr reads; Ok first in
      let observed, journal, replay = Log.read_with_operation_state ~read_operation ~read_journal in
      check bool "failed operation recheck cannot retire replay" true (replay = Log.Replay_pending);
      check bool "failed refresh cannot erase the exact earlier observation" true
        (observed = Ok (Some initial));
      check bool "working output survives the failed refresh" true (journal = Ok first);
      check int "unavailable recheck does not refetch a successful journal" 1 !reads)
      [Queued; Running {started_at=2.}])
    [Error "operation endpoint temporarily unavailable"; Ok None]

let test_decode_exact_operation_state () =
  let body fields = `Assoc (["schema", `String "masc.keeper_chat_operation.v1";
    "operation_id", `String "exact"] @ fields) in
  let failed = ["state", `String "Failed"; "completed_at", `Float 4.;
    "failure_kind", `String "Turn_cancelled"; "failure_detail", `String "stopped"] in
  (match Log.decode_operation_state ~operation_id:"exact" (body failed) with
   | Ok (Keeper_chat_operation.Failed {completed_at; failure}) ->
       check (float 0.) "completion time" 4. completed_at;
       check string "failure reason" "stopped" failure.detail
   | _ -> fail "exact failed operation was not decoded");
  List.iter (fun json ->
    check bool "malformed or mismatched authority cannot settle a journal" true
      (Result.is_error (Log.decode_operation_state ~operation_id:"exact" json)))
    [ `Null; `Bool false; `List []; `String "not an operation"
    ; body ["state", `String "surprise"]
    ; body ["state", `String "Cancelled"; "completed_at", `Float nan]
    ; body ["state", `String "Failed"; "completed_at", `Float 4.]
    ; `Assoc ["schema", `String "masc.keeper_chat_operation.v1";
        "operation_id", `String "another"; "state", `String "Queued"] ]

let test_decode_events_page () =
  let lines =
    [ line 0 1.0 (E.Run_started { run_id = "r"; thread_id = "keeper:keeper.one" })
    ; line 1 1.5 (E.Text_delta "hello")
    ]
  in
  (match
     Log.decode_events_page
       (page_json ~next_since_offset:(`Int 212) ~has_more:true
          ~next_since_seq:(Journal.After_seq 1) lines)
   with
   | Ok page ->
       check string "operation id" "tui-req-1" (Log.source_key page.source);
       check int "two events" 2 (List.length page.events);
       check bool "has_more" true page.has_more;
       check position "cursor" (Journal.After_seq 1) page.next_since_seq;
       check int "byte cursor" 212
         (Journal.page_start_offset page.next_since_offset)
   | Error detail -> fail detail);
  (* The byte cursor is required and never negative: a page without it cannot
     be continued from where it ended. *)
  (match
     Log.decode_events_page
       (`Assoc
          [ "schema", `String "masc.keeper_chat_events.v2"
          ; "operation_id", `String "x"
          ; "events", `List []
          ; "has_more", `Bool false
          ; "next_since_seq", `Int 3
          ])
   with
   | Ok _ -> fail "a page without next_since_offset decoded"
   | Error detail ->
       check string "the missing byte cursor is named"
         "events body has no next_since_offset" detail);
  (match
     Log.decode_events_page
       (page_json ~next_since_offset:(`Int (-1)) ~has_more:false
          ~next_since_seq:(Journal.After_seq 3) [])
   with
   | Ok _ -> fail "a negative byte cursor decoded"
   | Error detail ->
       check string "the negative byte cursor is named"
         "events body's next_since_offset is not an integer >= 0" detail);
  (* An empty whole-journal page hands back null: the whole journal again. *)
  (match
     Log.decode_events_page
       (page_json ~has_more:false ~next_since_seq:Journal.Whole_turn [])
   with
   | Ok page -> check position "null cursor" Journal.Whole_turn page.next_since_seq
   | Error detail -> fail detail);
  (match
     Log.decode_events_page
       (page_json ~schema:"masc.keeper_chat_events.v1" ~has_more:false
          ~next_since_seq:(Journal.After_seq 0) lines)
   with
   | Ok _ -> fail "a wrong schema decoded"
   | Error _ -> ());
  (match
     Log.decode_events_page
       (`Assoc
          [ "schema", `String "masc.keeper_chat_events.v2"
          ; "operation_id", `String "x"
          ; "events", `List []
          ; "has_more", `Bool false
          ; "next_since_seq", `Int (-1)
          ; "next_since_offset", `Int 0
          ])
   with
   | Ok _ -> fail "a negative cursor decoded"
   | Error _ -> ());
  match
    Log.decode_events_page
      (`Assoc
         [ "schema", `String "masc.keeper_chat_events.v2"
         ; "operation_id", `String "x"
         ; "events", `List [ `Assoc [ "v", `Int 1; "seq", `Int 9 ] ]
         ; "has_more", `Bool false
         ; "next_since_seq", `Int 9
         ; "next_since_offset", `Int 0
         ])
  with
  | Ok _ -> fail "a malformed line decoded"
  | Error _ -> ()

(* What the fold hands back is what a projection has to apply: each taken
   line with its delta, at the line's own time. *)
let taken_to_tagged taken =
  List.map (fun ((l : Journal.journaled_event), d) -> ((l.seq, l.ts), d)) taken

let taken = list (pair (pair int (float 0.0)) delta)

let test_add_journaled_holds_undrawn_positions () =
  let t = log () in
  let first =
    Log.add_journaled t
      [ line 0 1.0 (E.Run_started { run_id = "r"; thread_id = "keeper:keeper.one" })
      ; line 1 1.1 (E.Text_message_start { message_id = "m"; role = E.Assistant })
      ; line 2 1.2 (E.Text_delta "hi")
      ]
  in
  check (list tagged) "start and delta are entries, message start is not"
    [ (Some 0, Live.Run_started); (Some 2, Live.Text "hi") ]
    (List.map (fun (entry : Log.entry) -> (entry.seq, entry.delta)) (Log.entries t));
  check taken "the fold hands back the taken lines with their deltas and times"
    [ ((0, 1.0), Live.Run_started); ((2, 1.2), Live.Text "hi") ]
    (taken_to_tagged first);
  check position "the undrawn seq still counts as held" (Journal.After_seq 2)
    (Log.resume_position t);
  check bool "a live frame for the undrawn seq is a duplicate" false
    (Log.add t ~seq:(Some 1) (Live.Text "late"));
  let before = Log.revision t in
  let again =
    Log.add_journaled t
      [ line 2 1.2 (E.Text_delta "hi"); line 3 1.3 E.Agent_core_stream_ping ]
  in
  check taken "a line already held and an undrawn line are not handed back" []
    (taken_to_tagged again);
  check position "an undrawn line moves the resume position" (Journal.After_seq 3)
    (Log.resume_position t);
  check int "but not the revision: nothing to redraw" before (Log.revision t)

(* ── Golden: journal vs wire ──────────────────────────────────────── *)

let occurrence : E.tool_stream_occurrence =
  { stream_scope = 0; provider_message_id = Some "pm-1"; block_index = 2 }

(* No provider correlation at all: the wire omits both optional keys and the
   live decoder reads their absence as None. *)
let occurrence_anon : E.tool_stream_occurrence =
  { stream_scope = 1; provider_message_id = None; block_index = 0 }

(* Every constructor the server projects to a frame the live view ignores, or
   to no frame at all, plus a tool trio without provider ids. Absent here:
   [Agent_core_media_delta] (no renderer draws its URL yet, TUI or dashboard)
   and [Event_error] (terminal; see [failed_turn]). *)
let golden : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-golden"; thread_id = "keeper:keeper.one" }
  ; E.Batch_bound
      { operation_id = (match Keeper_chat_operation.Operation_id.of_string "tui-req-1" with Ok id -> id | Error detail -> fail detail)
      ; execution_id = (match Keeper_chat_operation.Operation_id.of_string "batch-owner" with Ok id -> id | Error detail -> fail detail) }
  ; E.Agent_core_stream_connected
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-1"; model = "kimi-for-coding"; usage = None }
  ; E.Agent_core_content_block_start
      { index = 0; content_type = "thinking"; tool_call_id = None; tool_call_name = None }
  ; E.Text_message_start { message_id = "msg-1"; role = E.Assistant }
  ; E.Agent_core_thinking_delta { index = 0; delta = "weighing it" }
  ; E.Agent_core_thinking_signature_delta { index = 0; signature_bytes = 42 }
  ; E.Agent_core_content_block_stop { index = 0 }
  ; E.Agent_core_stream_ping
  ; E.Text_delta "Let me "
  ; E.Tool_call_start
      { occurrence = occurrence_anon; tool_call_id = None; tool_call_name = "grep" }
  ; E.Tool_call_args { occurrence = occurrence_anon; tool_call_id = None; delta = "{\"pat\":\"x\"}" }
  ; E.Tool_call_end { occurrence = occurrence_anon; tool_call_id = None }
  ; E.Link_block
      { url = "https://example.com"; title = "Example"; description = Some "desc"; image = None }
  ; E.Image_block { url = "https://example.com/i.png"; caption = None }
  ; E.Audio_block { token = "aud-1"; mime = "audio/ogg"; message_text = "hi"; duration_sec = None }
  ; E.Tool_context_block
      { tool_call_id = "tc-3"; name = "grep"; args_summary = "pat x"; result_summary = None }
  ; E.Tool_call_start { occurrence; tool_call_id = Some "tc-1"; tool_call_name = "read_file" }
  ; E.Tool_call_args { occurrence; tool_call_id = Some "tc-1"; delta = "{\"path\":" }
  ; E.Tool_call_args_snapshot { occurrence; tool_call_id = Some "tc-1"; snapshot = "{\"path\":\"a.ml\"}" }
  ; E.Tool_call_end { occurrence; tool_call_id = Some "tc-1" }
  ; E.Tool_result_ready
      { occurrence; tool_call_id = Some "tc-1"; execution_id = Ids.Execution_id.of_string "exec-1" }
  ; E.Agent_core_stream_protocol_error
      { kind = E.Tool_args_without_start
      ; quarantined_occurrence = Some occurrence
      ; index = Some 2
      ; tool_call_id = Some "tc-1"
      ; event_type = Some "content_block_delta"
      ; reason = Some "args before start"
      ; raw_bytes = Some 128
      }
  ; E.Tool_approval_requested
      { tool_call_id = "tc-2"; tool_call_name = "shell"; args = "{\"cmd\":\"ls\"}"
      ; question = "run it?"; because = "policy asks" }
  ; E.Tool_approval_settled { tool_call_id = "tc-2"; outcome = "allowed" }
  ; E.Status_block { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
  ; E.Continuation_checkpoint { message = "checkpoint"; request_id = Some "req-2" }
  ; E.Agent_core_runtime_attempt_started { runtime_id = Some "claude-3-7-sonnet"; attempt_index = Some 1 }
  ; E.Text_delta "look."
  ; E.External_effect_completed
      { target = Masc.Keeper_surface_post.Delivered_to_slack { channel_id = "C1"; thread_ts = None } }
  ; E.Reply_details
      { reply = "Let me look."
      ; turn_outcome = Outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:3
      }
  ; E.Text_message_end
  ; E.Agent_core_stream_message_delta { stop_reason = None; usage = None }
    (* Both facts the delta can carry, so the golden comparison says the
       journal and the wire read them the same way rather than agreeing on an
       event that carries nothing. *)
  ; E.Agent_core_stream_message_delta
      { stop_reason = Some Agent_core.Types.MaxTokens
      ; usage =
          Some
            { Agent_core.Types.input_tokens = Some 1200
            ; output_tokens = Some 340
            ; cache_creation_input_tokens = None
            ; cache_read_input_tokens = Some 900
            ; cost_usd = None
            }
      }
  ; E.Agent_core_stream_message_stop
  ; E.Run_finished { run_id = "run-golden" }
  ]

(* A turn the server ended with an error frame. *)
let failed_turn : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-failed"; thread_id = "keeper:keeper.one" }
  ; E.Text_message_start { message_id = "msg-2"; role = E.Assistant }
  ; E.Text_delta "partial"
  ; E.Text_message_end
  ; E.Event_error { message = "boom" }
  ]

let wire_tagged_deltas events =
  let _, body =
    List.fold_left
      (fun (projection, acc) (seq, event) ->
         let projection, projected =
           Projection.project ~timestamp:(1000.0 +. float_of_int seq)
             ~redact_text:Fun.id ~redact_json:Fun.id projection event
         in
         ( projection
         , match projected with
           | Some ag_event -> acc ^ Ag_ui.event_to_sse ~id:seq ag_event
           | None -> acc ))
      (Projection.initial, "")
      events
  in
  let decoder = Live.create () in
  feed decoder body

let journal_tagged_deltas events =
  List.filter_map
    (fun (seq, event) -> Option.map (fun d -> (Some seq, d)) (Log.delta_of_journaled event))
    events

let test_wire_timestamps_match_journal_and_survive_reconnect () =
  let started_at = 1791363124.206972 in
  let text_at = 1791363124.709321 in
  let lines =
    [ line 0 started_at
        (E.Run_started { run_id = "run-timed"; thread_id = "keeper:keeper.one" })
    ; line 1 (started_at +. 0.1)
        (E.Text_message_start { message_id = "message-timed"; role = E.Assistant })
    ; line 2 text_at (E.Text_delta "timed reply")
    ]
  in
  let _, body =
    List.fold_left
      (fun (projection, body) (event : Journal.journaled_event) ->
        let projection, projected =
          Projection.project ~timestamp:event.ts ~redact_text:Fun.id
            ~redact_json:Fun.id projection event.event
        in
        ( projection
        , body
          ^ Option.fold ~none:""
              ~some:(Ag_ui.event_to_sse ~id:event.seq) projected ))
      (Projection.initial, "") lines
  in
  let from_wire = log () in
  let receive () =
    Live.feed (Live.create ()) body
    |> List.map (fun (item : Live.observed_delta) ->
           Log.add ?at:item.at from_wire ~seq:item.seq item.delta)
  in
  check (list bool) "the first stream contributes two visible events"
    [ true; true ] (receive ());
  let from_journal = log () in
  ignore (Log.add_journaled from_journal lines);
  let entries log =
    Log.entries log
    |> List.map (fun (entry : Log.entry) ->
           ((entry.seq, entry.at), entry.delta))
  in
  let observed = list (pair (pair (option int) (option (float 0.000001))) delta) in
  let expected =
    [ ((Some 0, Some started_at), Live.Run_started)
    ; ((Some 2, Some text_at), Live.Text "timed reply")
    ]
  in
  check observed "wire keeps the producer's fractional epoch seconds"
    expected (entries from_wire);
  check observed "journal replay uses identical event times"
    expected (entries from_journal);
  let revision = Log.revision from_wire in
  check (list bool) "a reconnected stream contributes no repeated events"
    [ false; false ] (receive ());
  check observed "reconnect preserves the original event times"
    expected (entries from_wire);
  check int "duplicate replay does not revise the log"
    revision (Log.revision from_wire)

let events_error =
  testable (Fmt.of_to_string Log.events_error_to_string) ( = )

let envelope ?(schema = "masc.keeper_chat_operation.error.v1") code message =
  Yojson.Safe.to_string
    (`Assoc
      [ "schema", `String schema; "error", `String code; "message", `String message ])
;;

(* The code decides; the message rides along only where the code alone does
   not say what to do. *)
let test_decode_events_error_by_code () =
  let decode ~status body = Log.decode_events_error ~status ~credential_sent:true body in
  check events_error "404 unknown_operation" Log.Unknown_operation
    (decode ~status:404 (envelope "unknown_operation" "no such op"));
  check events_error "410 journal_pruned" Log.Journal_pruned
    (decode ~status:410 (envelope "journal_pruned" "gone"));
  check events_error "503 journal_unreadable keeps the message"
    (Log.Journal_unavailable "disk says no")
    (decode ~status:503 (envelope "journal_unreadable" "disk says no"));
  check events_error "503 journal_corrupt keeps the message"
    (Log.Journal_unavailable "bad line 7")
    (decode ~status:503 (envelope "journal_corrupt" "bad line 7"));
  check events_error "an unknown code is undecodable with the status and message"
    (Log.Events_undecodable "400 operation_id is required")
    (decode ~status:400 (envelope "invalid_input" "operation_id is required"));
  (* The three cursor codes are the journal's own; the pane is told the read's
     positions no longer place, not that the body was unreadable. *)
  List.iter
    (fun refusal ->
       let code = Journal.cursor_refusal_to_wire refusal in
       check events_error
         ("400 " ^ code ^ " is a typed cursor refusal")
         (Log.Cursor_refused { refusal; message = "cursor says no" })
         (decode ~status:400 (envelope code "cursor says no")))
    [ Journal.Offset_past_rows; Journal.Offset_inside_row; Journal.Cursor_pair_mismatch ];
  check events_error "a body that is not JSON is undecodable as it came"
    (Log.Events_undecodable "502 <html>bad gateway</html>")
    (decode ~status:502 "<html>bad gateway</html>");
  check events_error "an object with no error code is undecodable"
    (Log.Events_undecodable "500 {\"oops\":true}")
    (decode ~status:500 "{\"oops\":true}");
  (* A 401/403 that names an auth code is about the credential. *)
  check events_error "401 is a refusal"
    (Log.Events_refused
       (Masc_tui_credential.refusal ~credential_sent:true
          Masc_tui_credential.Rejected))
    (decode ~status:401 {|{"error":"[AuthError] Invalid token","auth_error_code":"invalid_token"}|});
  check events_error "401 with an expired code says so"
    (Log.Events_refused
       (Masc_tui_credential.refusal ~credential_sent:true
          Masc_tui_credential.Expired))
    (decode ~status:401 {|{"error":"expired","auth_error_code":"token_expired"}|});
  check events_error "403 without a bearer names the missing credential"
    (Log.Events_refused
       (Masc_tui_credential.refusal ~credential_sent:false
          Masc_tui_credential.Rejected))
    (Log.decode_events_error ~status:403 ~credential_sent:false
       {|{"error":"[AuthError] Unauthorized","auth_error_code":"missing_token"}|});
  (* One without a code is the handler's own answer and is read like any
     other refusal, not sent to masc login. *)
  check events_error "403 without an auth code keeps the server's words"
    (Log.Events_denied "403 not yours")
    (decode ~status:403 (envelope "not_owner" "not yours"))
;;

(* The request the pager sends: both cursors in their request spelling, each
   absent for its own start. The executable's HTTP module cannot be linked by
   a test, so the query it sends is built here, where this can hold it: a
   dropped or misspelled cursor would still read correctly, one whole prefix
   decoded per page on the server, with nothing else to fail. *)
let test_events_query_spells_both_cursors () =
  let query ~since_seq ~since_offset =
    Log.events_query ~encode_value:(fun value -> value ^ "%20") ~operation_id:"op 1"
      ~since_seq ~since_offset ~limit:2000
  in
  let offset value =
    match Journal.page_start_of_wire (Some value) with
    | Some start -> start
    | None -> failf "offset %d is not a cursor" value
  in
  check string "the first page names neither cursor"
    "operation_id=op 1%20&limit=2000"
    (query ~since_seq:Journal.Whole_turn ~since_offset:Journal.first_row);
  check string "a resumed read names the seq it holds"
    "operation_id=op 1%20&since_seq=7&limit=2000"
    (query ~since_seq:(Journal.After_seq 7) ~since_offset:Journal.first_row);
  check string "a later page names both cursors"
    "operation_id=op 1%20&since_seq=7&since_offset=212&limit=2000"
    (query ~since_seq:(Journal.After_seq 7) ~since_offset:(offset 212))
;;

(* The pager follows has_more only while both cursors advance, starts where
   it is told from the first row, asks every later page from the byte offset
   the page before handed back, and stops at the first error. *)
let test_read_whole_journal_pages_until_the_position_stops_moving () =
  let asked = ref [] in
  let l seq = line seq (float_of_int seq) (E.Text_delta (string_of_int seq)) in
  let offset value =
    match Journal.page_start_of_wire (Some value) with
    | Some start -> start
    | None -> failf "offset %d is not a cursor" value
  in
  let page ~events ~has_more ~next_since_seq ~next_since_offset =
    Ok
      { Log.source = Log.Operation "op"
      ; events
      ; has_more
      ; next_since_seq
      ; next_since_offset = offset next_since_offset
      }
  in
  let page_of (since_seq : Journal.replay_position)
      (since_offset : Journal.page_start) =
    asked := (since_seq, Journal.page_start_to_wire since_offset) :: !asked;
    match since_seq, since_offset with
    | Journal.Whole_turn, Journal.From_first_row ->
        page ~events:[ l 0; l 1 ] ~has_more:true ~next_since_seq:(Journal.After_seq 1)
          ~next_since_offset:20
    | Journal.After_seq 1, (Journal.From_first_row | Journal.From_offset 20) ->
        page ~events:[ l 2 ] ~has_more:true ~next_since_seq:(Journal.After_seq 2)
          ~next_since_offset:30
    | Journal.After_seq 2, Journal.From_offset 30 ->
        page ~events:[] ~has_more:false ~next_since_seq:(Journal.After_seq 2)
          ~next_since_offset:30
    | (Journal.Whole_turn | Journal.After_seq _),
      (Journal.From_first_row | Journal.From_offset _) ->
        Error (Log.Events_transport "unexpected page")
  in
  let asked_list = list (pair position (option int)) in
  (match
     Log.read_whole_journal ~since_seq:Journal.Whole_turn
       ~fetch:(fun ~since_seq ~since_offset -> page_of since_seq since_offset)
   with
   | Ok lines ->
       check (list int) "every line once, in order" [ 0; 1; 2 ]
         (List.map (fun (l : Journal.journaled_event) -> l.seq) lines)
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  check asked_list
    "each page asked once: the first from the first row, the rest from the offset handed back"
    [ Journal.Whole_turn, None; Journal.After_seq 1, Some 20; Journal.After_seq 2, Some 30 ]
    (List.rev !asked);
  (* A resume starts where the log ends, from the first row. *)
  asked := [];
  (match
     Log.read_whole_journal ~since_seq:(Journal.After_seq 1)
       ~fetch:(fun ~since_seq ~since_offset -> page_of since_seq since_offset)
   with
   | Ok lines -> check int "only what the log lacks" 1 (List.length lines)
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  check asked_list "asked from the resume position"
    [ Journal.After_seq 1, None; Journal.After_seq 2, Some 30 ]
    (List.rev !asked);
  (* A page that claims more without advancing is an error naming the
     positions, asked once: the lines read so far are not the journal, and a
     shorter [Ok] would have the handler hold a truncated turn as the record
     and say nothing. The whole journal is never past anything, so a null
     cursor is stuck too. *)
  asked := [];
  let stuck ~since_seq ~since_offset =
    asked := (since_seq, Journal.page_start_to_wire since_offset) :: !asked;
    page ~events:[ line 0 1.0 (E.Text_delta "0") ] ~has_more:true ~next_since_seq:since_seq
      ~next_since_offset:(Journal.page_start_offset since_offset)
  in
  (match Log.read_whole_journal ~since_seq:Journal.Whole_turn ~fetch:stuck with
   | Ok lines -> failf "a stuck page read as %d line(s)" (List.length lines)
   | Error (Log.Events_undecodable detail) ->
       check string "the error names the positions that did not advance"
         "page after since_seq=whole_turn since_offset=0 claims more but did not \
          advance (next_since_seq=whole_turn next_since_offset=0)"
         detail
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  check asked_list "the stuck page is asked once" [ Journal.Whole_turn, None ]
    (List.rev !asked);
  (match Log.read_whole_journal ~since_seq:(Journal.After_seq 4) ~fetch:stuck with
   | Ok lines -> failf "a stuck page after a held seq read as %d line(s)" (List.length lines)
   | Error (Log.Events_undecodable detail) ->
       check string "the error names the held seq that did not advance"
         "page after since_seq=4 since_offset=0 claims more but did not advance \
          (next_since_seq=4 next_since_offset=0)"
         detail
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  (* A seq that moves is not enough: a byte cursor that stays would have the
     server decode the same rows again for every page. *)
  let offset_stuck ~since_seq:_ ~since_offset =
    page ~events:[ l 0 ] ~has_more:true ~next_since_seq:(Journal.After_seq 0)
      ~next_since_offset:(Journal.page_start_offset since_offset)
  in
  (match Log.read_whole_journal ~since_seq:Journal.Whole_turn ~fetch:offset_stuck with
   | Ok lines -> failf "a page whose offset stayed read as %d line(s)" (List.length lines)
   | Error (Log.Events_undecodable detail) ->
       check string "the error names the offset that did not advance"
         "page after since_seq=whole_turn since_offset=0 claims more but did not \
          advance (next_since_seq=0 next_since_offset=0)"
         detail
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  (* An error ends the read as that error. *)
  let failing ~since_seq ~since_offset:_ =
    match since_seq with
    | Journal.Whole_turn ->
        page ~events:[] ~has_more:true ~next_since_seq:(Journal.After_seq 5)
          ~next_since_offset:40
    | Journal.After_seq _ -> Error Log.Journal_pruned
  in
  check bool "the first error is the result" true
    (match Log.read_whole_journal ~since_seq:Journal.Whole_turn ~fetch:failing with
     | Error Log.Journal_pruned -> true
     | Ok _ | Error _ -> false)
;;

let test_hold_seq_counts_without_an_entry () =
  let log = Log.create ~keeper_name:"k" ~request_id:"r" ~started_at:0. in
  Log.hold_seq log 4;
  check position "a held position moves the resume position" (Journal.After_seq 4)
    (Log.resume_position log);
  check int "and adds no entry" 0 (List.length (Log.entries log));
  check bool "a frame arriving at a held position is a duplicate" false
    (Log.add log ~seq:(Some 4) Live.Run_started);
  let revision = Log.revision log in
  Log.hold_seq log 4;
  check int "holding again changes nothing" revision (Log.revision log)
;;

let test_golden_journal_equals_wire () =
  let events = List.mapi (fun seq event -> (seq, event)) golden in
  let wire = wire_tagged_deltas events in
  let journal = journal_tagged_deltas events in
  check bool "the fixture exercises the log" true (List.length journal > 10);
  check (list tagged) "journal decode equals the live wire decode" wire journal;
  let failed = List.mapi (fun seq event -> (seq, event)) failed_turn in
  check (list tagged) "a failed turn decodes the same on both sides"
    (wire_tagged_deltas failed) (journal_tagged_deltas failed);
  check bool "the failed turn ends in run_failed" true
    (match List.rev (journal_tagged_deltas failed) with
     | (Some 4, Live.Run_failed { message = "boom" }) :: _ -> true
     | _ -> false)

let test_golden_journal_equals_wire_in_chunks () =
  let events = List.mapi (fun seq event -> (seq, event)) golden in
  let whole = wire_tagged_deltas events in
  (* The same bytes cut at every 1..13 byte boundary read the same. *)
  let body =
    let _, body =
      List.fold_left
        (fun (projection, acc) (seq, event) ->
           let projection, projected =
             Projection.project ~timestamp:(1000.0 +. float_of_int seq)
               ~redact_text:Fun.id ~redact_json:Fun.id projection event
           in
           ( projection
           , match projected with
             | Some ag_event -> acc ^ Ag_ui.event_to_sse ~id:seq ag_event
             | None -> acc ))
        (Projection.initial, "")
        events
    in
    body
  in
  List.iter
    (fun size ->
      let decoder = Live.create () in
      let length = String.length body in
      let rec loop offset acc =
        if offset >= length then List.rev acc
        else
          let take = min size (length - offset) in
          loop (offset + take)
            (List.rev_append (feed decoder (String.sub body offset take)) acc)
      in
      check (list tagged) (Printf.sprintf "%d-byte chunks" size) whole (loop 0 []))
    [ 1; 5; 13 ]

let test_a_journal_page_fills_the_log_like_the_wire_does () =
  let events = List.mapi (fun seq event -> (seq, event)) golden in
  let from_wire = log () in
  List.iter
    (fun (seq, d) -> ignore (Log.add from_wire ~seq d : bool))
    (wire_tagged_deltas events);
  let from_journal = log () in
  let taken_from_journal =
    Log.add_journaled from_journal
      (List.map (fun (seq, event) -> line seq (1000.0 +. float_of_int seq) event) events)
  in
  let view t = List.map (fun (entry : Log.entry) -> (entry.seq, entry.delta)) (Log.entries t) in
  check (list tagged) "same entries" (view from_wire) (view from_journal);
  check (list tagged) "the fold hands back exactly the wire's deltas"
    (wire_tagged_deltas events)
    (List.map (fun ((l : Journal.journaled_event), d) -> (Some l.seq, d)) taken_from_journal);
  (* The journal holds every line's seq; the wire holds only the seqs of
     frames that drew something. The fixture ends with two undrawn
     bookkeeping events and then Run_finished, so the two agree here; a turn
     whose last frames draw nothing would leave the journal-fed log ahead. *)
  check position "same resume position when the turn ends in a drawn event"
    (Log.resume_position from_wire) (Log.resume_position from_journal);
  let trailing_undrawn = golden @ [ E.Agent_core_stream_ping; E.Agent_core_stream_ping ] in
  let events = List.mapi (fun seq event -> (seq, event)) trailing_undrawn in
  let from_journal = log () in
  let taken_with_trailing =
    Log.add_journaled from_journal
      (List.map (fun (seq, event) -> line seq (1000.0 +. float_of_int seq) event) events)
  in
  check int "the trailing undrawn frames hand nothing more back"
    (List.length taken_from_journal) (List.length taken_with_trailing);
  let from_wire = log () in
  List.iter (fun (seq, d) -> ignore (Log.add from_wire ~seq d : bool)) (wire_tagged_deltas events);
  check position "the journal-fed log is ahead by the trailing undrawn frames"
    (Journal.After_seq (List.length golden + 1)) (Log.resume_position from_journal);
  check position "the wire-fed log stops at the last drawn frame"
    (Journal.After_seq (List.length golden - 1)) (Log.resume_position from_wire);
  check int "same attempt" (Log.attempt from_wire) (Log.attempt from_journal);
  check bool "the wire's attempt advanced past the retry" true (Log.attempt from_wire = 1)

(* A reason that is only whitespace is not a reason. The live arm drops it
   rather than drawing [stopped: ] with nothing after it, so the replay arm
   drops it too: a reloaded turn and a watched one have to say the same thing
   about the same bytes. Asked here of [delta_of_journaled] directly, because
   the golden journal never carries a blank reason -- without these two the
   trim could go back to a plain [Option.map] and every other case in this
   file would still pass. *)
let test_a_blank_reason_is_not_a_reason () =
  let delta stop_reason usage =
    Log.delta_of_journaled (E.Agent_core_stream_message_delta { stop_reason; usage })
  in
  (match delta (Some (Agent_core.Types.Unknown "")) None with
   | None -> ()
   | Some other ->
       failf "a delta whose only fact was a blank reason became a row: %s"
         (delta_to_string other));
  match
    delta
      (Some (Agent_core.Types.Unknown "  "))
      (Some
         { Agent_core.Types.input_tokens = Some 7
         ; output_tokens = None
         ; cache_creation_input_tokens = None
         ; cache_read_input_tokens = None
         ; cost_usd = None
         })
  with
  | Some (Live.Stream_details { usage = Some usage; stop_reason = None }) ->
      check (option int) "the counters the same delta carried are kept" (Some 7)
        usage.Live.input_tokens
  | other ->
      failf "a blank reason survived beside the counters: %s"
        (match other with None -> "no row" | Some delta -> delta_to_string delta)

let test_response_boundaries_and_usage_survive_wire_and_replay () =
  let module T = Masc_tui_keeper_chat_transcript in
  let module Bridge = Masc.Keeper_chat_agent_core_stream_bridge in
  let module Accum = Masc.Keeper_stream_tool_accum in
  List.iter (fun (provider_id, next_model) ->
    let initial = {Agent_core.Types.zero_api_usage with input_tokens=500;
      cache_read_input_tokens=100} in
    let next_initial = {Agent_core.Types.zero_api_usage with input_tokens=200} in
    let start model usage = Agent_core.Types.MessageStart
        {id=provider_id;model;usage=Some usage} in
    let sparse output = Agent_core.Types.MessageDelta
        {stop_reason=None;usage=Some {input_tokens=None;output_tokens=Some output;
          cache_read_input_tokens=None;cache_creation_input_tokens=None;
          cost_usd=None}} in
    let bridge = ref (Bridge.empty_state ()) in
    let accum = Accum.create () in
    let reversed = ref [] in
    let publish event = reversed := event :: !reversed in
    let send event =
      Accum.on_event accum event;
      let translated = Bridge.translate ~redact_text:Fun.id ~base_dir:"/unused-no-media"
        ~stream_scope:(Accum.current_stream_scope accum) !bridge event in
      bridge := translated.bridge_state;
      List.iter publish translated.chat_events in
    let snapshots () =
      let indexed = List.mapi (fun seq event -> seq,event) (List.rev !reversed) in
      let wire = log () and replay = log () in
      wire_tagged_deltas indexed |> List.iter (fun (seq,delta) ->
        ignore (Log.add ~at:1000. wire ~seq delta));
      let journal = List.map (fun (seq,event) -> line seq 1000. event) indexed in
      ignore (Log.add_journaled replay journal);
      wire,replay,journal in
    let tokens log = T.stream_tokens_text ~keeper_name:"keeper.one"
      (Some (T.of_log ~now:2000. log)) in
    publish (E.Run_started {run_id="run";thread_id="keeper:keeper.one"});
    publish (E.Text_message_start {message_id="outer";role=E.Assistant});
    List.iter send Agent_core.Types.[start "observed" initial;
      ContentBlockDelta {index=0;delta=TextDelta "EARLIER_RESPONSE"};
      sparse 7;start "observed" initial];
    let wire,replay,_ = snapshots () in
    List.iter (fun log ->
      check (option string) "exact open-scope replay cannot erase delta usage"
        (Some "tokens: in 500 · out 7 · cache read 100 · cache write 0")
        (tokens log)) [wire;replay];
    List.iter send Agent_core.Types.[
      MessageDelta {stop_reason=Some StopToolUse;usage=None};MessageStop];
    (match Accum.close_turn_without_sources accum ~turn:0 with
     | Ok () -> () | Error detail -> fail detail);
    send (start next_model next_initial);
    let wire,replay,_ = snapshots () in
    List.iter (fun log ->
      check (option string) "new response initial counters arrive before any delta"
        (Some "tokens: in 200 · out 0 · cache read 0 · cache write 0") (tokens log);
      if next_model = "" then
        check string "only the absent model label is unavailable"
          "configured: configured-model"
          (T.runtime_identity_text ~keeper_name:"keeper.one"
             ~configured_runtime:"configured-model" (Some (T.of_log ~now:2000. log)))) [wire;replay];
    List.iter send Agent_core.Types.[
      ContentBlockDelta {index=0;delta=TextDelta "PREFIX"};
      ContentBlockDelta {index=1;delta=ThinkingDelta "REASONING"};
      sparse 9;start next_model next_initial;
      ContentBlockDelta {index=2;delta=TextDelta "SUFFIX"};MessageStop];
    let turn_ref = Ids.Turn_ref.make ~trace_id:"trace" ~absolute_turn:1 in
    publish (E.Reply_details {reply="PREFIX\nSUFFIX";turn_outcome=Outcome.Visible_reply;turn_ref});
    publish (E.Run_finished {run_id="run"});
    check int "each new sealed scope publishes one start, even with a reused or absent id" 2
      (List.length (List.filter (function E.Agent_core_stream_message_start _ -> true | _ -> false) !reversed));
    let wire,replay,journal = snapshots () in
    let projected log =
      let t = T.of_log ~now:2000. log in
      let speech = T.drawn t |> List.filter_map (fun (item:T.drawn_item) ->
        match item.drawn with Drawn_text text | Drawn_reply text -> Some text | _ -> None) in
      check (list string) "earlier response and observed stretches stay in place"
        ["EARLIER_RESPONSE";"PREFIX";"SUFFIX";"PREFIX\nSUFFIX"] speech;
      check bool "canonical authority is separate from observed interleaving" true
        (match List.rev (T.drawn t) with
         | {response_part=Some T.Final_response;origin=T.Reply_of_segment 0;_} :: _ -> true
         | _ -> false);
      check (option string) "same provider id in a later sealed scope starts fresh usage"
        (Some "tokens: in 200 · out 9 · cache read 0 · cache write 0") (tokens log);
      check (option string) "later response has usage without the preceding stop reason"
        (T.stream_tokens_text ~keeper_name:"keeper.one" (Some t))
        (T.stream_details_text ~keeper_name:"keeper.one" (Some t));
      T.drawn t in
    let wire_items = projected wire and replay_items = projected replay in
    check bool "wire and replay agree on content and stable origins" true
      (wire_items = replay_items);
    ignore (Log.add_journaled replay journal);
    check bool "overlapping replay leaves origins and content unchanged" true
      (replay_items = projected replay))
    ["reused-provider-id", "observed"; "", "observed";
     "reused-provider-id", ""; "", ""]
;;

let test_conflicting_provider_start_cannot_open_a_response () =
  let module Bridge = Masc.Keeper_chat_agent_core_stream_bridge in
  let initial = {Agent_core.Types.zero_api_usage with input_tokens=500} in
  let conflicting = {initial with input_tokens=900} in
  let _, events = List.fold_left (fun (state,events) event ->
    let translated = Bridge.translate ~redact_text:Fun.id ~base_dir:"/unused-no-media"
      ~stream_scope:0 state event in
    translated.bridge_state, events @ translated.chat_events)
    (Bridge.empty_state (), []) Agent_core.Types.[
      MessageStart {id="same";model="observed";usage=Some initial};
      ContentBlockDelta {index=0;delta=TextDelta "still first response"};
      MessageStart {id="same";model="observed";usage=Some conflicting}] in
  check int "rejected start is not published as a new response" 1
    (List.length (List.filter (function E.Agent_core_stream_message_start _ -> true | _ -> false) events));
  check bool "the protocol conflict remains observable" true
    (List.exists (function
       | E.Agent_core_stream_protocol_error {kind=E.Tool_message_start_conflict;_} -> true
       | _ -> false) events)
;;

let () =
  run "tui keeper chat log"
    [ ( "response windows", [test_case "wire/replay boundaries and usage" `Quick test_response_boundaries_and_usage_survive_wire_and_replay; test_case "conflicting start is not a response" `Quick test_conflicting_provider_start_cannot_open_a_response])
    ; ( "log"
      , [ test_case "seq dedup, and None never dedupes" `Quick
            test_seq_dedup_and_none_never_dedupes
        ; test_case "last seq follows the highest held" `Quick
            test_resume_position_follows_the_highest_held
        ; test_case "attempt advances on runtime attempt started" `Quick
            test_attempt_advances_on_runtime_attempt_started
        ; test_case "commit is idempotent and bumps once" `Quick
            test_commit_is_idempotent_and_bumps_once
        ; test_case "a blank reason is not a reason" `Quick
            test_a_blank_reason_is_not_a_reason
        ] )
    ; ( "v2 page"
      , [ test_case "failed operation recheck retains observed state" `Quick
            test_failed_operation_recheck_keeps_the_working_observation
        ; test_case "operation and journal observation order" `Quick test_operation_and_journal_read_order
        ; test_case "decode exact operation state" `Quick test_decode_exact_operation_state
        ; test_case "decode events page" `Quick test_decode_events_page
        ; test_case "add_journaled holds undrawn positions" `Quick
            test_add_journaled_holds_undrawn_positions
        ; test_case "decode events error by code" `Quick
            test_decode_events_error_by_code
        ; test_case "hold_seq counts without an entry" `Quick
            test_hold_seq_counts_without_an_entry
        ; test_case "the events query spells both cursors" `Quick
            test_events_query_spells_both_cursors
        ; test_case "read_whole_journal pages until the position stops moving" `Quick
            test_read_whole_journal_pages_until_the_position_stops_moving
        ] )
    ; ( "golden"
      , [ test_case "journal equals wire" `Quick test_golden_journal_equals_wire
        ; test_case "wire timestamps match journal and survive reconnect" `Quick
            test_wire_timestamps_match_journal_and_survive_reconnect
        ; test_case "journal equals wire in chunks" `Quick
            test_golden_journal_equals_wire_in_chunks
        ; test_case "a journal page fills the log like the wire does" `Quick
            test_a_journal_page_fills_the_log_like_the_wire_does
        ] )
    ]
