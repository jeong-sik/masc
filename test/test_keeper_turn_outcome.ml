(* RFC-0232 P2: producer-typed turn outcome.

   The reply payload's [turn_outcome] field is the only carrier of the
   checkpoint/visible/no-visible distinction; the legacy "Continuation
   checkpoint saved;" prefix sniff is deleted.  These tests pin:
   - the closed label codec (round-trip, unknown -> None),
   - the stop_reason -> outcome mapping (single mapping site),
   - response_text-aware result-surface classification,
   - payload decode policy: absent/unknown fails toward Visible_reply
     (the bitten failure mode, #20870, was silent non-persistence),
   - prefix deadness: checkpoint-shaped reply TEXT alone never
     classifies as a checkpoint. *)

open Alcotest

module TO = Masc.Keeper_turn_outcome
module Ops = Masc.Keeper_tool_surface_ops
module Stream = Server_routes_http_keeper_stream
module UT = Masc.Keeper_unified_turn
module Cycle = Masc.Keeper_heartbeat_loop_cycle
module Heartbeat = Masc.Keeper_heartbeat_loop.For_testing

let outcome : TO.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (TO.to_label t))
    TO.equal

let all = [ TO.Visible_reply; TO.Continuation_checkpoint; TO.No_visible_reply ]

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

let test_runtime_stop_reason_controls_durable_source_completion () =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String "turn-outcome-source"
          ; "trace_id", `String "trace-turn-outcome-source"
          ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let request : Agent_sdk.Error.input_required =
    { request_id = "source-input-1"
    ; participant_name = None
    ; question = "Need operator input"
    ; schema = None
    ; timeout_s = None
    ; created_at = 1_000.0
    }
  in
  let cycle_of_stop_reason stop_reason =
    match UT.turn_success_of_stop_reason ~meta stop_reason with
    | UT.Turn_completed meta -> Cycle.Completed meta
    | UT.Turn_checkpointed meta -> Cycle.Checkpointed meta
    | UT.Turn_input_required meta -> Cycle.Input_required meta
    | UT.Turn_cancelled _
    | UT.Turn_skipped _ ->
      fail "runtime stop reason mapped outside the executed turn outcomes"
  in
  check bool "completed turn settles durable source" true
    (Heartbeat.cycle_outcome_acks_source
       (cycle_of_stop_reason Runtime_agent.Completed));
  check bool "chat yield retains durable source" false
    (Heartbeat.cycle_outcome_acks_source
       (cycle_of_stop_reason
          (Runtime_agent.Yielded_to_chat_waiting { turns_used = 2 })));
  check bool "durable stimulus yield retains durable source" false
    (Heartbeat.cycle_outcome_acks_source
       (cycle_of_stop_reason
          (Runtime_agent.Yielded_to_durable_stimulus { turns_used = 2 })));
  check bool "repeated tool yield retains durable source" false
    (Heartbeat.cycle_outcome_acks_source
       (cycle_of_stop_reason
          (Runtime_agent.Yielded_after_repeated_tool_call
             { turns_used = 2
             ; tool_name = "keeper_tasks_list"
             ; repeated_count = 3
             })));
  check bool "input required retains durable source" false
    (Heartbeat.cycle_outcome_acks_source
       (cycle_of_stop_reason
          (Runtime_agent.InputRequired { turns_used = 2; request })))

let test_cooperative_yield_ignores_only_active_source_identity () =
  let stimulus post_id : Keeper_event_queue.stimulus =
    { post_id
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 1_000.0
    ; payload = Keeper_event_queue.Bootstrap
    }
  in
  let active = stimulus "active-source" in
  let later = stimulus "later-source" in
  let filter =
    Masc.Keeper_unified_turn_execution.For_testing
    .pending_without_active_sources
      ~active_source_stimuli:[ active ]
  in
  let only_active =
    Keeper_event_queue.enqueue Keeper_event_queue.empty active
    |> filter
  in
  check int "active source does not yield to itself" 0
    (Keeper_event_queue.length only_active);
  let with_later =
    Keeper_event_queue.empty
    |> fun queue -> Keeper_event_queue.enqueue queue active
    |> fun queue -> Keeper_event_queue.enqueue queue later
    |> filter
    |> Keeper_event_queue.to_list
  in
  match with_later with
  | [ retained ] ->
    check string "same payload with a different identity still requests yield"
      later.post_id
      retained.post_id
  | retained ->
    failf "expected one later durable source, got %d" (List.length retained)

let test_of_result_surface () =
  check outcome "completed with text -> visible" TO.Visible_reply
    (TO.of_result_surface ~response_text:"done" Runtime_agent.Completed);
  check outcome "completed with empty text -> no visible reply"
    TO.No_visible_reply
    (TO.of_result_surface ~response_text:"   " Runtime_agent.Completed)

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
   | Runtime_agent.Repeated_tool_call _
   | Runtime_agent.Terminal_tool_completed ->
     fail "chat request mapped to the durable reason");
  (match F.runtime_yield_reason durable_stimulus with
   | Runtime_agent.Durable_stimulus_waiting -> ()
   | Runtime_agent.Chat_waiting
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

let payload fields = Some (`Assoc fields)

let test_payload_decode () =
  check outcome "no payload -> visible" TO.Visible_reply
    (TO.of_reply_payload None);
  check outcome "field absent -> visible" TO.Visible_reply
    (TO.of_reply_payload (payload [ ("reply", `String "hi") ]));
  check outcome "checkpoint label" TO.Continuation_checkpoint
    (TO.of_reply_payload
       (payload [ (TO.wire_key, `String "continuation_checkpoint") ]));
  check outcome "visible label" TO.Visible_reply
    (TO.of_reply_payload
       (payload [ (TO.wire_key, `String "visible_reply") ]));
  check outcome "no visible reply label" TO.No_visible_reply
    (TO.of_reply_payload
       (payload [ (TO.wire_key, `String "no_visible_reply") ]));
  check outcome "unknown label -> visible (report-and-persist)"
    TO.Visible_reply
    (TO.of_reply_payload (payload [ (TO.wire_key, `String "deferred") ]))

let checkpoint_text =
  "Continuation checkpoint saved; keeper remains scheduled for the next \
   cycle."

(* The reply text no longer participates in classification: a reply that
   *looks* like the synthetic notice but is declared visible stays
   visible, and the declared checkpoint suppresses regardless of text. *)
let test_prefix_is_dead () =
  check outcome "checkpoint-shaped text, declared visible"
    TO.Visible_reply
    (TO.of_reply_payload
       (payload
          [ ("reply", `String checkpoint_text);
            (TO.wire_key, `String "visible_reply")
          ]));
  check outcome "ordinary text, declared checkpoint"
    TO.Continuation_checkpoint
    (TO.of_reply_payload
       (payload
         [ ("reply", `String "all done");
           (TO.wire_key, `String "continuation_checkpoint")
          ]));
  check outcome "ordinary text, declared no visible reply"
    TO.No_visible_reply
    (TO.of_reply_payload
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
  check (option string) "checkpoint-shaped text without field -> visible"
    (Some checkpoint_text)
    (Ops.direct_reply_visible_text
       (body [ ("reply", `String checkpoint_text) ]));
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
          ]))

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
          test_case "runtime stop reason controls durable source completion" `Quick
            test_runtime_stop_reason_controls_durable_source_completion;
          test_case "cooperative yield ignores only active source identity" `Quick
            test_cooperative_yield_ignores_only_active_source_identity;
          test_case "of_result_surface" `Quick test_of_result_surface;
          test_case "repeated exact tool call boundary" `Quick
            test_repeated_exact_tool_call_boundary;
          test_case "autonomous yield boundary contract" `Quick
            test_autonomous_yield_boundary_contract;
          test_case "terminal effect handler contract" `Quick
            test_terminal_effect_handler_contract;
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
        ] );
      ( "direct_reply",
        [
          test_case "direct_reply_visible_text" `Quick
            test_direct_reply_visible_text;
        ] );
    ]
