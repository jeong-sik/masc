(** A failed Keeper turn has no authority to dispose of Event Queue input.

    Provider, configuration, context-window, and tool failures describe the
    runtime attempt, not the independent Board/Schedule/Task facts admitted to
    that attempt. Every such outcome therefore maps to [Batch_no_action]; only
    a completed turn or a typed checkpoint that durably preserves a turn after
    projecting admitted attention can advance that attention. *)

open Alcotest

module KFR = Keeper_runtime_failure_route
module Turn = Masc.Keeper_unified_turn
module Loop = Masc.Keeper_heartbeat_loop
module Cycle = Masc.Keeper_heartbeat_loop_cycle

let test_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "failed-batch"
         ; "trace_id", `String "trace-failed-batch"
         ])
  with
  | Ok meta -> meta
  | Error detail -> failf "meta fixture failed: %s" detail
;;

let error = Agent_core.Error.Internal "test runtime failure"

let failed_outcome ?deferred_runtime_lane route =
  let meta = test_meta () in
  Cycle.Failed
    { meta
    ; failure =
        { Turn.error
        ; runtime_id = "lane-a"
        ; route
        ; source_disposition = Turn.Follow_failure_route
        ; deferred_runtime_lane
        }
    }
;;

let deferred_lane =
  Masc.Keeper_turn_driver.For_testing.make_deferred_runtime_lane
    ~assignment_id:"assignment-1"
    ~failed_runtime_id:"lane-a"
    ~next_runtime_id:"lane-b"
    ~later_runtime_ids:[]
    ~failure:error
;;

let assert_no_queue_action label outcome =
  match Loop.batch_disposition_of_cycle_outcome (Some outcome) with
  | Loop.Batch_no_action -> ()
  | Loop.Batch_ack_completed _ | Loop.Batch_ack_attention_only ->
    failf "%s incorrectly authorized ACK of failed-turn input" label
;;

let test_every_failure_route_preserves_batch () =
  let exhausted label terminal =
    KFR.Exhausted_visible_alive
      { terminal
      ; provenance = KFR.Masc_internal_error
      ; detail = label
      }
  in
  [ ( "network transient"
    , KFR.Retry_after_observed
        { retry_class = KFR.Network_transient; retry_after = None } )
  ; "rotate now", KFR.Rotate_now { rotate = KFR.Model_unavailable }
  ; "context overflow", exhausted "context overflow" KFR.Context_overflow
  ; "deterministic request", exhausted "deterministic request" KFR.Deterministic_request
  ; "configuration mismatch", exhausted "configuration mismatch" KFR.Config_mismatch
  ; "provider integration", exhausted "provider integration" KFR.Provider_integration
  ; "effect fenced", exhausted "effect fenced" KFR.Provider_attempt_effect_fenced
  ; "tool correction lost", exhausted "tool correction lost" KFR.Tool_correction_lost
  ]
  |> List.iter (fun (label, route) ->
    assert_no_queue_action label (failed_outcome route);
    assert_no_queue_action
      (label ^ " with deferred runtime")
      (failed_outcome ~deferred_runtime_lane:deferred_lane route))
;;

let test_nonterminal_outcomes_preserve_batch () =
  let meta = test_meta () in
  [ None
  ; Some
      (Cycle.Checkpointed
         { meta
         ; checkpoint_reason = Turn.Awaiting_external_effect
         ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
         })
  ; Some
      (Cycle.Checkpointed
         { meta
         ; checkpoint_reason = Turn.Operation_queued
         ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
         })
  ; Some
      (Cycle.Checkpointed
         { meta
         ; checkpoint_reason =
             Turn.Repeated_tool_call { tool_name = "keeper_tasks_list"; repeated_count = 3 }
         ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
         })
  ; Some (Cycle.Input_required meta)
  ; Some (Cycle.Cancelled meta)
  ; Some (Cycle.Skipped meta)
  ]
  |> List.iter (fun outcome ->
    match Loop.batch_disposition_of_cycle_outcome outcome with
    | Loop.Batch_no_action -> ()
    | Loop.Batch_ack_completed _ | Loop.Batch_ack_attention_only ->
      fail "an unfinished turn incorrectly authorized Event Queue ACK")
;;

let test_durable_stimulus_checkpoint_acks_admitted_batch () =
  let meta = test_meta () in
  match
    Loop.batch_disposition_of_cycle_outcome
      (Some
         (Cycle.Checkpointed
            { meta
            ; checkpoint_reason = Turn.Durable_stimulus_arrived
            ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
            }))
  with
  | Loop.Batch_ack_attention_only -> ()
  | Loop.Batch_ack_completed _ ->
    fail "a checkpoint was treated as a fully completed connector disposition"
  | Loop.Batch_no_action ->
    fail "a newer durable stimulus left the already-admitted batch pending"
;;

let test_repeated_assistant_checkpoint_acks_admitted_attention () =
  let meta = test_meta () in
  match
    Loop.batch_disposition_of_cycle_outcome
      (Some
         (Cycle.Checkpointed
            { meta
            ; checkpoint_reason = Turn.Repeated_assistant_text { repeated_count = 3 }
            ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
            }))
  with
  | Loop.Batch_ack_attention_only -> ()
  | Loop.Batch_ack_completed _ ->
    fail "a loop-guard checkpoint was treated as a completed connector disposition"
  | Loop.Batch_no_action ->
    fail "a repeated-assistant checkpoint retained already-observed attention"
;;

let test_repeated_assistant_checkpoint_records_hitl_continuation () =
  let meta = test_meta () in
  let outcome =
    Cycle.Checkpointed
      { meta
      ; checkpoint_reason = Turn.Repeated_assistant_text { repeated_count = 3 }
      ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
      }
  in
  check bool
    "HITL continuation projection is required before ACK"
    true
    (Loop.batch_disposition_of_cycle_outcome (Some outcome)
     |> Loop.For_testing.batch_disposition_records_continuation)
;;

let () =
  run
    "keeper_failed_selection_disposition"
    [ ( "failed turn preserves admitted input"
      , [ test_case
            "every runtime failure route leaves the batch pending"
            `Quick
            test_every_failure_route_preserves_batch
        ; test_case
            "nonterminal outcomes leave the batch pending"
            `Quick
            test_nonterminal_outcomes_preserve_batch
        ; test_case
            "durable-stimulus yield advances the admitted batch"
            `Quick
            test_durable_stimulus_checkpoint_acks_admitted_batch
        ; test_case
            "repeated-assistant checkpoint advances admitted attention"
            `Quick
            test_repeated_assistant_checkpoint_acks_admitted_attention
        ; test_case
            "repeated-assistant checkpoint projects HITL continuation"
            `Quick
            test_repeated_assistant_checkpoint_records_hitl_continuation
        ] )
    ]
;;
