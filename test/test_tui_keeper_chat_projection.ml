open Alcotest

module Chat = Masc_tui_keeper_chat_projection

let json_string json = Yojson.Safe.to_string json
let sse_event json = "data: " ^ json_string json ^ "\n\n"

let request : Chat.request =
  { request_id = "tui-request-1";
    keeper_name = "keeper.one";
    message = "hello";
    attachments = [];
  }

let thread_id = "keeper:" ^ request.keeper_name
let run_id = "keeper-operation-run-" ^ request.request_id
let message_id = "keeper-operation-message-" ^ request.request_id

let event event_type fields =
  `Assoc
    ([ "type", `String event_type
     ; "threadId", `String thread_id
     ; "timestamp", `Float 1.0
     ]
     @ fields)

let acceptance ?(operation_id = "tui-request-1") ?(state = "Queued")
    ?(queued_count = 0) () =
  `Assoc
    [ "type", `String "CUSTOM"
    ; "threadId", `String "default"
    ; "timestamp", `Float 1.0
    ; "name", `String "KEEPER_CHAT_OPERATION_ACCEPTED"
    ; ( "value"
      , `Assoc
          [ "operation_id", `String operation_id
          ; "state", `String state
          ; "queued_count", `Int queued_count
          ] )
    ]

let reply_details ?(reply = "hello") ?(turn_outcome = "visible_reply")
    ?(turn_ref = "trace-chat#1") () =
  event "CUSTOM"
    [ "runId", `String run_id
    ; "name", `String "KEEPER_REPLY_DETAILS"
    ; ( "value"
      , `Assoc
          [ "reply", `String reply
          ; "turn_outcome", `String turn_outcome
          ; "turn_ref", `String turn_ref
          ] )
    ]

let run_started = event "RUN_STARTED" [ "runId", `String run_id ]

let text_start =
  event "TEXT_MESSAGE_START"
    [ "runId", `String run_id
    ; "messageId", `String message_id
    ; "role", `String "assistant"
    ]

let delta text =
  event "TEXT_MESSAGE_CONTENT"
    [ "runId", `String run_id
    ; "messageId", `String message_id
    ; "delta", `String text
    ]

let text_end =
  event "TEXT_MESSAGE_END"
    [ "runId", `String run_id; "messageId", `String message_id ]

let run_finished = event "RUN_FINISHED" [ "runId", `String run_id ]

let run_error ?(accepted = true) ?(code = "turn_failed") message =
  event "RUN_ERROR"
    ((if accepted then [ "runId", `String run_id ] else [])
     @ [ "message", `String message; "code", `String code ])

let decode events =
  events |> List.map sse_event |> String.concat ""
  |> Chat.decode_response ~request

let decode_with_provenance events =
  events |> List.map sse_event |> String.concat ""
  |> Chat.decode_response_with_provenance ~request

let test_request_body_and_identity () =
  let request = Chat.create_request ~keeper_name:"keeper.one" ~message:"hello" () in
  check bool "request id prefix" true
    (String.starts_with ~prefix:"tui-" request.request_id);
  let uuid = String.sub request.request_id 4 (String.length request.request_id - 4) in
  check bool "request id carries canonical UUIDv7" true
    (Result.is_ok (Random_id.parse_uuid_v7 uuid));
  check string "exact body"
    (Printf.sprintf
       {|{"request_id":%S,"name":"keeper.one","message":"hello"}|}
       request.request_id)
    (Chat.request_body request);
  let second = Chat.create_request ~keeper_name:"keeper.one" ~message:"hello" () in
  check bool "fresh id per send" false
    (String.equal request.request_id second.request_id)

(* Since #33103 every projected frame carries id: <seq>. The strict decode
   reads events, not positions: a body with id lines decodes to exactly what
   the same body without them does. *)
let test_id_lines_do_not_change_the_strict_decode () =
  let events =
    [ acceptance (); run_started; text_start; delta "hel"; delta "lo"
    ; reply_details (); text_end; run_finished
    ]
  in
  let plain = events |> List.map sse_event |> String.concat "" in
  let with_ids =
    events
    |> List.mapi (fun seq event -> Printf.sprintf "id: %d\n%s" seq (sse_event event))
    |> String.concat ""
  in
  check bool "id lines classify as Sse_id" true
    (Chat.classify_sse_line "id: 12" = Chat.Sse_id 12);
  check bool "the frame end classifies on its own" true
    (Chat.classify_sse_line "" = Chat.Sse_frame_end);
  check bool "a non-integer id is ignored" true
    (Chat.classify_sse_line "id: abc" = Chat.Sse_ignored);
  check bool "same outcome with and without id lines" true
    (Chat.decode_response ~request plain = Chat.decode_response ~request with_ids);
  match Chat.decode_response ~request with_ids with
  | Ok (Chat.Turn_completed completed) ->
      check string "the reply is read through the id lines" "hello" completed.reply
  | Ok (Chat.Replayed_succeeded _) -> fail "replayed instead of completed"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_matching_acceptance_and_reply () =
  match
    decode
      [ acceptance (); run_started; text_start; delta "hel"; delta "lo"
      ; reply_details (); text_end; run_finished
      ]
  with
  | Ok (Chat.Turn_completed completed) ->
      check string "canonical reply details" "hello" completed.reply;
      check string "turn ref" "trace-chat#1" completed.turn_ref;
      check bool "visible outcome" true
        (completed.turn_outcome = Chat.Visible_reply);
      check int "queue count" 0 completed.acceptance.queued_count
  | Ok (Chat.Replayed_succeeded _) -> fail "live response classified as replay"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_acceptance_id_mismatch () =
  match decode [ acceptance ~operation_id:"other-request" () ] with
  | Error (Chat.Request_id_mismatch _) -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "mismatched request id was accepted"

let test_run_error_never_returns_partial_delta () =
  match
    decode
      [ acceptance (); run_started; text_start; delta "partial"
      ; run_error "provider failed"
      ]
  with
  | Error (Chat.Run_failed { accepted = true; message; _ }) ->
      check string "failure detail" "provider failed" message
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "partial delta hid RUN_ERROR"

let test_pre_acceptance_rejection () =
  match
    decode [ run_error ~accepted:false ~code:"invalid_input" "bad request" ]
  with
  | Error (Chat.Run_failed { accepted = false; code; _ }) ->
      check (option string) "rejection code" (Some "invalid_input") code
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "pre-acceptance RUN_ERROR was successful"

let test_interrupted_stream () =
  match decode [ acceptance (); run_started; text_start; delta "partial" ] with
  | Error (Chat.Stream_interrupted { accepted = true }) -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "unterminated stream was successful"

let test_finished_requires_reply_details () =
  match
    decode
      [ acceptance (); run_started; text_start; delta "partial"; text_end
      ; run_finished
      ]
  with
  | Error Chat.Missing_reply_details -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "RUN_FINISHED without reply details was successful"

let test_typed_nonvisible_outcomes () =
  let cases =
    [ "continuation_checkpoint", Chat.Continuation_checkpoint
    ; "external_effect_completed", Chat.Terminal_effect_settled
    ; "external_effect_pending", Chat.Awaiting_gate_approval
    ; "no_visible_reply", Chat.No_visible_reply
    ]
  in
  List.iter
    (fun (wire, expected) ->
       match
         decode
           [ acceptance ()
           ; run_started
           ; text_start
           ; reply_details ~reply:"" ~turn_outcome:wire ()
           ; text_end
           ; run_finished
           ]
       with
       | Ok (Chat.Turn_completed completed) ->
           check bool wire true (completed.turn_outcome = expected)
       | Ok (Chat.Replayed_succeeded _) -> fail (wire ^ " became replay")
       | Error error -> fail (Chat.stream_error_to_string error))
    cases

let test_media_only_visible_reply () =
  match
    decode
      [ acceptance (); run_started; text_start
      ; reply_details ~reply:"" ~turn_outcome:"visible_reply" ()
      ; text_end; run_finished
      ]
  with
  | Ok (Chat.Turn_completed completed) ->
      check string "media-only reply keeps empty text" "" completed.reply
  | Ok (Chat.Replayed_succeeded _) -> fail "media-only turn became replay"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_terminal_replay_states () =
  (match decode [ acceptance ~state:"Succeeded" () ] with
   | Ok (Chat.Replayed_succeeded _) -> ()
   | Ok (Chat.Turn_completed _) -> fail "terminal replay became live turn"
   | Error error -> fail (Chat.stream_error_to_string error));
  List.iter
    (fun (state, expected) ->
       match decode [ acceptance ~state () ] with
       | Error error when expected error -> ()
       | Error error -> fail (Chat.stream_error_to_string error)
       | Ok _ -> fail (state ^ " replay was successful"))
    [ "Failed", (function Chat.Replayed_failed -> true | _ -> false)
    ; "Cancelled", (function Chat.Replayed_cancelled -> true | _ -> false)
    ]

let test_terminal_replay_flushes_buffered_completion () =
  match
    decode
      [ acceptance ~state:"Succeeded" (); run_started; text_start
      ; reply_details ~reply:"buffered reply" (); text_end; run_finished
      ]
  with
  | Ok (Chat.Turn_completed completed) ->
      check string "buffered canonical reply" "buffered reply" completed.reply
  | Ok (Chat.Replayed_succeeded _) -> fail "buffered completion was discarded"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_current_wire_only () =
  let alias =
    event "content_delta"
      [ "runId", `String run_id
      ; "messageId", `String message_id
      ; "delta", `String "old"
      ]
  in
  check bool "old event alias is not accepted" true
    (Result.is_error
       (decode
          [ acceptance (); run_started; text_start; alias; reply_details ()
          ; text_end; run_finished
          ]));
  check bool "bare JSON is not accepted" true
    (Result.is_error
       (Chat.decode_response ~request
          {|{"result":{"text":"old"}}|}))

let test_lifecycle_identity_is_exact () =
  let mismatched_finish =
    event "RUN_FINISHED" [ "runId", `String "keeper-operation-run-other" ]
  in
  (match
     decode
       [ acceptance (); run_started; text_start; reply_details (); text_end
       ; mismatched_finish
       ]
   with
   | Error (Chat.Event_identity_mismatch { field = "runId"; _ }) -> ()
   | Error error -> fail (Chat.stream_error_to_string error)
   | Ok _ -> fail "mismatched run identity was accepted");
  let unknown_custom =
    event "CUSTOM"
      [ "runId", `String run_id; "name", `String "KEEPER_OLD_ALIAS"
      ; "value", `Null
      ]
  in
  match
    decode
      [ acceptance (); run_started; text_start; unknown_custom
      ; reply_details (); text_end; run_finished
      ]
  with
  | Error (Chat.Unknown_custom_event "KEEPER_OLD_ALIAS") -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "unknown custom event was accepted"

let test_runtime_attempt_requires_null_payload () =
  let malformed_runtime_attempt =
    event "CUSTOM"
      [ "runId", `String run_id
      ; "name", `String "KEEPER_RUNTIME_ATTEMPT_STARTED"
      ; "value", `Assoc []
      ]
  in
  match decode [ acceptance (); run_started; malformed_runtime_attempt ] with
  | Error (Chat.Malformed_event detail) ->
    check bool "the payload contract is named" true
      (String_util.contains_substring detail "value must be null")
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "non-null runtime-attempt payload was accepted"

let test_current_nonterminal_event_set () =
  let custom name =
    let value =
      if String.equal name "KEEPER_TOOL_RESULT_READY"
      then
        `Assoc
          [ "toolStreamScope", `Int 0
          ; "toolCallBlockIndex", `Int 0
          ; "toolCallId", `String "tool-1"
          ; "executionId", `String "exec-1"
          ]
      else if String.equal name "KEEPER_STREAM_PROTOCOL_ERROR" then
        `Assoc [ "kind", `String "sse_error" ]
      else if String.equal name "KEEPER_TOOL_APPROVAL_REQUESTED" then
        `Assoc
          [ "tool_call_id", `String "tool-1"
          ; "tool_call_name", `String "Read"
          ; "args", `String "{}"
          ; "question", `String "Run Read?"
          ]
      else if String.equal name "KEEPER_TOOL_APPROVAL_SETTLED" then
        `Assoc
          [ "tool_call_id", `String "tool-1"
          ; "outcome", `String "approved"
          ]
      else `Null
    in
    event "CUSTOM"
      [ "runId", `String run_id; "name", `String name; "value", value ]
  in
  let custom_names = Chat.current_custom_names in
  let tool_events =
    [ event "TOOL_CALL_START"
        [ "runId", `String run_id
        ; "toolStreamScope", `Int 0; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "tool-1"
        ; "toolCallName", `String "read"
        ]
    ; event "TOOL_CALL_ARGS"
        [ "runId", `String run_id
        ; "toolStreamScope", `Int 0; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "tool-1"
        ; "delta", `String "{}"
        ]
    ; event "TOOL_CALL_END"
        [ "runId", `String run_id
        ; "toolStreamScope", `Int 0; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "tool-1"
        ]
    ]
  in
  match
    decode
      ([ acceptance (); run_started; text_start ]
       @ tool_events
       @ List.map custom custom_names
       @ [ reply_details (); text_end; run_finished ])
  with
  | Ok (Chat.Turn_completed _) -> ()
  | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_tool_result_ready_requires_exact_canonical_identity () =
  let result_ready value =
    event "CUSTOM"
      [ "runId", `String run_id
      ; "name", `String "KEEPER_TOOL_RESULT_READY"
      ; "value", value
      ]
  in
  let invalid_values =
    [ `Null
    ; `Assoc
        [ "toolStreamScope", `Int 0; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "tool-1"
        ]
    ; `Assoc
        [ "toolStreamScope", `Int 0; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "tool-1"; "executionId", `String ""
        ]
    ; `Assoc
        [ "toolStreamScope", `Int 0; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "tool-1"
        ; "executionId", `String "exec-1"
        ; "provider_result", `String "not-part-of-the-contract"
        ]
    ]
  in
  List.iter
    (fun value ->
      match decode [ acceptance (); run_started; result_ready value ] with
      | Error (Chat.Malformed_event _) -> ()
      | Error error -> fail (Chat.stream_error_to_string error)
      | Ok _ -> fail "malformed KEEPER_TOOL_RESULT_READY was accepted")
    invalid_values

let tool_start ?(scope = 0) ?(block_index = 0) ?provider_message_id ~call_id
    ~name () =
  event "TOOL_CALL_START"
    ([ "runId", `String run_id
     ; "toolStreamScope", `Int scope
     ; "toolCallBlockIndex", `Int block_index
     ; "toolCallId", `String call_id
     ; "toolCallName", `String name
     ]
     @ Option.to_list
         (Option.map
            (fun value -> "providerMessageId", `String value)
            provider_message_id))
;;

let tool_result_ready ?(scope = 0) ?(block_index = 0) ?provider_message_id
    ~call_id ~execution_id () =
  event "CUSTOM"
    [ "runId", `String run_id
    ; "name", `String "KEEPER_TOOL_RESULT_READY"
    ; ( "value"
      , `Assoc
          ([ "toolStreamScope", `Int scope
           ; "toolCallBlockIndex", `Int block_index
           ; "toolCallId", `String call_id
           ; "executionId", `String execution_id
           ]
           @ Option.to_list
               (Option.map
                  (fun value -> "providerMessageId", `String value)
                  provider_message_id)) )
    ]
;;

let completed_tail = [ text_start; reply_details (); text_end; run_finished ]

let tool_quarantined ?(scope = 0) ?(block_index = 0) () =
  event "CUSTOM"
    [ "runId", `String run_id
    ; "name", `String "KEEPER_STREAM_PROTOCOL_ERROR"
    ; ( "value"
      , `Assoc
          [ "kind", `String "tool_replay_mismatch"
          ; ( "quarantined_occurrence"
            , `Assoc
                [ "toolStreamScope", `Int scope
                ; "toolCallBlockIndex", `Int block_index
                ] )
          ] )
    ]
;;

let test_tool_result_identity_is_occurrence_scoped_and_write_once () =
  let decode_completed middle =
    decode ([ acceptance (); run_started ] @ middle @ completed_tail)
  in
  (match
     decode_completed
       [ tool_start ~block_index:0 ~call_id:"reused" ~name:"Read" ()
       ; tool_result_ready ~block_index:0 ~call_id:"reused" ~execution_id:"exec-first" ()
       ; tool_start ~block_index:1 ~call_id:"reused" ~name:"Write" ()
       ; tool_result_ready ~block_index:0 ~call_id:"reused" ~execution_id:"exec-first" ()
       ; tool_result_ready ~block_index:1 ~call_id:"reused" ~execution_id:"exec-second" ()
       ]
   with
   | Ok (Chat.Turn_completed _) -> ()
   | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
   | Error error -> fail (Chat.stream_error_to_string error));
  (match
     decode_completed
       [ tool_start ~call_id:"call-once" ~name:"Read" ()
       ; tool_result_ready ~call_id:"call-once" ~execution_id:"exec-one" ()
       ; tool_result_ready ~call_id:"call-once" ~execution_id:"exec-one" ()
       ]
   with
   | Ok (Chat.Turn_completed _) -> ()
   | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
   | Error error -> fail (Chat.stream_error_to_string error));
  (match
     decode_completed
       [ tool_start ~call_id:"call-once" ~name:"Read" ()
       ; tool_result_ready ~call_id:"call-once" ~execution_id:"exec-one" ()
       ; tool_result_ready ~call_id:"call-once" ~execution_id:"exec-two" ()
       ]
   with
   | Error
       (Chat.Conflicting_tool_result
          { recorded_execution_id = "exec-one"
          ; received_execution_id = "exec-two"
          ; _
          }) ->
       ()
   | Error error -> fail (Chat.stream_error_to_string error)
   | Ok _ -> fail "conflicting canonical identity was accepted");
  (match
     decode_completed
       [ tool_start ~block_index:0 ~call_id:"first" ~name:"Read" ()
       ; tool_start ~block_index:1 ~call_id:"second" ~name:"Write" ()
       ; tool_result_ready ~block_index:0 ~call_id:"first"
           ~execution_id:"exec-reused" ()
       ; tool_result_ready ~block_index:1 ~call_id:"second"
           ~execution_id:"exec-reused" ()
       ]
   with
   | Error
       (Chat.Reused_tool_execution_id
          { execution_id = "exec-reused"
          ; recorded_occurrence =
              { stream_scope = 0; block_index = 0; provider_message_id = None }
          ; received_occurrence =
              { stream_scope = 0; block_index = 1; provider_message_id = None }
          }) ->
       ()
   | Error error -> fail (Chat.stream_error_to_string error)
   | Ok _ -> fail "one canonical execution was accepted for two occurrences");
  match
    decode_completed
      [ tool_start ~block_index:0 ~call_id:"duplicate" ~name:"Read" ()
      ; tool_start ~block_index:1 ~call_id:"duplicate" ~name:"Write" ()
      ; tool_result_ready ~block_index:1 ~call_id:"duplicate" ~execution_id:"exec-second" ()
      ]
  with
  | Ok (Chat.Turn_completed _) -> ()
  | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
  | Error error -> fail (Chat.stream_error_to_string error)
;;

let test_tool_metadata_and_quarantine_are_write_once () =
  let decode_completed middle =
    decode ([ acceptance (); run_started ] @ middle @ completed_tail)
  in
  let expect_protocol_error label events =
    match decode_completed events with
    | Error _ -> ()
    | Ok _ -> fail (label ^ " was accepted")
  in
  expect_protocol_error "changed tool name for one occurrence"
    [ tool_start ~call_id:"call-1" ~name:"Read" ()
    ; tool_start ~call_id:"call-1" ~name:"Write" ()
    ];
  expect_protocol_error "changed provider call id on an idempotent result"
    [ tool_start ~call_id:"call-1" ~name:"Read" ()
    ; tool_result_ready ~call_id:"call-1" ~execution_id:"exec-1" ()
    ; tool_result_ready ~call_id:"changed" ~execution_id:"exec-1" ()
    ];
  expect_protocol_error "changed provider message correlation"
    [ tool_start ~provider_message_id:"message-a" ~call_id:"call-1"
        ~name:"Read" ()
    ; tool_result_ready ~provider_message_id:"message-b" ~call_id:"call-1"
        ~execution_id:"exec-1" ()
    ];
  expect_protocol_error "arguments changed after canonical result"
    [ tool_start ~call_id:"call-1" ~name:"Read" ()
    ; tool_result_ready ~call_id:"call-1" ~execution_id:"exec-1" ()
    ; event "TOOL_CALL_ARGS"
        [ "runId", `String run_id
        ; "toolStreamScope", `Int 0
        ; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "call-1"
        ; "delta", `String "{\"changed\":true}"
        ]
    ];
  expect_protocol_error "result after quarantine"
    [ tool_start ~call_id:"call-1" ~name:"Read" ()
    ; tool_quarantined ()
    ; tool_result_ready ~call_id:"call-1" ~execution_id:"exec-1" ()
    ];
  expect_protocol_error "arguments after quarantine"
    [ tool_start ~call_id:"call-1" ~name:"Read" ()
    ; tool_quarantined ()
    ; event "TOOL_CALL_ARGS"
        [ "runId", `String run_id
        ; "toolStreamScope", `Int 0
        ; "toolCallBlockIndex", `Int 0
        ; "toolCallId", `String "call-1"
        ; "delta", `String {|{"late":true}|}
        ]
    ];
  (match
     decode_completed
       [ tool_start ~call_id:"call-1" ~name:"Read" ()
       ; tool_result_ready ~call_id:"call-1" ~execution_id:"exec-1" ()
       ; tool_quarantined ()
       ]
   with
   | Ok (Chat.Turn_completed _) -> ()
   | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
   | Error error ->
     fail
       ("quarantine after write-once result failed the whole stream: "
        ^ Chat.stream_error_to_string error));
  (match
     decode_completed
       [ tool_quarantined ()
       ; tool_start ~call_id:"call-1" ~name:"Read" ()
       ; tool_result_ready ~call_id:"call-1" ~execution_id:"exec-1" ()
       ]
   with
   | Ok (Chat.Turn_completed _) -> ()
   | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
   | Error error -> fail (Chat.stream_error_to_string error));
  expect_protocol_error "null protocol error payload"
    [ event "CUSTOM"
        [ "runId", `String run_id
        ; "name", `String "KEEPER_STREAM_PROTOCOL_ERROR"
        ; "value", `Null
        ]
    ]
;;

let test_finished_requires_text_end () =
  match
    decode
      [ acceptance (); run_started; text_start; reply_details (); run_finished ]
  with
  | Error Chat.Missing_text_end -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "RUN_FINISHED without TEXT_MESSAGE_END was successful"

let test_protocol_errors_preserve_acceptance_provenance () =
  let unknown_custom =
    event "CUSTOM"
      [ "runId", `String run_id; "name", `String "KEEPER_OLD_ALIAS"
      ; "value", `Null
      ]
  in
  let accepted_cases =
    [ "duplicate acceptance", [ acceptance (); acceptance () ]
    ; ( "duplicate reply details"
      , [ acceptance (); run_started; reply_details (); reply_details () ] )
    ; "duplicate run start", [ acceptance (); run_started; run_started ]
    ; "missing run start", [ acceptance (); text_start ]
    ; ( "missing reply details"
      , [ acceptance (); run_started; text_start; text_end; run_finished ] )
    ; ( "missing text end"
      , [ acceptance (); run_started; text_start; reply_details (); run_finished ] )
    ; ( "unknown custom event"
      , [ acceptance (); run_started; unknown_custom ] )
    ]
  in
  List.iter
    (fun (label, events) ->
       match decode_with_provenance events with
       | Error failure ->
           check bool (label ^ " retains acceptance") true
             failure.Chat.acceptance_observed;
           check bool (label ^ " reaches accepted recovery") true
             (Chat.error_acceptance_observed (Chat.Protocol_error failure))
       | Ok _ -> fail (label ^ " unexpectedly succeeded"))
    accepted_cases;
  List.iter
    (fun error ->
       check bool "public helper infers intrinsic acceptance" true
         (Chat.error_acceptance_observed (Chat.protocol_error error)))
    [ Chat.Duplicate_acceptance
    ; Chat.Duplicate_reply_details
    ; Chat.Unknown_custom_event "unknown"
    ; Chat.Duplicate_run_start
    ; Chat.Missing_run_start "TEXT_MESSAGE_START"
    ; Chat.Missing_reply_details
    ; Chat.Missing_text_end
    ];
  match Chat.decode_response_with_provenance ~request "data: {bad\n\n" with
  | Error failure ->
      check bool "pre-accept malformed stream has no acceptance" false
        failure.Chat.acceptance_observed
  | Ok _ -> fail "malformed pre-accept stream unexpectedly succeeded"

let test_terminal_text_sanitization () =
  let raw = "\027[31mred\027[0m\nnext\027]52;c;Y2xpcA==\007" in
  let safe = Chat.terminal_safe_text ~preserve_newlines:true raw in
  check bool "CSI introducer removed" false (String.contains safe '\027');
  check bool "OSC terminator removed" false (String.contains safe '\007');
  check bool "requested newline retained" true (String.contains safe '\n');
  check bool "visible payload retained" true
    (String.starts_with ~prefix:" [31mred [0m" safe)

let test_request_labels_keep_random_suffix () =
  let prefix = "tui-019d0000-0000-7000-8000-" in
  let first = Chat.compact_request_id (prefix ^ "aaaaaaaaaaaa") in
  let second = Chat.compact_request_id (prefix ^ "bbbbbbbbbbbb") in
  check bool "nearby UUIDv7 labels remain distinct" false
    (String.equal first second);
  check int "compact label width" 20 (String.length first)

let test_error_certainty () =
  check bool "transport is unverified" true
    (Chat.error_certainty (Chat.Transport_error "cut")
     = Chat.Outcome_unverified);
  List.iter
    (fun status ->
      let error : Chat.error = Chat.Http_error { status; body = "rejected" } in
      check bool
        (Printf.sprintf "HTTP %d before the handler is verified" status)
        true
        (Chat.error_certainty error = Chat.Verified_rejected))
    [ 400; 401; 403; 404 ];
  List.iter
    (fun status ->
      let error : Chat.error = Chat.Http_error { status; body = "ambiguous" } in
      check bool
        (Printf.sprintf "HTTP %d may follow upstream dispatch" status)
        true
        (Chat.error_certainty error = Chat.Outcome_unverified))
    [ 408; 409; 425; 429; 500; 502; 503; 504 ];
  let unauthorized : Chat.error =
    Chat.Http_error { status = 401; body = "unauthorized" }
  in
  check bool "uncertain reconnect keeps HTTP rejection unverified" true
    (Chat.error_certainty ~was_unverified:true unauthorized
     = Chat.Outcome_unverified);
  check bool "pre-accept rejection is verified" true
    (Chat.error_certainty
       (Chat.protocol_error
          (Chat.Run_failed
             { accepted = false; message = "bad"; code = Some "invalid_input" }))
     = Chat.Verified_rejected);
  check bool "ambiguous replay keeps invalid-input rejection unverified" true
    (Chat.error_certainty ~was_unverified:true
       (Chat.protocol_error
          (Chat.Run_failed
             { accepted = false; message = "bad"; code = Some "invalid_input" }))
     = Chat.Outcome_unverified);
  check bool "store uncertainty is not a verified rejection" true
    (Chat.error_certainty
       (Chat.protocol_error
          (Chat.Run_failed
             { accepted = false
             ; message = "store unavailable"
             ; code = Some "store_unavailable"
             }))
     = Chat.Outcome_unverified);
  check bool "changed-source idempotency conflict keeps the fence" true
    (Chat.error_certainty
       (Chat.protocol_error
          (Chat.Run_failed
             { accepted = false
             ; message = "idempotency conflict"
             ; code = Some "idempotency_conflict"
             }))
     = Chat.Outcome_unverified);
  check bool "uncertain retry keeps pre-accept rejection unverified" true
    (Chat.error_certainty ~was_unverified:true
       (Chat.protocol_error
          (Chat.Run_failed
             { accepted = false; message = "store unavailable"; code = None }))
     = Chat.Outcome_unverified);
  check bool "post-accept failure is verified" true
    (Chat.error_certainty
       (Chat.protocol_error
          (Chat.Run_failed
             { accepted = true; message = "failed"; code = None }))
     = Chat.Verified_failed)

let test_reader_unauthenticated () =
  List.iter
    (fun status ->
      let error : Chat.error = Chat.Http_error { status; body = "unauthorized" } in
      check bool
        (Printf.sprintf "HTTP %d means the reader could not ask" status)
        true
        (Chat.reader_unauthenticated error);
      (* The same status on the dispatch POST proves the operation was never
         created. A reconciliation read must not borrow that conclusion, so the
         two predicates are pinned together here: if someone collapses them,
         this pair stops disagreeing and the test fails. *)
      check bool
        (Printf.sprintf "HTTP %d still reads as a verified dispatch rejection" status)
        true
        (Chat.error_certainty error = Chat.Verified_rejected))
    [ 401; 403 ];
  List.iter
    (fun status ->
      let error : Chat.error = Chat.Http_error { status; body = "other" } in
      check bool
        (Printf.sprintf "HTTP %d is not an authentication failure" status)
        false
        (Chat.reader_unauthenticated error))
    [ 400; 404; 409; 500; 503 ];
  check bool "a cut transport is not an authentication failure" false
    (Chat.reader_unauthenticated (Chat.Transport_error "cut"));
  check bool "a protocol failure is not an authentication failure" false
    (Chat.reader_unauthenticated
       (Chat.protocol_error
          (Chat.Run_failed { accepted = false; message = "bad"; code = None })))

(* The chat surface renders a transport failure as two sentences: the caller's
   own reading of what it means for the turn, and this one's reading of where it
   happened. Both used to claim the outcome was unverified, so the line said it
   twice and pushed the cause -- the only part that changes between failures --
   to the far end, where the terminal truncated it. *)
let test_transport_error_names_the_cause_not_the_certainty () =
  let cause = "Connection Error: Failed connecting to 127.0.0.1: connection refused" in
  let rendered = Chat.error_to_string (Chat.Transport_error cause) in
  let has needle = String_util.string_contains_substring ~needle rendered in
  check bool "the cause survives" true (has cause);
  check bool "the certainty is not restated here" false (has "unverified");
  (* [Transport_error] is always [Outcome_unverified], so the caller that
     renders certainty always speaks -- this one never has to. *)
  check bool "transport failures are always unverified" true
    (Chat.error_certainty (Chat.Transport_error cause) = Chat.Outcome_unverified)
;;

let test_reconciliation_failure_detail () =
  let refused : Chat.error =
    Chat.Http_error
      { status = 401
      ; body = {|{"error":"[AuthError] Unauthorized","auth_error_code":"missing_token"}|}
      }
  in
  let has needle detail =
    String_util.string_contains_substring ~needle detail
  in
  (* Without a bearer the operator has none to present. *)
  let absent = Chat.reconciliation_failure_detail ~credential_sent:false refused in
  check bool "an absent credential is named as absent" true
    (has "holds no operator token" absent);
  check bool "an absent credential is not called refused" false
    (has "was refused" absent);
  (* With one, the server rejected what it was given -- telling the operator to
     provide a token would be advice they have already followed. *)
  let rejected = Chat.reconciliation_failure_detail ~credential_sent:true refused in
  check bool "a rejected credential is named as rejected" true
    (has "was refused" rejected);
  check bool "a rejected credential is not called absent" false
    (has "holds no operator token" rejected);
  List.iter
    (fun (label, detail) ->
      check bool (label ^ " names the command that mints one") true
        (has "masc login" detail);
      check bool (label ^ " says the operation survives") true
        (has "untouched on the server" detail);
      check bool (label ^ " does not paste the server body") false
        (has "auth_error_code" detail))
    [ ("absent", absent); ("rejected", rejected) ];
  let upstream : Chat.error =
    Chat.Http_error { status = 503; body = "owner_stopping" }
  in
  List.iter
    (fun credential_sent ->
      let detail =
        Chat.reconciliation_failure_detail ~credential_sent upstream
      in
      check bool "every other failure keeps the server words" true
        (has "owner_stopping" detail);
      check bool "every other failure does not blame the credential" false
        (has "masc login" detail))
    [ true; false ]

let operation_json state fields =
  let input =
    Masc.Keeper_chat_operation_payload.input_to_json
      ~message:request.message
      ~user_blocks:[]
      ~turn_instructions:None
      ~surface_context:None
      ~attachments:[]
  in
  let execution_digest =
    match Keeper_chat_operation.execution_digest input with
    | Ok digest -> digest
    | Error detail -> fail detail
  in
  `Assoc
    ([ "schema", `String "masc.keeper_chat_operation.v1"
     ; "operation_id", `String request.request_id
     ; "sequence", `String "7"
     ; "created_at", `Float 1.0
     ; "execution_digest", `String execution_digest
     ; "source", `Assoc []
     ; "input", input
     ; "state", `String state
     ]
     @ fields)

let test_operation_reconciliation_projection () =
  (match
     Chat.decode_operation_reconciliation ~request
       (operation_json "Running" [ "started_at", `Float 2.0 ])
   with
   | Ok (Chat.Operation_pending Chat.Running) -> ()
   | Ok _ -> fail "running operation projected to the wrong state"
   | Error error -> fail (Chat.stream_error_to_string error));
  (match
     Chat.decode_operation_reconciliation ~request
       (operation_json "Succeeded"
          [ "completed_at", `Float 3.0; "outcome_ref", `String "turn#9" ])
   with
   | Ok (Chat.Operation_succeeded { outcome_ref = "turn#9" }) -> ()
   | Ok _ -> fail "succeeded operation projected to the wrong state"
   | Error error -> fail (Chat.stream_error_to_string error));
  (match
     Chat.decode_operation_reconciliation ~request
       (operation_json "Failed"
          [ "completed_at", `Float 3.0
          ; "failure_kind", `String "Turn_exception"
          ; "failure_detail", `String "provider failed"
          ; "outcome_ref", `Null
          ])
   with
   | Ok
       (Chat.Operation_failed
         { failure_kind = "Turn_exception"; detail = "provider failed"; _ }) ->
       ()
   | Ok _ -> fail "failed operation projected to the wrong state"
   | Error error -> fail (Chat.stream_error_to_string error));
  match
    Chat.decode_operation_reconciliation ~request
      (operation_json "Cancelled" [ "completed_at", `Float 3.0 ])
  with
  | Ok Chat.Operation_cancelled -> ()
  | Ok _ -> fail "cancelled operation projected to the wrong state"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_operation_reconciliation_uses_server_canonical_message () =
  let request_with_whitespace = { request with message = "  hello \n" } in
  match
    Chat.decode_operation_reconciliation ~request:request_with_whitespace
      (operation_json "Running" [ "started_at", `Float 2.0 ])
  with
  | Ok (Chat.Operation_pending Chat.Running) -> ()
  | Ok _ -> fail "canonical operation projected to the wrong state"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_stale_completion_identity () =
  let current : Chat.request =
    { request_id = "tui-current"; keeper_name = "keeper.one"; message = "one"; attachments = [] }
  in
  let same = { current with message = "same identity" } in
  let stale = { current with request_id = "tui-stale" } in
  let wrong_keeper = { current with keeper_name = "keeper.two" } in
  check bool "changed message rejected" false
    (Chat.same_request_identity current same);
  check bool "stale request rejected" false
    (Chat.same_request_identity current stale);
  check bool "wrong keeper rejected" false
    (Chat.same_request_identity current wrong_keeper)

let test_operation_reconciliation_binds_original_input () =
  let valid = operation_json "Running" [ "started_at", `Float 2.0 ] in
  let replace name value = function
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (field, current) ->
               if String.equal field name then field, value else field, current)
             fields)
    | _ -> fail "operation fixture must be an object"
  in
  let changed_input =
    Masc.Keeper_chat_operation_payload.input_to_json
      ~message:"different message"
      ~user_blocks:[]
      ~turn_instructions:None
      ~surface_context:None
      ~attachments:[]
  in
  (match
     Chat.decode_operation_reconciliation ~request
       (replace "input" changed_input valid)
   with
   | Error (Chat.Event_identity_mismatch { field = "input"; _ }) -> ()
   | Error error -> fail (Chat.stream_error_to_string error)
   | Ok _ -> fail "changed durable input matched the original request");
  (match
     Chat.decode_operation_reconciliation ~request
       (replace "execution_digest" (`String "wrong-digest") valid)
   with
   | Error (Chat.Event_identity_mismatch { field = "execution_digest"; _ }) -> ()
   | Error error -> fail (Chat.stream_error_to_string error)
   | Ok _ -> fail "wrong durable execution digest matched the original request");
  match
    Chat.decode_operation_reconciliation ~request (replace "input" `Null valid)
  with
  | Ok (Chat.Operation_pending Chat.Running) -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "digest-bound redacted operation projected to the wrong state"


(* A one-pixel PNG. The bytes matter: the media type is read from them, so a
   fixture that only looks like a PNG by filename would pass a test the real
   path fails. *)
let png_bytes =
  "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06"
;;

let with_temp_file ~suffix contents f =
  let path = Filename.temp_file "masc-tui-attach-" suffix in
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel;
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> f path)
;;

(* The endpoint resolves an image by attachment_id from user_blocks; an
   attachment no block names is carried and never read. Both halves have to be
   on the wire or the keeper receives a text-only turn while the operator sees
   an attached image. *)
let test_attachment_reaches_both_wire_fields () =
  let attachment =
    { Chat.attachment_id = "att-1"
    ; name = "probe.png"
    ; mime_type = "image/png"
    ; size = 12
    ; data = "AAAA"
    }
  in
  let request =
    Chat.create_request ~attachments:[ attachment ] ~keeper_name:"k" ~message:"look" ()
  in
  let json = Chat.request_to_yojson request in
  let member name = Yojson.Safe.Util.member name json in
  (match member "attachments" with
   | `List [ one ] ->
     Alcotest.(check string)
       "attachment id"
       "att-1"
       (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "id" one))
   | other ->
     Alcotest.failf "attachments should carry one entry, got %s" (Yojson.Safe.to_string other));
  match member "user_blocks" with
  | `List [ image; text ] ->
    Alcotest.(check string)
      "block references the attachment"
      "att-1"
      (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "attachment_id" image));
    Alcotest.(check string)
      "image leads the blocks"
      "image"
      (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "type" image));
    Alcotest.(check string)
      "message text follows"
      "look"
      (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "text" text))
  | other ->
    Alcotest.failf "user_blocks should be image then text, got %s" (Yojson.Safe.to_string other)
;;

(* A request with nothing staged keeps the shape it always had, so a text-only
   turn is byte-identical to what this surface sent before attachments existed. *)
let test_no_attachment_sends_no_multimodal_fields () =
  let json = Chat.request_to_yojson (Chat.create_request ~keeper_name:"k" ~message:"hi" ()) in
  Alcotest.(check bool)
    "no attachments key"
    true
    (Yojson.Safe.Util.member "attachments" json = `Null);
  Alcotest.(check bool)
    "no user_blocks key"
    true
    (Yojson.Safe.Util.member "user_blocks" json = `Null)
;;

let test_media_type_comes_from_bytes_not_extension () =
  with_temp_file ~suffix:".txt" png_bytes (fun path ->
    match Masc_tui_attachment.of_file ~path with
    | Error error ->
      Alcotest.failf "a PNG named .txt should attach: %s"
        (Masc_tui_attachment.error_to_string error)
    | Ok attachment ->
      Alcotest.(check string) "sniffed media type" "image/png" attachment.Chat.mime_type;
      Alcotest.(check int) "size is the file's" (String.length png_bytes) attachment.Chat.size;
      Alcotest.(check string)
        "data is raw base64, no data-url prefix"
        (Base64.encode_string png_bytes)
        attachment.Chat.data)
;;

(* Bytes that never had a path -- what the clipboard hands over. The name is
   the operator's label and the endpoint's filename; the media type still
   comes from the bytes, so a clipboard holding something that is not an image
   is refused here rather than at the provider. *)
let test_clipboard_bytes_attach_under_their_own_name () =
  match Masc_tui_attachment.of_bytes ~name:"image-1.png" png_bytes with
  | Error error ->
    Alcotest.failf "clipboard PNG should attach: %s"
      (Masc_tui_attachment.error_to_string error)
  | Ok attachment ->
    Alcotest.(check string) "name is the one given" "image-1.png" attachment.Chat.name;
    Alcotest.(check string) "sniffed media type" "image/png" attachment.Chat.mime_type;
    Alcotest.(check int) "size is the bytes'" (String.length png_bytes) attachment.Chat.size
;;

let test_clipboard_bytes_that_are_not_an_image_are_refused () =
  match Masc_tui_attachment.of_bytes ~name:"image-1.png" "this is not an image" with
  | Ok _ -> Alcotest.fail "non-image clipboard bytes must not attach"
  | Error error ->
    Alcotest.(check bool)
      "the error names what was refused, not a path that does not exist"
      true
      (String_util.contains_substring
         (Masc_tui_attachment.error_to_string error)
         "image-1.png")
;;

let test_non_image_is_rejected_by_its_bytes () =
  with_temp_file ~suffix:".png" "this is not an image" (fun path ->
    match Masc_tui_attachment.of_file ~path with
    | Ok _ -> Alcotest.fail "a text file named .png must not attach"
    | Error error ->
      Alcotest.(check bool)
        "error names the admitted set"
        true
        (String_util.contains_substring
           (Masc_tui_attachment.error_to_string error)
           "image/png"))
;;

(* A drop has three answers and they are not interchangeable. An image is
   staged; a source file keeps its path, because naming it is why it was
   dropped; an image that cannot be staged says so, because answering a drop
   with a filename hides that the image was refused. *)
let test_a_dropped_image_is_staged () =
  with_temp_file ~suffix:".png" png_bytes (fun path ->
    match Masc_tui_attachment.classify_drop ~path with
    | Masc_tui_attachment.Attach attachment ->
      Alcotest.(check string) "media type" "image/png" attachment.Chat.mime_type
    | Masc_tui_attachment.Keep_path -> Alcotest.fail "an image should attach, not keep its path"
    | Masc_tui_attachment.Refuse error ->
      Alcotest.failf "an image should attach: %s" (Masc_tui_attachment.error_to_string error))
;;

let test_a_dropped_non_image_keeps_its_path () =
  with_temp_file ~suffix:".ml" "let () = print_endline \"hi\"" (fun path ->
    match Masc_tui_attachment.classify_drop ~path with
    | Masc_tui_attachment.Keep_path -> ()
    | Masc_tui_attachment.Attach _ -> Alcotest.fail "a source file must not attach"
    | Masc_tui_attachment.Refuse _ ->
      Alcotest.fail "a source file is not a refused image; its path is the point")
;;

let test_an_unstageable_image_is_refused_not_pathed () =
  with_temp_file ~suffix:".png" "" (fun path ->
    match Masc_tui_attachment.classify_drop ~path with
    | Masc_tui_attachment.Refuse _ -> ()
    | Masc_tui_attachment.Attach _ -> Alcotest.fail "an empty file must not attach"
    | Masc_tui_attachment.Keep_path ->
      Alcotest.fail "an empty .png should say so, not silently become a path")
;;

let test_missing_file_is_named_in_the_error () =
  match Masc_tui_attachment.of_file ~path:"/nonexistent/masc-attach-probe.png" with
  | Ok _ -> Alcotest.fail "a missing path must not attach"
  | Error error ->
    Alcotest.(check bool)
      "error names the path"
      true
      (String_util.contains_substring
         (Masc_tui_attachment.error_to_string error)
         "masc-attach-probe.png")
;;

let () =
  run "tui_keeper_chat_projection"
    [ ( "keeper chat"
      , [ test_case "exact request body and UUIDv7" `Quick
            test_request_body_and_identity
        ; test_case "id lines do not change the strict decode" `Quick
            test_id_lines_do_not_change_the_strict_decode
        ; test_case "matching acceptance and reply" `Quick
            test_matching_acceptance_and_reply
        ; test_case "acceptance id mismatch" `Quick
            test_acceptance_id_mismatch
        ; test_case "RUN_ERROR beats partial delta" `Quick
            test_run_error_never_returns_partial_delta
        ; test_case "pre-acceptance rejection" `Quick
            test_pre_acceptance_rejection
        ; test_case "interrupted stream" `Quick test_interrupted_stream
        ; test_case "finished requires reply details" `Quick
            test_finished_requires_reply_details
        ; test_case "typed non-visible outcomes" `Quick
            test_typed_nonvisible_outcomes
        ; test_case "media-only visible reply" `Quick
            test_media_only_visible_reply
        ; test_case "terminal replay states" `Quick test_terminal_replay_states
        ; test_case "terminal replay flushes buffered completion" `Quick
            test_terminal_replay_flushes_buffered_completion
        ; test_case "current wire only" `Quick test_current_wire_only
        ; test_case "exact lifecycle identities" `Quick
            test_lifecycle_identity_is_exact
        ; test_case "runtime attempt requires null payload" `Quick
            test_runtime_attempt_requires_null_payload
        ; test_case "current nonterminal event set" `Quick
            test_current_nonterminal_event_set
        ; test_case "tool result requires exact canonical identity" `Quick
            test_tool_result_ready_requires_exact_canonical_identity
        ; test_case "tool result identity is scoped and write-once" `Quick
            test_tool_result_identity_is_occurrence_scoped_and_write_once
        ; test_case "tool metadata and quarantine are write-once" `Quick
            test_tool_metadata_and_quarantine_are_write_once
        ; test_case "finished requires text end" `Quick
            test_finished_requires_text_end
        ; test_case "protocol errors preserve acceptance provenance" `Quick
            test_protocol_errors_preserve_acceptance_provenance
        ; test_case "terminal text sanitization" `Quick
            test_terminal_text_sanitization
        ; test_case "request labels keep random suffix" `Quick
            test_request_labels_keep_random_suffix
        ; test_case "typed error certainty" `Quick test_error_certainty
        ; test_case "unauthenticated reader keeps the operation open" `Quick
            test_reader_unauthenticated
        ; test_case "transport error names the cause, not the certainty" `Quick
            test_transport_error_names_the_cause_not_the_certainty
        ; test_case "reconciliation failure detail" `Quick
            test_reconciliation_failure_detail
        ; test_case "operation reconciliation projection" `Quick
            test_operation_reconciliation_projection
        ; test_case "operation reconciliation uses server-canonical message" `Quick
            test_operation_reconciliation_uses_server_canonical_message
        ; test_case "operation reconciliation binds original input" `Quick
            test_operation_reconciliation_binds_original_input
        ; test_case "stale completion identity" `Quick
            test_stale_completion_identity
        ] )
    ; ( "attachments"
      , [ test_case "attachment reaches both wire fields" `Quick
            test_attachment_reaches_both_wire_fields
        ; test_case "no attachment sends no multimodal fields" `Quick
            test_no_attachment_sends_no_multimodal_fields
        ; test_case "media type comes from bytes" `Quick
            test_media_type_comes_from_bytes_not_extension
        ; test_case "non-image is rejected" `Quick
            test_non_image_is_rejected_by_its_bytes
        ; test_case "clipboard bytes attach under their own name" `Quick
            test_clipboard_bytes_attach_under_their_own_name
        ; test_case "clipboard bytes that are not an image are refused" `Quick
            test_clipboard_bytes_that_are_not_an_image_are_refused
        ; test_case "missing file is named" `Quick
            test_missing_file_is_named_in_the_error
        ; test_case "a dropped image is staged" `Quick
            test_a_dropped_image_is_staged
        ; test_case "a dropped non-image keeps its path" `Quick
            test_a_dropped_non_image_keeps_its_path
        ; test_case "an unstageable image is refused" `Quick
            test_an_unstageable_image_is_refused_not_pathed
        ] )
    ]
