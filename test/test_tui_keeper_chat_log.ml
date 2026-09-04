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
  check int "last seq" 0 (Log.last_seq t)

let test_last_seq_follows_the_highest_held () =
  let t = log () in
  check int "empty log" (-1) (Log.last_seq t);
  ignore (Log.add t ~seq:(Some 4) (Live.Text "a") : bool);
  ignore (Log.add t ~seq:(Some 2) (Live.Text "b") : bool);
  check int "gaps do not matter, order does not matter" 4 (Log.last_seq t)

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
    ; "next_since_seq", `Int next_since_seq
    ]

let test_decode_events_page () =
  let lines =
    [ line 0 1.0 (E.Run_started { run_id = "r"; thread_id = "keeper:keeper.one" })
    ; line 1 1.5 (E.Text_delta "hello")
    ]
  in
  (match Log.decode_events_page (page_json ~has_more:true ~next_since_seq:1 lines) with
   | Ok page ->
       check int "two events" 2 (List.length page.events);
       check bool "has_more" true page.has_more;
       check int "cursor" 1 page.next_since_seq
   | Error detail -> fail detail);
  (match Log.decode_events_page (page_json ~schema:"masc.keeper_chat_events.v1" ~has_more:false ~next_since_seq:0 lines) with
   | Ok _ -> fail "a wrong schema decoded"
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

let test_add_journaled_holds_undrawn_positions () =
  let t = log () in
  Log.add_journaled t
    [ line 0 1.0 (E.Run_started { run_id = "r"; thread_id = "keeper:keeper.one" })
    ; line 1 1.1 (E.Text_message_start { message_id = "m"; role = E.Assistant })
    ; line 2 1.2 (E.Text_delta "hi")
    ];
  check (list tagged) "start and delta are entries, message start is not"
    [ (Some 0, Live.Run_started); (Some 2, Live.Text "hi") ]
    (List.map (fun (entry : Log.entry) -> (entry.seq, entry.delta)) (Log.entries t));
  check int "the undrawn seq still counts as held" 2 (Log.last_seq t);
  check bool "a live frame for the undrawn seq is a duplicate" false
    (Log.add t ~seq:(Some 1) (Live.Text "late"))

(* ── Golden: journal vs wire ──────────────────────────────────────── *)

let occurrence : E.tool_stream_occurrence =
  { stream_scope = 0; provider_message_id = Some "pm-1"; block_index = 2 }

let golden : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-golden"; thread_id = "keeper:keeper.one" }
  ; E.Agent_core_stream_connected
  ; E.Text_message_start { message_id = "msg-1"; role = E.Assistant }
  ; E.Agent_core_thinking_delta { index = 0; delta = "weighing it" }
  ; E.Text_delta "Let me "
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
  ; E.Run_finished { run_id = "run-golden" }
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
  List.concat_map
    (fun (seq, event) -> List.map (fun d -> (Some seq, d)) (Log.delta_of_journaled event))
    events

let test_golden_journal_equals_wire () =
  let events = List.mapi (fun seq event -> (seq, event)) golden in
  let wire = wire_tagged_deltas events in
  let journal = journal_tagged_deltas events in
  check bool "the fixture exercises the log" true (List.length journal > 10);
  check (list tagged) "journal decode equals the live wire decode" wire journal

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
  Log.add_journaled from_journal
    (List.map (fun (seq, event) -> line seq (1000.0 +. float_of_int seq) event) events);
  let view t = List.map (fun (entry : Log.entry) -> (entry.seq, entry.delta)) (Log.entries t) in
  check (list tagged) "same entries" (view from_wire) (view from_journal);
  check int "same last seq" (Log.last_seq from_wire) (Log.last_seq from_journal);
  check int "same attempt" (Log.attempt from_wire) (Log.attempt from_journal);
  check bool "the wire's attempt advanced past the retry" true (Log.attempt from_wire = 1)

let () =
  run "tui keeper chat log"
    [ ( "log"
      , [ test_case "seq dedup, and None never dedupes" `Quick
            test_seq_dedup_and_none_never_dedupes
        ; test_case "last seq follows the highest held" `Quick
            test_last_seq_follows_the_highest_held
        ; test_case "attempt advances on runtime attempt started" `Quick
            test_attempt_advances_on_runtime_attempt_started
        ; test_case "commit is idempotent and bumps once" `Quick
            test_commit_is_idempotent_and_bumps_once
        ] )
    ; ( "v2 page"
      , [ test_case "decode events page" `Quick test_decode_events_page
        ; test_case "add_journaled holds undrawn positions" `Quick
            test_add_journaled_holds_undrawn_positions
        ] )
    ; ( "golden"
      , [ test_case "journal equals wire" `Quick test_golden_journal_equals_wire
        ; test_case "journal equals wire in chunks" `Quick
            test_golden_journal_equals_wire_in_chunks
        ; test_case "a journal page fills the log like the wire does" `Quick
            test_a_journal_page_fills_the_log_like_the_wire_does
        ] )
    ]
