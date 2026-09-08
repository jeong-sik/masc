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
  | Loop.Batch_ack_completed | Loop.Batch_ack_attention_only ->
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
  ; ( "effect fenced"
    , exhausted "effect fenced"
        (KFR.Provider_attempt_effect_fenced KFR.Fenced_effect_attempted) )
  ; ( "effect fenced without observation"
    , exhausted "effect fenced without observation"
        (KFR.Provider_attempt_effect_fenced KFR.Fenced_observation_unavailable) )
  ; ( "tool correction lost"
    , exhausted "tool correction lost"
        (KFR.Tool_correction_lost KFR.Fenced_effect_attempted) )
  ; ( "tool correction lost without observation"
    , exhausted "tool correction lost without observation"
        (KFR.Tool_correction_lost KFR.Fenced_observation_unavailable) )
  ]
  |> List.iter (fun (label, route) ->
    assert_no_queue_action label (failed_outcome route);
    assert_no_queue_action
      (label ^ " with deferred runtime")
      (failed_outcome ~deferred_runtime_lane:deferred_lane route))
;;

(* #32956: a failed turn settles the HITL continuation it was handed only
   when the provider answered the request that carried the replay evidence.
   These are the routes the driver produces after an answer: the accept gate
   rejected it, a tool it called failed terminally, or an attempt was fenced
   after a tool effect. *)
let exhausted_route label terminal =
  KFR.Exhausted_visible_alive
    { terminal; provenance = KFR.Masc_internal_error; detail = label }
;;

let observed_failure_routes =
  [ "no progress truncated", KFR.Rotate_now { rotate = KFR.No_progress_truncated }
  ; "no progress empty", KFR.Rotate_now { rotate = KFR.No_progress_empty }
  ; ( "no progress thinking only"
    , KFR.Rotate_now { rotate = KFR.No_progress_thinking_only } )
  ; "contract violation", exhausted_route "contract violation" KFR.Contract_violation
  ; ( "terminal effect runtime failure"
    , exhausted_route "terminal effect runtime failure" KFR.Terminal_effect_runtime_failure )
  ; ( "effect fenced after a tool effect"
    , exhausted_route "effect fenced"
        (KFR.Provider_attempt_effect_fenced KFR.Fenced_effect_attempted) )
  ; ( "tool correction lost after a tool effect"
    , exhausted_route "tool correction lost"
        (KFR.Tool_correction_lost KFR.Fenced_effect_attempted) )
  ]
;;

(* Nothing the model said is on record for these: the request was refused,
   never answered, or the answer is unreadable. *)
let unobserved_failure_routes =
  [ ( "provider timeout"
    , KFR.Retry_after_observed
        { retry_class = KFR.Provider_timeout; retry_after = None } )
  ; ( "server error"
    , KFR.Retry_after_observed { retry_class = KFR.Server_error; retry_after = None } )
  ; "auth failed", KFR.Rotate_now { rotate = KFR.Auth_failed }
  ; "model unavailable", KFR.Rotate_now { rotate = KFR.Model_unavailable }
  ; "attempt rejected", KFR.Rotate_now { rotate = KFR.Attempt_rejected }
  ; "context overflow", exhausted_route "context overflow" KFR.Context_overflow
  ; "configuration mismatch", exhausted_route "configuration mismatch" KFR.Config_mismatch
  ; "provider integration", exhausted_route "provider integration" KFR.Provider_integration
  ; "internal opaque", exhausted_route "internal opaque" KFR.Internal_opaque
    (* The lanes set this before any answer: claude-code on spawn, codex when
       the turn input could not be written. A continuation that fails this
       way must keep its wake, or the model never sees the replay. *)
  ; ( "effect fenced without observation"
    , exhausted_route "effect fenced without observation"
        (KFR.Provider_attempt_effect_fenced KFR.Fenced_observation_unavailable) )
  ; ( "tool correction lost without observation"
    , exhausted_route "tool correction lost without observation"
        (KFR.Tool_correction_lost KFR.Fenced_observation_unavailable) )
  ]
;;

let test_failure_after_an_answer_settles_continuation_as_failed () =
  List.iter
    (fun (label, route) ->
       match Loop.continuation_settlement_of_cycle_outcome (Some (failed_outcome route)) with
       | Loop.Continuation_settled_failed { route = settled } ->
         check bool (label ^ ": the settlement carries the turn's route") true (settled = route)
       | Loop.Continuation_settled_recorded ->
         failf "%s: a failed turn was settled as a recorded continuation" label
       | Loop.Continuation_unsettled ->
         failf "%s: a failure after the provider answered left the continuation unsettled" label)
    observed_failure_routes
;;

let test_failure_before_an_answer_leaves_continuation_unsettled () =
  List.iter
    (fun (label, route) ->
       match Loop.continuation_settlement_of_cycle_outcome (Some (failed_outcome route)) with
       | Loop.Continuation_unsettled -> ()
       | Loop.Continuation_settled_recorded ->
         failf "%s: a failed turn was settled as a recorded continuation" label
       | Loop.Continuation_settled_failed _ ->
         failf "%s: a failure with no answer on record settled the continuation" label)
    unobserved_failure_routes
;;

(* The settlement is a chat-store receipt, not a queue action: the batch of a
   failed turn stays pending whether or not the provider answered. *)
let test_failure_after_an_answer_still_leaves_batch_pending () =
  List.iter
    (fun (label, route) ->
       assert_no_queue_action label (failed_outcome route);
       assert_no_queue_action
         (label ^ " with deferred runtime")
         (failed_outcome ~deferred_runtime_lane:deferred_lane route))
    observed_failure_routes
;;

let test_recorded_settlement_follows_the_batch_disposition () =
  let meta = test_meta () in
  (match
     Loop.continuation_settlement_of_cycle_outcome
       (Some
          (Cycle.Completed
             { meta; continuation_route = Turn.Continuation_route_addressed }))
   with
   | Loop.Continuation_settled_recorded -> ()
   | Loop.Continuation_settled_failed _ | Loop.Continuation_unsettled ->
     fail "a completed turn did not record its continuation");
  List.iter
    (fun (label, checkpoint_reason) ->
       match
         Loop.continuation_settlement_of_cycle_outcome
           (Some
              (Cycle.Checkpointed
                 { meta
                 ; checkpoint_reason
                 ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
                 }))
       with
       | Loop.Continuation_settled_recorded -> ()
       | Loop.Continuation_settled_failed _ | Loop.Continuation_unsettled ->
         failf "%s: a checkpoint did not record its continuation" label)
    [ "durable stimulus arrived", Turn.Durable_stimulus_arrived
    ; "operation queued", Turn.Operation_queued
    ];
  List.iter
    (fun outcome ->
       match Loop.continuation_settlement_of_cycle_outcome outcome with
       | Loop.Continuation_unsettled -> ()
       | Loop.Continuation_settled_recorded | Loop.Continuation_settled_failed _ ->
         fail "an unfinished turn settled the continuation")
    [ None; Some (Cycle.Input_required meta); Some (Cycle.Cancelled meta); Some (Cycle.Skipped meta) ]
;;

let test_nonterminal_outcomes_preserve_batch () =
  let meta = test_meta () in
  [ None; Some (Cycle.Input_required meta); Some (Cycle.Cancelled meta); Some (Cycle.Skipped meta) ]
  |> List.iter (fun outcome ->
    match Loop.batch_disposition_of_cycle_outcome outcome with
    | Loop.Batch_no_action -> ()
    | Loop.Batch_ack_completed | Loop.Batch_ack_attention_only ->
      fail "an unfinished turn incorrectly authorized Event Queue ACK")
;;

(* Every checkpoint reason is produced after the model ran with the admitted
   batch projected, so each one advances already-observed attention. The
   regression this pins: a turn that ended on a Gate-deferred tool call left
   its admitted HITL resolution at the queue head, and with one resolution
   admitted per turn the same spent grant cost a turn on every wake while the
   resolutions queued behind it never reached the model (edgar.a.poe,
   2026-09-02: eight turns on one Execute over ten minutes). *)
let every_checkpoint_reason =
  [ "durable stimulus arrived", Turn.Durable_stimulus_arrived
  ; "repeated assistant text", Turn.Repeated_assistant_text { repeated_count = 3 }
  ; ( "repeated tool call"
    , Turn.Repeated_tool_call { tool_name = "keeper_tasks_list"; repeated_count = 3 } )
  ; "operation queued", Turn.Operation_queued
  ]
;;

let test_every_checkpoint_reason_acks_admitted_attention () =
  let meta = test_meta () in
  List.iter
    (fun (label, checkpoint_reason) ->
       match
         Loop.batch_disposition_of_cycle_outcome
           (Some
              (Cycle.Checkpointed
                 { meta
                 ; checkpoint_reason
                 ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
                 }))
       with
       | Loop.Batch_ack_attention_only -> ()
       | Loop.Batch_ack_completed ->
         failf "%s: a checkpoint was treated as a completed connector disposition" label
       | Loop.Batch_no_action ->
         failf "%s: a checkpoint retained attention the turn already projected" label)
    every_checkpoint_reason
;;

let test_every_checkpoint_reason_records_hitl_continuation () =
  let meta = test_meta () in
  List.iter
    (fun (label, checkpoint_reason) ->
       check
         bool
         (label ^ ": HITL continuation projection is required before ACK")
         true
         (Loop.batch_disposition_of_cycle_outcome
            (Some
               (Cycle.Checkpointed
                  { meta
                  ; checkpoint_reason
                  ; continuation_route = Turn.Continuation_no_terminal_effect_receipt
                  }))
          |> Loop.For_testing.batch_disposition_records_continuation))
    every_checkpoint_reason
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
  | Loop.Batch_ack_completed ->
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
  | Loop.Batch_ack_completed ->
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
        ; test_case
            "every checkpoint reason advances admitted attention"
            `Quick
            test_every_checkpoint_reason_acks_admitted_attention
        ; test_case
            "every checkpoint reason projects HITL continuation"
            `Quick
            test_every_checkpoint_reason_records_hitl_continuation
        ] )
    ; ( "failed turn settles the continuation only after an answer"
      , [ test_case
            "a failure after the provider answered settles as failed"
            `Quick
            test_failure_after_an_answer_settles_continuation_as_failed
        ; test_case
            "a failure with no answer on record stays unsettled"
            `Quick
            test_failure_before_an_answer_leaves_continuation_unsettled
        ; test_case
            "a settled failure still leaves the batch pending"
            `Quick
            test_failure_after_an_answer_still_leaves_batch_pending
        ; test_case
            "recorded settlement follows the batch disposition"
            `Quick
            test_recorded_settlement_follows_the_batch_disposition
        ] )
    ]
;;
