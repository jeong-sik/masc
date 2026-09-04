open Alcotest

module Live = Masc_tui_keeper_chat_live

(* The live decoder takes bytes, not lines, so the property that matters is
   that it does not care where the chunks were cut. Every test that asserts a
   delta sequence therefore asserts it for a whole-body feed and for a
   byte-at-a-time feed, and the invariance test below pins the general case. *)

let delta_to_string : Live.delta -> string = function
  | Live.Run_started -> "run_started"
  | Live.Runtime_attempt_started -> "runtime_attempt_started"
  | Live.Text text -> Printf.sprintf "text(%s)" text
  | Live.Thinking text -> Printf.sprintf "thinking(%s)" text
  | Live.Tool_started { occurrence; tool_name } ->
      Printf.sprintf "tool_started(%d/%d,%s)" occurrence.stream_scope
        occurrence.block_index tool_name
  | Live.Tool_args { occurrence; fragment = Live.Args_delta delta } ->
      Printf.sprintf "tool_args_delta(%d/%d,%s)" occurrence.stream_scope
        occurrence.block_index delta
  | Live.Tool_args { occurrence; fragment = Live.Args_snapshot snapshot } ->
      Printf.sprintf "tool_args_snapshot(%d/%d,%s)" occurrence.stream_scope
        occurrence.block_index snapshot
  | Live.Tool_ended { occurrence } ->
      Printf.sprintf "tool_ended(%d/%d)" occurrence.stream_scope occurrence.block_index
  | Live.Tool_result { occurrence; execution_id } ->
      Printf.sprintf "tool_result(%d/%d,%s)" occurrence.stream_scope
        occurrence.block_index execution_id
  | Live.Stream_protocol_error { quarantined_occurrence; detail } ->
      let occurrence =
        Option.fold ~none:"-"
          ~some:(fun (occurrence : Live.tool_occurrence) ->
            Printf.sprintf "%d/%d" occurrence.stream_scope occurrence.block_index)
          quarantined_occurrence
      in
      Printf.sprintf "stream_protocol_error(%s,%s)" occurrence detail
  | Live.Approval_requested { call_id; tool_name; args; question; because } ->
      Printf.sprintf "approval_requested(%s,%s,%s,%s,%s)" call_id tool_name
        args question because
  | Live.Approval_settled { call_id; outcome } ->
      Printf.sprintf "approval_settled(%s,%s)" call_id outcome
  | Live.Accepted { admission; queue_length } ->
      let admission =
        match admission with
        | Live.Queued -> "queued"
        | Live.Running -> "running"
        | Live.Settled -> "settled"
      in
      Printf.sprintf "accepted(%s,%d)" admission queue_length
  | Live.Checkpoint -> "checkpoint"
  | Live.External_effect_completed -> "external_effect_completed"
  | Live.Reply_details { reply; turn_outcome; turn_ref } ->
      Printf.sprintf "reply_details(%s,%s,%s)" reply
        (Masc.Keeper_turn_outcome.to_label turn_outcome)
        turn_ref
  | Live.Run_failed { message } -> Printf.sprintf "run_failed(%s)" message
  | Live.Run_finished -> "run_finished"
  | Live.Undecodable detail -> Printf.sprintf "undecodable(%s)" detail

let delta = testable (Fmt.of_to_string delta_to_string) ( = )

(* ── Stream fixtures ─────────────────────────────────────────────── *)

let thread_id = "keeper:keeper.one"
let run_id = "keeper-operation-run-tui-request-1"
let message_id = "keeper-operation-message-tui-request-1"

let event event_type fields =
  `Assoc
    ([ "type", `String event_type
     ; "threadId", `String thread_id
     ; "timestamp", `Float 1.0
     ]
     @ fields)

let sse json = "data: " ^ Yojson.Safe.to_string json ^ "\n\n"

let text_content delta =
  event "TEXT_MESSAGE_CONTENT"
    [ "runId", `String run_id
    ; "messageId", `String message_id
    ; "delta", `String delta
    ]

let custom name value =
  event "CUSTOM"
    [ "runId", `String run_id; "name", `String name; "value", value ]

let occurrence_fields ?(scope = 2) ?(block_index = 1) ?(call_id = Some "call-1") () =
  [ "toolStreamScope", `Int scope
  ; "toolCallBlockIndex", `Int block_index
  ]
  @ Option.fold ~none:[] ~some:(fun id -> [ "toolCallId", `String id ]) call_id
;;

let occurrence ?(scope = 2) ?(block_index = 1) ?(call_id = Some "call-1") () =
  { Live.stream_scope = scope
  ; block_index
  ; provider_message_id = None
  ; tool_call_id = call_id
  }
;;

(* A turn that answers, reads a file, thinks, and answers again — the shape
   the live pane exists to show. *)
let coding_turn_events =
  [ event "RUN_STARTED" [ "runId", `String run_id ]
  ; event "TEXT_MESSAGE_START"
      [ "runId", `String run_id
      ; "messageId", `String message_id
      ; "role", `String "assistant"
      ]
  ; text_content "Let me "
  ; text_content "look."
  ; event "TOOL_CALL_START"
      ([ "runId", `String run_id; "toolCallName", `String "read_file" ]
       @ occurrence_fields ())
  ; event "TOOL_CALL_ARGS"
      ([ "runId", `String run_id; "delta", `String "{\"path\":\"lib/a.ml\"}" ]
       @ occurrence_fields ())
  ; event "TOOL_CALL_END"
      ([ "runId", `String run_id ] @ occurrence_fields ())
  ; custom "KEEPER_TOOL_RESULT_READY"
      (`Assoc
         (occurrence_fields () @ [ "executionId", `String "exec-1" ]))
  ; custom "KEEPER_THINKING_DELTA"
      (`Assoc [ "index", `Int 0; "delta", `String "weighing it" ])
  ; text_content " Found it."
  ; event "TEXT_MESSAGE_END"
      [ "runId", `String run_id; "messageId", `String message_id ]
  ; event "RUN_FINISHED" [ "runId", `String run_id ]
  ]

let coding_turn_body =
  coding_turn_events |> List.map sse |> String.concat ""

let expected_coding_turn =
  [ Live.Run_started
  ; Live.Text "Let me "
  ; Live.Text "look."
  ; Live.Tool_started { occurrence = occurrence (); tool_name = "read_file" }
  ; Live.Tool_args
      { occurrence = occurrence (); fragment = Live.Args_delta "{\"path\":\"lib/a.ml\"}" }
  ; Live.Tool_ended { occurrence = occurrence () }
  ; Live.Tool_result { occurrence = occurrence (); execution_id = "exec-1" }
  ; Live.Thinking "weighing it"
  ; Live.Text " Found it."
  ; Live.Run_finished
  ]

(* ── Feed drivers ────────────────────────────────────────────────── *)

(* The acceptance event carries no runId: the server sends it before there is
   a run. Built here rather than through [custom] so the fixture is the shape
   the server actually writes. *)
let accepted ?(operation_id = "op-1") ~state ~queued_count () =
  event "CUSTOM"
    [ "name", `String "KEEPER_CHAT_OPERATION_ACCEPTED"
    ; ( "value"
      , `Assoc
          [ "operation_id", `String operation_id
          ; "state", `String state
          ; "queued_count", `Int queued_count
          ] )
    ]

let feed_whole body =
  let decoder = Live.create () in
  List.map snd (Live.feed decoder body)

let feed_whole_tagged body =
  let decoder = Live.create () in
  Live.feed decoder body

(* Split [body] into [size]-byte chunks and concatenate what each feed
   returns. *)
let feed_in_chunks ~size body =
  let decoder = Live.create () in
  let length = String.length body in
  let rec loop offset acc =
    if offset >= length then List.rev acc
    else
      let take = min size (length - offset) in
      let chunk = String.sub body offset take in
      loop (offset + take) (List.rev_append (Live.feed decoder chunk) acc)
  in
  List.map snd (loop 0 [])

let feed_in_chunks_tagged ~size body =
  let decoder = Live.create () in
  let length = String.length body in
  let rec loop offset acc =
    if offset >= length then List.rev acc
    else
      let take = min size (length - offset) in
      let chunk = String.sub body offset take in
      loop (offset + take) (List.rev_append (Live.feed decoder chunk) acc)
  in
  loop 0 []

let tagged = pair (option int) delta

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_coding_turn_whole_body () =
  check (list delta) "deltas of a whole-body feed" expected_coding_turn
    (feed_whole coding_turn_body)

let test_chunk_boundaries_do_not_matter () =
  (* 1 catches every mid-line and mid-escape cut. The others are chosen to
     land inside JSON payloads, on and around the "\n\n" that ends an event,
     and past the end of one event into the next. *)
  List.iter
    (fun size ->
      check (list delta)
        (Printf.sprintf "deltas are the same in %d-byte chunks" size)
        expected_coding_turn
        (feed_in_chunks ~size coding_turn_body))
    [ 1; 2; 3; 7; 13; 64; 997; String.length coding_turn_body ]

let test_partial_line_emits_nothing_until_it_ends () =
  let decoder = Live.create () in
  let body = sse (text_content "hello") in
  let split_at = String.length body - 4 in
  let head = String.sub body 0 split_at in
  let tail = String.sub body split_at (String.length body - split_at) in
  check (list delta) "an unfinished line yields no delta" []
    (List.map snd (Live.feed decoder head));
  check (list delta) "the delta arrives when the line ends"
    [ Live.Text "hello" ]
    (List.map snd (Live.feed decoder tail))

(* ── Journal seq on the frame ─────────────────────────────────────── *)

let with_id seq frame = Printf.sprintf "id: %d\n%s" seq frame

let test_a_frame_id_tags_its_deltas () =
  check (list tagged) "the id line's seq rides the delta"
    [ (Some 7, Live.Text "hello") ]
    (feed_whole_tagged (with_id 7 (sse (text_content "hello"))))

let test_an_id_held_across_a_chunk_boundary () =
  let decoder = Live.create () in
  check (list tagged) "the id line alone yields nothing" []
    (Live.feed decoder "id: 7\n");
  check (list tagged) "the data line that follows carries it"
    [ (Some 7, Live.Text "hello") ]
    (Live.feed decoder (sse (text_content "hello")))

let test_an_id_less_frame_does_not_inherit_the_previous_seq () =
  let body =
    with_id 3 (sse (text_content "a"))
    ^ sse (accepted ~state:"Running" ~queued_count:1 ())
    ^ with_id 4 (sse (text_content "b"))
  in
  check (list tagged) "acceptance is None between two tagged frames"
    [ (Some 3, Live.Text "a")
    ; (None, Live.Accepted { admission = Live.Running; queue_length = 1 })
    ; (Some 4, Live.Text "b")
    ]
    (feed_whole_tagged body);
  List.iter
    (fun size ->
      check (list tagged)
        (Printf.sprintf "the same tags in %d-byte chunks" size)
        (feed_whole_tagged body)
        (feed_in_chunks_tagged ~size body))
    [ 1; 2; 3; 7; 13 ]

let test_a_non_integer_id_is_no_seq () =
  check (list tagged) "id: x tags nothing"
    [ (None, Live.Text "hello") ]
    (feed_whole_tagged ("id: x\n" ^ sse (text_content "hello")));
  List.iter
    (fun raw ->
      check (list tagged) (raw ^ " is not a decimal seq")
        [ (None, Live.Text "hello") ]
        (feed_whole_tagged (raw ^ "\n" ^ sse (text_content "hello"))))
    [ "id: 0x10"; "id: 1_0"; "id: -1"; "id: +5" ]

let test_id_line_spellings () =
  check (list tagged) "no space after the colon" [ (Some 7, Live.Text "hello") ]
    (feed_whole_tagged ("id:7\n" ^ sse (text_content "hello")));
  check (list tagged) "trailing spaces" [ (Some 7, Live.Text "hello") ]
    (feed_whole_tagged ("id: 7   \n" ^ sse (text_content "hello")));
  check (list tagged) "two id lines: the last one wins" [ (Some 8, Live.Text "hello") ]
    (feed_whole_tagged ("id: 7\nid: 8\n" ^ sse (text_content "hello")))

(* SSE dispatches on the empty line alone; a line of spaces is a nameless
   field and must not end the frame -- or the seq would be dropped before the
   data line it belongs to. *)
let test_a_whitespace_line_is_not_a_frame_end () =
  check (list tagged) "the seq survives a blank-but-not-empty line"
    [ (Some 7, Live.Text "hello") ]
    (feed_whole_tagged ("id: 7\n   \n" ^ sse (text_content "hello")))

(* Two data lines in one frame share the frame's id: the seq is cleared at
   the frame end, not at the first data line. *)
let test_two_data_lines_in_one_frame_share_the_seq () =
  let frame =
    "id: 7\n"
    ^ "data: " ^ Yojson.Safe.to_string (text_content "a") ^ "\n"
    ^ "data: " ^ Yojson.Safe.to_string (text_content "b") ^ "\n\n"
  in
  check (list tagged) "both carry seq 7"
    [ (Some 7, Live.Text "a"); (Some 7, Live.Text "b") ]
    (feed_whole_tagged frame)

let test_unreadable_line_is_reported_and_does_not_stop_the_stream () =
  let body =
    "data: {not json\n\n" ^ sse (text_content "after") ^ "data:{\"type\":\"X\"}\n\n"
  in
  match feed_whole body with
  | [ Live.Undecodable json_detail; Live.Text "after"; Live.Undecodable frame_detail ]
    ->
      check bool "the unreadable JSON says so" true
        (String.length json_detail > 0);
      check string "a non-canonical data field is named as one"
        "non-canonical data field" frame_detail
  | other ->
      failf "expected report, text, report; got [%s]"
        (String.concat "; " (List.map delta_to_string other))

let test_missing_field_names_the_event () =
  let body =
    sse
      (event "TOOL_CALL_START"
         ([ "runId", `String run_id ]
          @ occurrence_fields ~call_id:(Some "call-9") ()))
  in
  check (list delta) "a tool start with no name is reported as such"
    [ Live.Undecodable "TOOL_CALL_START has no nonblank toolCallName" ]
    (feed_whole body)

let test_tool_result_requires_nonblank_canonical_identity () =
  let result value =
    sse (custom "KEEPER_TOOL_RESULT_READY" value) |> feed_whole
  in
  check (list delta) "missing execution id is reported"
    [ Live.Undecodable "KEEPER_TOOL_RESULT_READY has no nonblank executionId" ]
    (result (`Assoc (occurrence_fields ~call_id:(Some "call-9") ())));
  check (list delta) "blank execution id is reported"
    [ Live.Undecodable "KEEPER_TOOL_RESULT_READY has no nonblank executionId" ]
    (result
       (`Assoc
          (occurrence_fields ~call_id:(Some "call-9") ()
           @ [ "executionId", `String " " ])))

let test_protocol_error_carries_only_the_quarantined_occurrence () =
  let value =
    `Assoc
      [ "kind", `String "tool_replay_mismatch"
      ; "reason", `String "replayed arguments changed"
      ; ( "quarantined_occurrence"
        , `Assoc (occurrence_fields ~scope:4 ~block_index:7 ~call_id:None ()) )
      ]
  in
  check (list delta) "the exact quarantined row reaches the live view"
    [ Live.Stream_protocol_error
        { quarantined_occurrence =
            Some (occurrence ~scope:4 ~block_index:7 ~call_id:None ())
        ; detail = "tool_replay_mismatch: replayed arguments changed"
        }
    ]
    (sse (custom "KEEPER_STREAM_PROTOCOL_ERROR" value) |> feed_whole)

let test_args_snapshot_replaces_rather_than_appends () =
  let body =
    sse
      (event "TOOL_CALL_ARGS"
         ([ "runId", `String run_id
          ; "snapshot", `String "{\"path\":\"b.ml\"}"
          ]
          @ occurrence_fields ~call_id:(Some "call-2") ()))
  in
  check (list delta) "a snapshot is carried as a snapshot"
    [ Live.Tool_args
        { occurrence = occurrence ~call_id:(Some "call-2") ()
        ; fragment = Live.Args_snapshot "{\"path\":\"b.ml\"}"
        }
    ]
    (feed_whole body)

let test_run_error_is_a_failure_even_with_no_message () =
  let body = sse (event "RUN_ERROR" [ "runId", `String run_id ]) in
  check (list delta) "a run error with no message still fails the run"
    [ Live.Run_failed { message = "" } ]
    (feed_whole body)

let test_events_this_view_does_not_draw_are_silent () =
  let body =
    sse (custom "KEEPER_STREAM_PING" `Null)
    ^ sse (event "STEP_STARTED" [ "runId", `String run_id ])
  in
  check (list delta)
    "a ping and a step boundary produce nothing rather than a report" []
    (feed_whole body)

let test_checkpoint_and_external_effect_are_drawn () =
  let body =
    sse (custom "KEEPER_CONTINUATION_CHECKPOINT" (`Assoc []))
    ^ sse (custom "KEEPER_EXTERNAL_EFFECT_COMPLETED" (`Assoc []))
  in
  check (list delta) "both reach the view"
    [ Live.Checkpoint; Live.External_effect_completed ]
    (feed_whole body)

let test_an_approval_request_is_read_whole () =
  let body =
    sse
      (custom "KEEPER_TOOL_APPROVAL_REQUESTED"
         (`Assoc
            [ "tool_call_id", `String "c1"
            ; "tool_call_name", `String "Edit"
            ; "args", `String "{\"file_path\":\"a.ml\"}"
            ; "question", `String "Run Edit on a.ml?"
            ]))
  in
  check (list delta) "every field the prompt needs comes through"
    [ Live.Approval_requested
        { call_id = "c1"
        ; tool_name = "Edit"
        ; args = "{\"file_path\":\"a.ml\"}"
        ; question = "Run Edit on a.ml?"
        ; because = ""
        }
    ]
    (feed_whole body)

let test_a_request_missing_its_question_is_reported () =
  (* Without a question there is nothing to ask, so this is reported rather
     than drawn as a prompt with a blank line. *)
  let body =
    sse
      (custom "KEEPER_TOOL_APPROVAL_REQUESTED"
         (`Assoc
            [ "tool_call_id", `String "c1"; "tool_call_name", `String "Edit" ]))
  in
  match feed_whole body with
  | [ Live.Undecodable detail ] ->
      check bool "the report names what was missing" true
        (String.length detail > 0)
  | other ->
      failf "expected one report, got [%s]"
        (String.concat "; " (List.map delta_to_string other))

let test_the_because_reaches_the_pane () =
  (* The approval list screen shows why a call was held (#30518). A reader
     answering from the chat pane decides on the same call, so the reason has
     to arrive here too -- without it the pane asks a question the rest of the
     TUI already answers. *)
  let body =
    sse
      (custom "KEEPER_TOOL_APPROVAL_REQUESTED"
         (`Assoc
            [ "tool_call_id", `String "c1"
            ; "tool_call_name", `String "Edit"
            ; "args", `String "{}"
            ; "question", `String "Run Edit on a.ml?"
            ; "because", `String "file_path touches /etc"
            ]))
  in
  check (list delta) "why the call was held travels with the ask"
    [ Live.Approval_requested
        { call_id = "c1"
        ; tool_name = "Edit"
        ; args = "{}"
        ; question = "Run Edit on a.ml?"
        ; because = "file_path touches /etc"
        }
    ]
    (feed_whole body)

let test_a_request_with_no_arguments_is_still_a_prompt () =
  let body =
    sse
      (custom "KEEPER_TOOL_APPROVAL_REQUESTED"
         (`Assoc
            [ "tool_call_id", `String "c1"
            ; "tool_call_name", `String "Execute"
            ; "question", `String "Run Execute?"
            ]))
  in
  check (list delta) "a reader still has to answer it"
    [ Live.Approval_requested
        { call_id = "c1"
        ; tool_name = "Execute"
        ; args = ""
        ; question = "Run Execute?"
        ; because = ""
        }
    ]
    (feed_whole body)

let test_the_settled_event_carries_its_outcome () =
  let body =
    sse
      (custom "KEEPER_TOOL_APPROVAL_SETTLED"
         (`Assoc
            [ "tool_call_id", `String "c1"; "outcome", `String "timed_out" ]))
  in
  check (list delta) "including the paths where nobody answered"
    [ Live.Approval_settled { call_id = "c1"; outcome = "timed_out" } ]
    (feed_whole body)

(* The acceptance is what the pane has to answer "why has this not started"
   with. Before it, a wait of minutes and a wait of seconds look the same. *)
let test_acceptance_states_are_read () =
  let deltas state = feed_whole (sse (accepted ~state ~queued_count:2 ())) in
  check (list delta) "queued keeps its place in the queue"
    [ Live.Accepted { admission = Live.Queued; queue_length = 2 } ]
    (deltas "Queued");
  check (list delta) "running has started"
    [ Live.Accepted { admission = Live.Running; queue_length = 2 } ]
    (deltas "Running");
  (* One admission for the three terminal words: the pane draws them the same,
     and keeping them apart here would be a distinction nothing reads. *)
  List.iter
    (fun state ->
      check (list delta) ("a finished operation is settled: " ^ state)
        [ Live.Accepted { admission = Live.Settled; queue_length = 2 } ]
        (deltas state))
    [ "Succeeded"; "Failed"; "Cancelled" ]

(* An unknown state is reported rather than folded into one of the three. A
   reader that guessed would draw a queue position for a word it did not
   understand. *)
let test_unknown_acceptance_state_is_reported () =
  check (list delta) "the unknown word is named"
    [ Live.Undecodable
        "unknown Keeper chat operation state \"Vanished\""
    ]
    (feed_whole (sse (accepted ~state:"Vanished" ~queued_count:1 ())))

let test_acceptance_missing_fields_are_named () =
  let value fields = event "CUSTOM"
    [ "name", `String "KEEPER_CHAT_OPERATION_ACCEPTED"
    ; "value", `Assoc (("operation_id", `String "op-1") :: fields)
    ]
  in
  check (list delta) "a missing state names itself"
    [ Live.Undecodable "KEEPER_CHAT_OPERATION_ACCEPTED.value.state is required" ]
    (feed_whole (sse (value [ "queued_count", `Int 1 ])));
  check (list delta) "a missing queued_count names itself"
    [ Live.Undecodable
        "KEEPER_CHAT_OPERATION_ACCEPTED.value.queued_count is required"
    ]
    (feed_whole (sse (value [ "state", `String "Queued" ])))

let test_acceptance_rejects_negative_queue_length () =
  check (list delta) "the live and strict readers share the queue bound"
    [ Live.Undecodable
        "KEEPER_CHAT_OPERATION_ACCEPTED.value.queued_count must be a nonnegative integer"
    ]
    (feed_whole (sse (accepted ~state:"Queued" ~queued_count:(-1) ())))

let test_runtime_attempt_boundary_is_typed () =
  let body = sse (custom "KEEPER_RUNTIME_ATTEMPT_STARTED" `Null) in
  check (list delta) "runtime boundary is not silently dropped"
    [ Live.Runtime_attempt_started ]
    (feed_whole body)

let test_runtime_attempt_rejects_non_null_payload () =
  let body =
    sse (custom "KEEPER_RUNTIME_ATTEMPT_STARTED" (`Assoc []))
  in
  check (list delta) "runtime boundary payload is exact"
    [ Live.Undecodable
        "Keeper chat CUSTOM event KEEPER_RUNTIME_ATTEMPT_STARTED.value must be null"
    ]
    (feed_whole body)

let test_unknown_custom_event_is_reported () =
  let body = sse (custom "KEEPER_FUTURE_EVENT" `Null) in
  check (list delta) "new server vocabulary cannot disappear silently"
    [ Live.Undecodable "unknown CUSTOM event name: KEEPER_FUTURE_EVENT" ]
    (feed_whole body)

let () =
  run "tui_keeper_chat_live"
    [ ( "deltas"
      , [ test_case "coding turn, whole body" `Quick test_coding_turn_whole_body
        ; test_case "chunk size does not change the deltas" `Quick
            test_chunk_boundaries_do_not_matter
        ; test_case "a partial line is held" `Quick
            test_partial_line_emits_nothing_until_it_ends
        ; test_case "args snapshot stays a snapshot" `Quick
            test_args_snapshot_replaces_rather_than_appends
        ; test_case "checkpoint and external effect are drawn" `Quick
            test_checkpoint_and_external_effect_are_drawn
        ; test_case "runtime attempt boundary is typed" `Quick
            test_runtime_attempt_boundary_is_typed
        ; test_case "runtime attempt rejects non-null payload" `Quick
            test_runtime_attempt_rejects_non_null_payload
        ] )
    ; ( "acceptance"
      , [ test_case "the three states are read" `Quick
            test_acceptance_states_are_read
        ; test_case "an unknown state is reported" `Quick
            test_unknown_acceptance_state_is_reported
        ; test_case "missing fields name themselves" `Quick
            test_acceptance_missing_fields_are_named
        ; test_case "negative queue length is rejected" `Quick
            test_acceptance_rejects_negative_queue_length
        ] )
    ; ( "held calls"
      , [ test_case "an approval request is read whole" `Quick
            test_an_approval_request_is_read_whole;
          test_case "the because reaches the pane" `Quick
            test_the_because_reaches_the_pane;
        test_case "a request with no arguments is still a prompt" `Quick
            test_a_request_with_no_arguments_is_still_a_prompt
        ; test_case "the settled event carries its outcome" `Quick
            test_the_settled_event_carries_its_outcome
        ; test_case "a request missing its question is reported" `Quick
            test_a_request_missing_its_question_is_reported
        ] )
    ; ( "reporting"
      , [ test_case "an unreadable line is reported, the stream continues"
            `Quick test_unreadable_line_is_reported_and_does_not_stop_the_stream
        ; test_case "a missing field names its event" `Quick
            test_missing_field_names_the_event
        ; test_case "tool result requires canonical identity" `Quick
            test_tool_result_requires_nonblank_canonical_identity
        ; test_case "protocol error carries quarantined occurrence" `Quick
            test_protocol_error_carries_only_the_quarantined_occurrence
        ; test_case "a run error with no message still fails" `Quick
            test_run_error_is_a_failure_even_with_no_message
        ; test_case "undrawn events stay silent" `Quick
            test_events_this_view_does_not_draw_are_silent
        ; test_case "a frame id tags its deltas" `Quick test_a_frame_id_tags_its_deltas
        ; test_case "an id held across a chunk boundary" `Quick
            test_an_id_held_across_a_chunk_boundary
        ; test_case "an id-less frame does not inherit the previous seq" `Quick
            test_an_id_less_frame_does_not_inherit_the_previous_seq
        ; test_case "a non-integer id is no seq" `Quick test_a_non_integer_id_is_no_seq
        ; test_case "id line spellings" `Quick test_id_line_spellings
        ; test_case "a whitespace line is not a frame end" `Quick
            test_a_whitespace_line_is_not_a_frame_end
        ; test_case "two data lines in one frame share the seq" `Quick
            test_two_data_lines_in_one_frame_share_the_seq
        ; test_case "unknown custom event is reported" `Quick
            test_unknown_custom_event_is_reported
        ] )
    ]
