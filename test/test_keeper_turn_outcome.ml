(* RFC-0232 P2: producer-typed turn outcome.

   The reply payload's [turn_outcome] field is the only carrier of the
   checkpoint/visible/no-visible distinction; the legacy "Continuation
   checkpoint saved;" prefix sniff is deleted.  These tests pin:
   - the closed label codec (round-trip, unknown -> None),
   - the stop_reason -> outcome mapping (single mapping site),
   - response_text-aware result-surface classification,
   - payload decode policy: absent/malformed/unknown fails closed,
   - prefix deadness: checkpoint-shaped reply TEXT alone never
     classifies as a checkpoint. *)

open Alcotest

module TO = Masc.Keeper_turn_outcome
module Ops = Masc.Keeper_tool_surface_ops
module Stream = Server_routes_http_keeper_stream
module Response_text = Masc.Keeper_agent_run_response_text

let outcome : TO.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (TO.to_label t))
    TO.equal

let all =
  [ TO.Visible_reply
  ; TO.Continuation_checkpoint
  ; TO.External_effect_pending
  ; TO.No_visible_reply
  ]

let test_label_round_trip () =
  List.iter
    (fun t ->
      check (option outcome) "of_label (to_label t) = Some t"
        (Some t)
        (TO.of_label (TO.to_label t)))
    all

let test_unknown_label_is_none () =
  List.iter
    (fun label ->
      check (option outcome) label None (TO.of_label label))
    [ ""; "completed"; "checkpoint"; "Visible_reply"; "VISIBLE_REPLY" ]

let test_of_stop_reason () =
  let request : Agent_sdk.Error.input_required =
    { request_id = "outcome-input-1"
    ; participant_name = None
    ; question = "Which repository?"
    ; schema = None
    ; timeout_s = None
    ; created_at = 1_000.0
    }
  in
  check outcome "completed -> visible" TO.Visible_reply
    (TO.of_stop_reason Runtime_agent.Completed);
  check outcome "chat yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_to_chat_waiting { turns_used = 2 }));
  check outcome "durable stimulus yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_to_durable_stimulus { turns_used = 2 }));
  check outcome "external effect wait -> typed pending" TO.External_effect_pending
    (TO.of_stop_reason
       (Runtime_agent.Awaiting_external_effect { turns_used = 2 }));
  check outcome "repeated tool yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_after_repeated_tool_call
          { turns_used = 2
          ; tool_name = "keeper_tasks_list"
          ; repeated_count = 3
          }));
  check outcome "typed input required -> visible" TO.Visible_reply
    (TO.of_stop_reason
       (Runtime_agent.InputRequired { turns_used = 2; request }))

let test_of_result_surface () =
  check outcome "completed with text -> visible" TO.Visible_reply
    (TO.of_result_surface ~response_text:"done" Runtime_agent.Completed);
  check outcome "completed with empty text -> no visible reply"
    TO.No_visible_reply
    (TO.of_result_surface ~response_text:"   " Runtime_agent.Completed)

let test_external_effect_wait_is_typed_status () =
  let stop_reason = Runtime_agent.Awaiting_external_effect { turns_used = 2 } in
  check bool "external effect prose is suppressed" true
    (Response_text.stop_reason_suppresses_visible_response stop_reason);
  check outcome "external effect remains typed with blank text"
    TO.External_effect_pending
    (TO.of_result_surface ~response_text:"" stop_reason)

let test_external_effect_status_survives_server_projection () =
  let turn_outcome =
    TO.of_result_surface
      ~response_text:""
      (Runtime_agent.Awaiting_external_effect { turns_used = 2 })
  in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"gate-ack" ~absolute_turn:2 in
  let body =
    `Assoc
      [ "reply", `String ""
      ; TO.wire_key, `String (TO.to_label turn_outcome)
      ; TO.turn_ref_wire_key, Ids.Turn_ref.to_yojson turn_ref
      ]
    |> Yojson.Safe.to_string
  in
  match
    Stream.For_testing.canonical_reply_payload_of_body ~redact_text:Fun.id body
  with
  | Error error ->
    fail
      (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
         error)
  | Ok canonical ->
    check outcome "server preserves typed Gate wait" TO.External_effect_pending
      canonical.turn_outcome;
    check string "server keeps control status out of reply text" "" canonical.visible_reply;
    check (option string) "server accepts typed control status without prose"
      None
      (Stream.For_testing.direct_reply_terminal_error
         (Some canonical.payload_json)
         canonical.visible_reply);
    match
      Stream.For_testing.queued_delivery_outcome_of_turn_ref
        (Some canonical.turn_ref)
    with
    | Stream.Delivered { outcome_ref } ->
      check string "typed Gate wait keeps the exact turn ref"
        (Ids.Turn_ref.to_string turn_ref)
        outcome_ref
    | Stream.Failed _ | Stream.Deferred _ ->
      fail "typed Gate wait did not remain deliverable for a queued turn"

let test_external_effect_status_becomes_persisted_chat_block () =
  match
    Stream.For_testing.persisted_reply_blocks
      ~turn_outcome:TO.External_effect_pending
      None
  with
  | Some
      [ Masc.Keeper_chat_blocks.Status
          { kind = Masc.Keeper_chat_blocks.External_effect_pending }
      ] ->
    ()
  | Some _ -> fail "typed Gate wait persisted the wrong block shape"
  | None -> fail "typed Gate wait did not persist a status block"

let test_continuation_status_becomes_persisted_chat_block () =
  match
    Stream.For_testing.persisted_reply_blocks
      ~turn_outcome:TO.Continuation_checkpoint
      None
  with
  | Some
      [ Masc.Keeper_chat_blocks.Status
          { kind = Masc.Keeper_chat_blocks.Continuation_checkpoint }
      ] ->
    ()
  | Some _ -> fail "typed continuation persisted the wrong block shape"
  | None -> fail "typed continuation did not persist a status block"

let test_terminal_effect_defer_kinds_remain_distinct () =
  let expect_yield label state expected =
    match Masc.Keeper_agent_run.terminal_effect_boundary_decision state with
    | Ok (Runtime_agent.Yield actual) ->
      check string label expected
        (match actual with
         | Runtime_agent.Durable_stimulus_waiting -> "durable_stimulus_waiting"
         | Runtime_agent.External_effect_deferred -> "external_effect_deferred"
         | Runtime_agent.Chat_waiting -> "chat_waiting"
         | Runtime_agent.Repeated_tool_call _ -> "repeated_tool_call"
         | Runtime_agent.Terminal_tool_completed -> "terminal_tool_completed")
    | Ok Runtime_agent.Continue -> fail (label ^ " unexpectedly continued")
    | Error error -> fail (label ^ ": " ^ Agent_sdk.Error.to_string error)
  in
  expect_yield
    "generic deferred tool preserves existing checkpoint"
    Masc.Keeper_tools_oas.Deferred_tool_result
    "durable_stimulus_waiting";
  expect_yield
    "typed external effect uses Gate acknowledgement path"
    Masc.Keeper_tools_oas.External_effect_deferred
    "external_effect_deferred"

let tool_call ?(input = Some "input") ?(output = Some "output") tool_name
    : Masc.Keeper_agent_result.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome = "ok"
  ; execution_outcome = Tool_result.Ok
  ; typed_outcome = None
  ; latency_ms = 1.
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = input
  ; output_fingerprint = output
  }

let test_repeated_exact_tool_call_boundary () =
  let detect =
    Masc.Keeper_agent_run.For_testing.repeated_exact_tool_call ~threshold:3
  in
  check (option (pair string int)) "three exact calls yield"
    (Some ("keeper_tasks_list", 3))
    (detect
       [ tool_call "keeper_tasks_list"
       ; tool_call "keeper_tasks_list"
       ; tool_call "keeper_tasks_list"
       ]);
  check (option (pair string int)) "changed output proves progress" None
    (detect
       [ tool_call ~output:(Some "new") "keeper_tasks_list"
       ; tool_call ~output:(Some "old") "keeper_tasks_list"
       ; tool_call ~output:(Some "old") "keeper_tasks_list"
       ]);
  check (option (pair string int)) "missing fingerprints never guess" None
    (detect
       [ tool_call ~input:None "keeper_tasks_list"
       ; tool_call ~input:None "keeper_tasks_list"
       ; tool_call ~input:None "keeper_tasks_list"
       ])

let test_autonomous_yield_boundary_contract () =
  let module F = Masc.Keeper_agent_run.For_testing in
  let chat : Masc.Keeper_agent_run.autonomous_yield_request =
    { reason = Masc.Keeper_agent_run.Chat_waiting }
  in
  let durable_stimulus : Masc.Keeper_agent_run.autonomous_yield_request =
    { reason =
        Masc.Keeper_agent_run.Durable_stimulus_waiting
          { pending_count = 1
          ; head = None
          ; head_age_sec = 0.
          ; kinds = [ Keeper_event_queue.Bootstrap ]
          }
    }
  in
  (match F.runtime_yield_reason chat with
    | Runtime_agent.Chat_waiting -> ()
    | Runtime_agent.Durable_stimulus_waiting
    | Runtime_agent.External_effect_deferred
    | Runtime_agent.Repeated_tool_call _
   | Runtime_agent.Terminal_tool_completed ->
     fail "chat request mapped to the durable reason");
  (match F.runtime_yield_reason durable_stimulus with
    | Runtime_agent.Durable_stimulus_waiting -> ()
    | Runtime_agent.Chat_waiting
    | Runtime_agent.External_effect_deferred
   | Runtime_agent.Repeated_tool_call _
   | Runtime_agent.Terminal_tool_completed ->
     fail "durable request mapped to the chat reason");
  check bool "repeated exact call yield preserves its evidence" true
    (match
       Runtime_agent.For_testing.stop_reason_of_cooperative_yield
         ~turns_used:8
         (Runtime_agent.Repeated_tool_call
            { tool_name = "keeper_tasks_list"; repeated_count = 3 })
     with
     | Runtime_agent.Yielded_after_repeated_tool_call
         { turns_used = 8
         ; tool_name = "keeper_tasks_list"
         ; repeated_count = 3
         } ->
       true
     | Runtime_agent.Completed
     | Runtime_agent.Yielded_to_chat_waiting _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.Awaiting_external_effect _
     | Runtime_agent.Yielded_after_repeated_tool_call _
     | Runtime_agent.InputRequired _ ->
       false);
  check bool "terminal tool yield settles as completion" true
    (match
       Runtime_agent.For_testing.stop_reason_of_cooperative_yield
         ~turns_used:3
         Runtime_agent.Terminal_tool_completed
     with
     | Runtime_agent.Completed -> true
     | Runtime_agent.Yielded_to_chat_waiting _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.Awaiting_external_effect _
     | Runtime_agent.Yielded_after_repeated_tool_call _
     | Runtime_agent.InputRequired _ -> false)

let test_terminal_effect_handler_contract () =
  let is_terminal =
    Masc.Keeper_tools_oas_bundle.For_testing.is_terminal_effect_handler
  in
  check bool "surface post is a terminal effect" true
    (is_terminal Masc.Keeper_tool_descriptor.Tool_surface_post);
  check bool "surface read is not a terminal effect" false
    (is_terminal Masc.Keeper_tool_descriptor.Tool_surface_read);
  check bool "filesystem write is not a reply terminal" false
    (is_terminal Masc.Keeper_tool_descriptor.Tool_write_file)

let test_terminal_externalization_failure_contract () =
  let classify =
    Masc.Keeper_tools_oas_bundle.For_testing.terminal_externalization_failure
  in
  let error : Masc.Tool_bridge.externalization_error =
    { message = "disk unavailable" }
  in
  List.iter
    (fun state ->
       check bool "non-completed state remains authoritative" true
         (Option.is_none (classify state error)))
    [ Masc.Keeper_tools_oas.Terminal_effect_open
    ; Masc.Keeper_tools_oas.Deferred_tool_result
    ; Masc.Keeper_tools_oas.External_effect_deferred
    ; Masc.Keeper_tools_oas.Terminal_effect_failed
        { failure_class = Tool_result.Workflow_rejection
        ; effect_disposition = Tool_result.Proven_pre_effect
        ; diagnostic = "original failure"
        }
    ];
  match
    classify Masc.Keeper_tools_oas.Terminal_effect_completed error
  with
  | Some
      { failure_class = Tool_result.Runtime_failure
      ; effect_disposition = Tool_result.Proven_post_effect
      ; diagnostic
      } ->
    check bool "internal diagnostic is retained" true
      (String_util.contains_substring diagnostic "disk unavailable")
  | Some _ | None ->
    fail "completed terminal effect did not become proven post-effect failure"

let payload fields = Some (`Assoc fields)

let decoded_exn payload =
  match TO.of_reply_payload payload with
  | Ok outcome -> outcome
  | Error error -> fail (TO.decode_error_to_string error)

let check_decode_error label expected payload =
  match TO.of_reply_payload payload with
  | Error actual -> check bool label true (actual = expected)
  | Ok actual ->
    failf "%s: unexpectedly decoded %s" label (TO.to_label actual)

let test_payload_decode () =
  check_decode_error "no payload fails closed" TO.Payload_missing None;
  check_decode_error "field absent fails closed" TO.Turn_outcome_missing
    (payload [ ("reply", `String "hi") ]);
  check outcome "checkpoint label" TO.Continuation_checkpoint
    (decoded_exn
       (payload [ (TO.wire_key, `String "continuation_checkpoint") ]));
  check outcome "visible label" TO.Visible_reply
    (decoded_exn
       (payload [ (TO.wire_key, `String "visible_reply") ]));
  check outcome "no visible reply label" TO.No_visible_reply
    (decoded_exn
       (payload [ (TO.wire_key, `String "no_visible_reply") ]));
  check_decode_error "unknown label fails closed"
    (TO.Turn_outcome_unknown "deferred")
    (payload [ (TO.wire_key, `String "deferred") ]);
  check_decode_error "duplicate label fails closed" TO.Turn_outcome_duplicate
    (payload
       [ (TO.wire_key, `String "visible_reply")
       ; (TO.wire_key, `String "no_visible_reply")
       ]);
  check_decode_error "non-string label fails closed" TO.Turn_outcome_not_string
    (payload [ (TO.wire_key, `Int 1) ]);
  check_decode_error "non-object payload fails closed" TO.Payload_not_object
    (Some (`List []))

let checkpoint_text =
  "Continuation checkpoint saved; keeper remains scheduled for the next \
   cycle."

(* The reply text no longer participates in classification: a reply that
   *looks* like the synthetic notice but is declared visible stays
   visible, and the declared checkpoint suppresses regardless of text. *)
let test_prefix_is_dead () =
  check outcome "checkpoint-shaped text, declared visible"
    TO.Visible_reply
    (decoded_exn
       (payload
          [ ("reply", `String checkpoint_text);
            (TO.wire_key, `String "visible_reply")
          ]));
  check outcome "ordinary text, declared checkpoint"
    TO.Continuation_checkpoint
    (decoded_exn
       (payload
         [ ("reply", `String "all done");
           (TO.wire_key, `String "continuation_checkpoint")
          ]));
  check outcome "ordinary text, declared no visible reply"
    TO.No_visible_reply
    (decoded_exn
       (payload
          [ ("reply", `String "all done");
            (TO.wire_key, `String "no_visible_reply")
          ]))

let turn_ref_t : Ids.Turn_ref.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (Ids.Turn_ref.to_string t))
    Ids.Turn_ref.equal

(* RFC-0233 §7: the consumer-side decode of the turn join key the keeper
   minted into the reply payload.  Parse, don't repair — absent and
   malformed both decode to None; of_string splits on the LAST '#'. *)
let test_turn_ref_payload_decode () =
  check (option turn_ref_t) "no payload -> None" None
    (TO.turn_ref_of_reply_payload None);
  check (option turn_ref_t) "field absent -> None" None
    (TO.turn_ref_of_reply_payload (payload [ ("reply", `String "hi") ]));
  check (option turn_ref_t) "valid join key decodes"
    (Some
       (Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000"
          ~absolute_turn:4071))
    (TO.turn_ref_of_reply_payload
       (payload
          [ (TO.turn_ref_wire_key, `String "trace-1780648779957-00000#4071") ]));
  check (option turn_ref_t) "inner '#' splits on the last separator"
    (Some (Ids.Turn_ref.make ~trace_id:"weird#trace" ~absolute_turn:12))
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "weird#trace#12") ]));
  check (option turn_ref_t) "no separator -> None (never repaired)" None
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "no-separator") ]));
  check (option turn_ref_t) "non-int suffix -> None" None
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "trace#abc") ]));
  check (option turn_ref_t) "non-string field -> None" None
    (TO.turn_ref_of_reply_payload (payload [ (TO.turn_ref_wire_key, `Int 5) ]))

let test_queued_delivery_requires_exact_turn_ref () =
  let check_failed label payload_json =
    match
      payload_json
      |> TO.turn_ref_of_reply_payload
      |> Stream.For_testing.queued_delivery_outcome_of_turn_ref
    with
    | Stream.Failed { kind = Stream.Missing_turn_ref; detail } ->
        check bool (label ^ " has diagnostic detail") true
          (String.trim detail <> "")
    | Stream.Failed _ | Stream.Delivered _ | Stream.Deferred _ ->
        fail (label ^ " must fail with Missing_turn_ref")
  in
  check_failed "missing turn_ref"
    (payload [ ("reply", `String "hi") ]);
  check_failed "malformed turn_ref"
    (payload
       [ ("reply", `String "hi")
       ; (TO.turn_ref_wire_key, `String "not-a-turn-ref")
       ]);
  let valid =
    payload
      [ ("reply", `String "hi")
      ; (TO.turn_ref_wire_key, `String "trace-queued#42")
      ]
  in
  match
    valid
    |> TO.turn_ref_of_reply_payload
    |> Stream.For_testing.queued_delivery_outcome_of_turn_ref
  with
  | Stream.Delivered { outcome_ref } ->
      check string "valid turn_ref is preserved exactly"
        "trace-queued#42" outcome_ref
  | Stream.Failed _ | Stream.Deferred _ ->
    fail "valid turn_ref must produce Delivered"

let test_terminal_commit_error_cannot_become_delivery_success () =
  let persist_error = "terminal transcript fsync failed" in
  let check_error label queued_turn =
    match
      Stream.For_testing.committed_delivery_outcome
        ~queued_turn
        ~turn_ref:None
        (Error persist_error)
    with
    | Error observed -> check string label persist_error observed
    | Ok None -> fail (label ^ " was downgraded to direct delivery success")
    | Ok (Some _) -> fail (label ^ " was downgraded to queued delivery success")
  in
  check_error "direct commit preserves typed Error" false;
  check_error "queued commit preserves typed Error" true

let test_media_only_queued_reply_uses_delivery_path () =
  match
    Stream.For_testing.empty_reply_delivery_plan
      ~queued_turn:true
      ~has_visible_blocks:true
      ~has_tool_calls:false
  with
  | `Visible_blocks -> ()
  | `Tool_calls_only | `Failure | `User_only ->
    fail "media-only queued reply must use the delivered assistant path"

let test_media_continuation_uses_assistant_delivery_path () =
  List.iter
    (fun has_direct_checkpoint ->
       match
         Stream.For_testing.continuation_delivery_plan
           ~has_direct_checkpoint
           ~has_visible_blocks:true
           ~has_tool_calls:true
       with
       | `Assistant_reply -> ()
       | `Tool_calls_only | `No_assistant_reply | `User_only ->
         fail
           "media continuation must persist and broadcast the structured assistant row")
    [ false; true ]

let test_continuation_status_uses_assistant_delivery_path () =
  let blocks =
    Stream.For_testing.persisted_reply_blocks
      ~turn_outcome:TO.Continuation_checkpoint
      None
  in
  match
    Stream.For_testing.continuation_delivery_plan
      ~has_direct_checkpoint:false
      ~has_visible_blocks:(Option.is_some blocks)
      ~has_tool_calls:false
  with
  | `Assistant_reply -> ()
  | `Tool_calls_only | `No_assistant_reply | `User_only ->
    fail "typed continuation status must use the delivered assistant path"

let body fields = `Assoc fields

let test_direct_reply_visible_text () =
  check (option string) "declared checkpoint -> None" None
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String checkpoint_text);
            ("turn_outcome", `String "continuation_checkpoint")
          ]));
  check (option string) "declared no visible reply -> None" None
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String "all done");
            ("turn_outcome", `String "no_visible_reply")
          ]));
  check_raises
    "missing outcome is a direct-reply contract error"
    (Invalid_argument "keeper reply payload is missing turn_outcome")
    (fun () ->
       ignore
         (Ops.direct_reply_visible_text
            (body [ ("reply", `String checkpoint_text) ])
          : string option));
  check (option string) "declared visible -> reply text" (Some "all done")
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String "all done");
            ("turn_outcome", `String "visible_reply")
          ]));
  check (option string) "empty reply -> None" None
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String "   ");
            ("turn_outcome", `String "visible_reply")
          ]));
  check_raises
    "visible outcome without reply is a direct-reply contract error"
    (Invalid_argument
       "keeper reply payload is missing reply for visible_reply")
    (fun () ->
       ignore
         (Ops.direct_reply_visible_text
            (body [ ("turn_outcome", `String "visible_reply") ])
          : string option))

let test_connector_projection_keeps_external_wait_typed () =
  match
    Masc.Keeper_chat_blocks.connector_projection
      ~turn_outcome:TO.External_effect_pending
      ~reply:(Some "assistant preface that must not survive")
  with
  | Connector_status { kind = External_effect_pending } -> ()
  | Connector_status { kind = Continuation_checkpoint }
  | Connector_text _ | Connector_no_visible_reply ->
    fail "external-effect wait must remain a typed connector status"

let test_connector_projection_keeps_continuation_typed () =
  match
    Masc.Keeper_chat_blocks.connector_projection
      ~turn_outcome:TO.Continuation_checkpoint
      ~reply:(Some "assistant preface that must not survive")
  with
  | Connector_status { kind = Continuation_checkpoint } -> ()
  | Connector_status { kind = External_effect_pending }
  | Connector_text _ | Connector_no_visible_reply ->
    fail "continuation checkpoint must remain a typed connector status"

let test_direct_reply_projection_keeps_external_wait_typed () =
  match
    Ops.direct_reply_projection
      (body
         [ ("reply", `String "assistant preface that must not survive")
         ; ("turn_outcome", `String "external_effect_pending")
         ])
  with
  | Connector_status { kind = External_effect_pending } -> ()
  | Connector_status { kind = Continuation_checkpoint }
  | Connector_text _ | Connector_no_visible_reply ->
    fail "direct reply collapsed external-effect wait into silence"

let () =
  run "keeper_turn_outcome"
    [
      ( "codec",
        [
          test_case "label round trip" `Quick test_label_round_trip;
          test_case "unknown label is None" `Quick test_unknown_label_is_none;
        ] );
      ( "mapping",
        [
          test_case "of_stop_reason" `Quick test_of_stop_reason;
          test_case "of_result_surface" `Quick test_of_result_surface;
          test_case "external effect wait is typed status" `Quick
            test_external_effect_wait_is_typed_status;
          test_case "external effect status survives server projection" `Quick
            test_external_effect_status_survives_server_projection;
          test_case "external effect status becomes persisted chat block" `Quick
            test_external_effect_status_becomes_persisted_chat_block;
          test_case "terminal effect defer kinds remain distinct" `Quick
            test_terminal_effect_defer_kinds_remain_distinct;
          test_case "repeated exact tool call boundary" `Quick
            test_repeated_exact_tool_call_boundary;
          test_case "autonomous yield boundary contract" `Quick
            test_autonomous_yield_boundary_contract;
          test_case "terminal effect handler contract" `Quick
            test_terminal_effect_handler_contract;
          test_case "terminal externalization failure contract" `Quick
            test_terminal_externalization_failure_contract;
        ] );
      ( "payload_decode",
        [
          test_case "decode policy" `Quick test_payload_decode;
          test_case "prefix is dead" `Quick test_prefix_is_dead;
          test_case "turn_ref decode (parse, don't repair)" `Quick
            test_turn_ref_payload_decode;
          test_case "queued delivery requires exact turn_ref" `Quick
            test_queued_delivery_requires_exact_turn_ref;
          test_case "terminal commit error cannot become delivery success" `Quick
            test_terminal_commit_error_cannot_become_delivery_success;
          test_case "media-only queued reply uses delivery path" `Quick
            test_media_only_queued_reply_uses_delivery_path;
          test_case "media continuation uses assistant delivery path" `Quick
            test_media_continuation_uses_assistant_delivery_path;
          test_case "continuation status uses assistant delivery path" `Quick
            test_continuation_status_uses_assistant_delivery_path;
          test_case "continuation status persists as a chat block" `Quick
            test_continuation_status_becomes_persisted_chat_block;
        ] );
      ( "direct_reply",
        [
          test_case "direct_reply_visible_text" `Quick
            test_direct_reply_visible_text;
          test_case "connector projection keeps external wait typed" `Quick
            test_connector_projection_keeps_external_wait_typed;
          test_case "connector projection keeps continuation typed" `Quick
            test_connector_projection_keeps_continuation_typed;
          test_case "direct reply keeps external wait typed" `Quick
            test_direct_reply_projection_keeps_external_wait_typed;
        ] );
    ]
