open Alcotest

module Chat = Masc_tui_keeper_chat_projection

let json_string json = Yojson.Safe.to_string json
let sse_event json = "data: " ^ json_string json ^ "\n\n"

let request : Chat.request =
  { request_id = "tui-request-1";
    keeper_name = "keeper.one";
    message = "hello";
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

let test_request_body_and_identity () =
  let request = Chat.create_request ~keeper_name:"keeper.one" ~message:"hello" in
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
  let second = Chat.create_request ~keeper_name:"keeper.one" ~message:"hello" in
  check bool "fresh id per send" false
    (String.equal request.request_id second.request_id)

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
    ; "external_effect_completed", Chat.External_effect_completed
    ; "external_effect_pending", Chat.External_effect_pending
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

let test_current_nonterminal_event_set () =
  let custom name =
    event "CUSTOM"
      [ "runId", `String run_id; "name", `String name; "value", `Null ]
  in
  let custom_names =
    [ "KEEPER_CONNECTED"; "KEEPER_STREAM_MESSAGE_START"
    ; "KEEPER_STREAM_MESSAGE_DELTA"; "KEEPER_STREAM_MESSAGE_STOP"
    ; "KEEPER_STREAM_PING"; "KEEPER_CONTENT_BLOCK_START"
    ; "KEEPER_CONTENT_BLOCK_STOP"; "KEEPER_THINKING_DELTA"
    ; "KEEPER_THINKING_SIGNATURE_DELTA"; "KEEPER_MEDIA_DELTA"
    ; "KEEPER_STREAM_PROTOCOL_ERROR"; "KEEPER_CONTINUATION_CHECKPOINT"
    ; "KEEPER_EXTERNAL_EFFECT_COMPLETED"; "KEEPER_TOOL_RESULT_READY"
    ]
  in
  let tool_events =
    [ event "TOOL_CALL_START"
        [ "runId", `String run_id; "toolCallId", `String "tool-1"
        ; "toolCallName", `String "read"
        ]
    ; event "TOOL_CALL_ARGS"
        [ "runId", `String run_id; "toolCallId", `String "tool-1"
        ; "delta", `String "{}"
        ]
    ; event "TOOL_CALL_END"
        [ "runId", `String run_id; "toolCallId", `String "tool-1" ]
    ]
  in
  match
    decode
      ([ acceptance (); run_started; text_start ]
       @ List.map custom custom_names
       @ tool_events
       @ [ reply_details (); text_end; run_finished ])
  with
  | Ok (Chat.Turn_completed _) -> ()
  | Ok (Chat.Replayed_succeeded _) -> fail "live stream became replay"
  | Error error -> fail (Chat.stream_error_to_string error)

let test_finished_requires_text_end () =
  match
    decode
      [ acceptance (); run_started; text_start; reply_details (); run_finished ]
  with
  | Error Chat.Missing_text_end -> ()
  | Error error -> fail (Chat.stream_error_to_string error)
  | Ok _ -> fail "RUN_FINISHED without TEXT_MESSAGE_END was successful"

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
  check int "compact label width" 14 (String.length first)

let test_error_certainty () =
  check bool "transport is unverified" true
    (Chat.error_certainty (Chat.Transport_error "cut")
     = Chat.Outcome_unverified);
  check bool "pre-accept rejection is verified" true
    (Chat.error_certainty
       (Chat.Protocol_error
          (Chat.Run_failed
             { accepted = false; message = "bad"; code = Some "invalid_input" }))
     = Chat.Verified_rejected);
  check bool "store uncertainty is not a verified rejection" true
    (Chat.error_certainty
       (Chat.Protocol_error
          (Chat.Run_failed
             { accepted = false
             ; message = "store unavailable"
             ; code = Some "store_unavailable"
             }))
     = Chat.Outcome_unverified);
  check bool "uncertain retry keeps pre-accept rejection unverified" true
    (Chat.error_certainty ~was_unverified:true
       (Chat.Protocol_error
          (Chat.Run_failed
             { accepted = false; message = "store unavailable"; code = None }))
     = Chat.Outcome_unverified);
  check bool "post-accept failure is verified" true
    (Chat.error_certainty
       (Chat.Protocol_error
          (Chat.Run_failed
             { accepted = true; message = "failed"; code = None }))
     = Chat.Verified_failed)

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
    { request_id = "tui-current"; keeper_name = "keeper.one"; message = "one" }
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

let () =
  run "tui_keeper_chat_projection"
    [ ( "keeper chat"
      , [ test_case "exact request body and UUIDv7" `Quick
            test_request_body_and_identity
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
        ; test_case "current nonterminal event set" `Quick
            test_current_nonterminal_event_set
        ; test_case "finished requires text end" `Quick
            test_finished_requires_text_end
        ; test_case "terminal text sanitization" `Quick
            test_terminal_text_sanitization
        ; test_case "request labels keep random suffix" `Quick
            test_request_labels_keep_random_suffix
        ; test_case "typed error certainty" `Quick test_error_certainty
        ; test_case "operation reconciliation projection" `Quick
            test_operation_reconciliation_projection
        ; test_case "operation reconciliation uses server-canonical message" `Quick
            test_operation_reconciliation_uses_server_canonical_message
        ; test_case "operation reconciliation binds original input" `Quick
            test_operation_reconciliation_binds_original_input
        ; test_case "stale completion identity" `Quick
            test_stale_completion_identity
        ] )
    ]
