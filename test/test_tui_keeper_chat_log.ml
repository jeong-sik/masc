(* RFC-0412 stage 3a — the per-operation event log behind the keeper chat
   pane. Seq dedup, the attempt counter, the committed flag and revision, the
   v2 page decoder, and the golden case: a journal decoded through
   [delta_of_journaled] equals the same journal projected by the server to
   AG-UI, encoded as SSE, and read by the live decoder. *)

open Alcotest
module Live = Masc_tui_keeper_chat_live
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

let delta_to_string : Live.delta -> string = function
  | Live.Run_started -> "run_started"
  | Live.Runtime_attempt_started -> "runtime_attempt_started"
  | Live.Text text -> "text(" ^ text ^ ")"
  | Live.Thinking text -> "thinking(" ^ text ^ ")"
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
  | Live.Accepted { admission; queue_length } ->
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
  check bool "an id-less delta is added" true (Log.add t ~seq:None (Live.Accepted { admission = Live.Running; queue_length = 1 }));
  check bool "and again: None never dedupes" true (Log.add t ~seq:None (Live.Accepted { admission = Live.Running; queue_length = 1 }));
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
  ignore (Log.add t ~seq:(Some 2) Live.Runtime_attempt_started : bool);
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

let page_json ?(schema = "masc.keeper_chat_events.v2") ~has_more ~next_since_seq lines =
  `Assoc
    [ "schema", `String schema
    ; "operation_id", `String "tui-req-1"
    ; "events", `List (List.map Journal.journaled_event_to_json lines)
    ; "has_more", `Bool has_more
    ; "next_since_seq", Journal.replay_position_to_yojson next_since_seq
    ]

let test_decode_events_page () =
  let lines =
    [ line 0 1.0 (E.Run_started { run_id = "r"; thread_id = "keeper:keeper.one" })
    ; line 1 1.5 (E.Text_delta "hello")
    ]
  in
  (match
     Log.decode_events_page
       (page_json ~has_more:true ~next_since_seq:(Journal.After_seq 1) lines)
   with
   | Ok page ->
       check string "operation id" "tui-req-1" page.operation_id;
       check int "two events" 2 (List.length page.events);
       check bool "has_more" true page.has_more;
       check position "cursor" (Journal.After_seq 1) page.next_since_seq
   | Error detail -> fail detail);
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
   [Agent_core_media_delta] (its source kind lives in agent_core, which this
   test does not link) and [Event_error] (terminal; see [failed_turn]). *)
let golden : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-golden"; thread_id = "keeper:keeper.one" }
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
  ; E.Agent_core_runtime_attempt_started
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
  Live.feed decoder body

let journal_tagged_deltas events =
  List.filter_map
    (fun (seq, event) -> Option.map (fun d -> (Some seq, d)) (Log.delta_of_journaled event))
    events

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
  check events_error "a body that is not JSON is undecodable as it came"
    (Log.Events_undecodable "502 <html>bad gateway</html>")
    (decode ~status:502 "<html>bad gateway</html>");
  check events_error "an object with no error code is undecodable"
    (Log.Events_undecodable "500 {\"oops\":true}")
    (decode ~status:500 "{\"oops\":true}");
  (* A 401/403 is about the credential, whatever the body says. *)
  check events_error "401 is a refusal"
    (Log.Events_refused (Masc_tui_credential.refusal ~credential_sent:true))
    (decode ~status:401 (envelope "unauthorized" "bad token"));
  check events_error "403 without a bearer names the missing credential"
    (Log.Events_refused (Masc_tui_credential.refusal ~credential_sent:false))
    (Log.decode_events_error ~status:403 ~credential_sent:false "forbidden")
;;

(* The pager follows has_more only while the position advances, starts where
   it is told, and stops at the first error. *)
let test_read_whole_journal_pages_until_the_position_stops_moving () =
  let asked = ref [] in
  let page_of (since_seq : Journal.replay_position) =
    asked := since_seq :: !asked;
    let l seq = line seq (float_of_int seq) (E.Text_delta (string_of_int seq)) in
    match since_seq with
    | Journal.Whole_turn ->
        Ok { Log.operation_id = "op"; events = [ l 0; l 1 ]; has_more = true
           ; next_since_seq = Journal.After_seq 1 }
    | Journal.After_seq 1 ->
        Ok { Log.operation_id = "op"; events = [ l 2 ]; has_more = true
           ; next_since_seq = Journal.After_seq 2 }
    | Journal.After_seq 2 ->
        Ok { Log.operation_id = "op"; events = []; has_more = false
           ; next_since_seq = Journal.After_seq 2 }
    | Journal.After_seq _ -> Error (Log.Events_transport "unexpected page")
  in
  (match
     Log.read_whole_journal ~since_seq:Journal.Whole_turn
       ~fetch:(fun ~since_seq -> page_of since_seq)
   with
   | Ok lines ->
       check (list int) "every line once, in order" [ 0; 1; 2 ]
         (List.map (fun (l : Journal.journaled_event) -> l.seq) lines)
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  check (list position) "each page asked once, from the whole journal"
    [ Journal.Whole_turn; Journal.After_seq 1; Journal.After_seq 2 ]
    (List.rev !asked);
  (* A resume starts where the log ends. *)
  asked := [];
  (match
     Log.read_whole_journal ~since_seq:(Journal.After_seq 1)
       ~fetch:(fun ~since_seq -> page_of since_seq)
   with
   | Ok lines -> check int "only what the log lacks" 1 (List.length lines)
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  check (list position) "asked from the resume position"
    [ Journal.After_seq 1; Journal.After_seq 2 ]
    (List.rev !asked);
  (* A page that claims more without advancing is an error naming the
     position, asked once: the lines read so far are not the journal, and a
     shorter [Ok] would have the handler hold a truncated turn as the record
     and say nothing. The whole journal is never past anything, so a null
     cursor is stuck too. *)
  asked := [];
  let stuck ~since_seq =
    asked := since_seq :: !asked;
    Ok { Log.operation_id = "op"; events = [ line 0 1.0 (E.Text_delta "0") ]
       ; has_more = true; next_since_seq = since_seq }
  in
  (match Log.read_whole_journal ~since_seq:Journal.Whole_turn ~fetch:stuck with
   | Ok lines -> failf "a stuck page read as %d line(s)" (List.length lines)
   | Error (Log.Events_undecodable detail) ->
       check string "the error names the position that did not advance"
         "page after since_seq=whole_turn claims more but did not advance \
          (next_since_seq=whole_turn)"
         detail
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  check (list position) "the stuck page is asked once" [ Journal.Whole_turn ]
    (List.rev !asked);
  (match Log.read_whole_journal ~since_seq:(Journal.After_seq 4) ~fetch:stuck with
   | Ok lines -> failf "a stuck page after a held seq read as %d line(s)" (List.length lines)
   | Error (Log.Events_undecodable detail) ->
       check string "the error names the held seq that did not advance"
         "page after since_seq=4 claims more but did not advance (next_since_seq=4)"
         detail
   | Error error -> failf "unexpected %s" (Log.events_error_to_string error));
  (* An error ends the read as that error. *)
  let failing ~since_seq =
    match since_seq with
    | Journal.Whole_turn ->
        Ok { Log.operation_id = "op"; events = []; has_more = true
           ; next_since_seq = Journal.After_seq 5 }
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
            (List.rev_append (Live.feed decoder (String.sub body offset take)) acc)
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

let () =
  run "tui keeper chat log"
    [ ( "log"
      , [ test_case "seq dedup, and None never dedupes" `Quick
            test_seq_dedup_and_none_never_dedupes
        ; test_case "last seq follows the highest held" `Quick
            test_resume_position_follows_the_highest_held
        ; test_case "attempt advances on runtime attempt started" `Quick
            test_attempt_advances_on_runtime_attempt_started
        ; test_case "commit is idempotent and bumps once" `Quick
            test_commit_is_idempotent_and_bumps_once
        ] )
    ; ( "v2 page"
      , [ test_case "decode events page" `Quick test_decode_events_page
        ; test_case "add_journaled holds undrawn positions" `Quick
            test_add_journaled_holds_undrawn_positions
        ; test_case "decode events error by code" `Quick
            test_decode_events_error_by_code
        ; test_case "hold_seq counts without an entry" `Quick
            test_hold_seq_counts_without_an_entry
        ; test_case "read_whole_journal pages until the position stops moving" `Quick
            test_read_whole_journal_pages_until_the_position_stops_moving
        ] )
    ; ( "golden"
      , [ test_case "journal equals wire" `Quick test_golden_journal_equals_wire
        ; test_case "journal equals wire in chunks" `Quick
            test_golden_journal_equals_wire_in_chunks
        ; test_case "a journal page fills the log like the wire does" `Quick
            test_a_journal_page_fills_the_log_like_the_wire_does
        ] )
    ]
