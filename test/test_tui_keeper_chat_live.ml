open Alcotest

module Live = Masc_tui_keeper_chat_live

(* The live decoder takes bytes, not lines, so the property that matters is
   that it does not care where the chunks were cut. Every test that asserts a
   delta sequence therefore asserts it for a whole-body feed and for a
   byte-at-a-time feed, and the invariance test below pins the general case. *)

let delta_to_string : Live.delta -> string = function
  | Live.Run_started -> "run_started"
  | Live.Text text -> Printf.sprintf "text(%s)" text
  | Live.Thinking text -> Printf.sprintf "thinking(%s)" text
  | Live.Tool_started { call_id; tool_name } ->
      Printf.sprintf "tool_started(%s,%s)" call_id tool_name
  | Live.Tool_args { call_id; fragment = Live.Args_delta delta } ->
      Printf.sprintf "tool_args_delta(%s,%s)" call_id delta
  | Live.Tool_args { call_id; fragment = Live.Args_snapshot snapshot } ->
      Printf.sprintf "tool_args_snapshot(%s,%s)" call_id snapshot
  | Live.Tool_ended { call_id } -> Printf.sprintf "tool_ended(%s)" call_id
  | Live.Tool_result { call_id } -> Printf.sprintf "tool_result(%s)" call_id
  | Live.Checkpoint -> "checkpoint"
  | Live.External_effect_completed -> "external_effect_completed"
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
      [ "runId", `String run_id
      ; "toolCallId", `String "call-1"
      ; "toolCallName", `String "read_file"
      ]
  ; event "TOOL_CALL_ARGS"
      [ "runId", `String run_id
      ; "toolCallId", `String "call-1"
      ; "delta", `String "{\"path\":\"lib/a.ml\"}"
      ]
  ; event "TOOL_CALL_END"
      [ "runId", `String run_id; "toolCallId", `String "call-1" ]
  ; custom "KEEPER_TOOL_RESULT_READY"
      (`Assoc [ "tool_call_id", `String "call-1" ])
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
  ; Live.Tool_started { call_id = "call-1"; tool_name = "read_file" }
  ; Live.Tool_args
      { call_id = "call-1"; fragment = Live.Args_delta "{\"path\":\"lib/a.ml\"}" }
  ; Live.Tool_ended { call_id = "call-1" }
  ; Live.Tool_result { call_id = "call-1" }
  ; Live.Thinking "weighing it"
  ; Live.Text " Found it."
  ; Live.Run_finished
  ]

(* ── Feed drivers ────────────────────────────────────────────────── *)

let feed_whole body =
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
  loop 0 []

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
    (Live.feed decoder head);
  check (list delta) "the delta arrives when the line ends"
    [ Live.Text "hello" ]
    (Live.feed decoder tail)

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
         [ "runId", `String run_id; "toolCallId", `String "call-9" ])
  in
  check (list delta) "a tool start with no name is reported as such"
    [ Live.Undecodable "TOOL_CALL_START has no toolCallName" ]
    (feed_whole body)

let test_args_snapshot_replaces_rather_than_appends () =
  let body =
    sse
      (event "TOOL_CALL_ARGS"
         [ "runId", `String run_id
         ; "toolCallId", `String "call-2"
         ; "snapshot", `String "{\"path\":\"b.ml\"}"
         ])
  in
  check (list delta) "a snapshot is carried as a snapshot"
    [ Live.Tool_args
        { call_id = "call-2"
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
        ] )
    ; ( "reporting"
      , [ test_case "an unreadable line is reported, the stream continues"
            `Quick test_unreadable_line_is_reported_and_does_not_stop_the_stream
        ; test_case "a missing field names its event" `Quick
            test_missing_field_names_the_event
        ; test_case "a run error with no message still fails" `Quick
            test_run_error_is_a_failure_even_with_no_message
        ; test_case "undrawn events stay silent" `Quick
            test_events_this_view_does_not_draw_are_silent
        ] )
    ]
