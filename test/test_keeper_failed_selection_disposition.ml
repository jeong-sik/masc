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

(* RFC-provider-path-rest §3.1: a failed cycle decides the next dispatch from
   the path the input goes to next. The ids here are not in the runtime table,
   so a deferred suffix's head and a fresh walk of the assignment both serve;
   resting walks are pinned against a real table in
   test_keeper_turn_driver_failover. *)
let now = 1000.0

let decide ?deferred_runtime_lane route =
  Loop.For_testing.after_failure
    ~now
    ~assignment_id:"lane-a"
    { Turn.error
    ; runtime_id = "lane-a"
    ; route
    ; source_disposition = Turn.Follow_failure_route
    ; deferred_runtime_lane
    }
;;

let show_after_failure = function
  | None -> "cadence"
  | Some (Loop.Continue_on_deferred_lane { next_runtime_id }) ->
    Printf.sprintf "continue on %s" next_runtime_id
  | Some (Loop.Wait_for_path_release { release_at; waiting_on }) ->
    Printf.sprintf "wait for %s until %.1f" waiting_on release_at
;;

let check_decision label expected actual =
  check string label (show_after_failure expected) (show_after_failure actual)
;;

let wait ~after =
  Some (Loop.Wait_for_path_release { release_at = now +. after; waiting_on = "lane-a" })
;;

(* #34653: with no other path for the input, a rate limit or quota waits for
   the failed path's own rest and a wakeup does not cut that wait short
   (pinned in test_keeper_keepalive_helpers).
   The rest is the provider's answer: a stated 5 s waits 5 s, not a cadence. *)
let test_a_refusal_without_a_suffix_waits_for_the_failed_path () =
  let cap_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec in
  let floor_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec in
  check_decision "a rate limit stating 5 s"
    (wait ~after:5.0)
    (decide (KFR.Retry_after_observed { retry_class = KFR.Rate_limited; retry_after = Some 5.0 }));
  check_decision "a rate limit stating nothing"
    (wait ~after:floor_sec)
    (decide (KFR.Retry_after_observed { retry_class = KFR.Rate_limited; retry_after = None }));
  check_decision "a hard quota stating nothing"
    (wait ~after:cap_sec)
    (decide (KFR.Retry_after_observed { retry_class = KFR.Hard_quota; retry_after = None }))
;;

(* #36583: the driver deferred the input to a path that is not resting, so the
   keeper does not wait for the path that refused it. *)
let test_a_suffix_on_a_serving_path_continues_without_waiting () =
  List.iter
    (fun (label, route) ->
       check_decision label
         (Some (Loop.Continue_on_deferred_lane { next_runtime_id = "lane-b" }))
         (decide ~deferred_runtime_lane:deferred_lane route))
    [ ( "rate limit"
      , KFR.Retry_after_observed { retry_class = KFR.Rate_limited; retry_after = None } )
    ; ( "hard quota"
      , KFR.Retry_after_observed { retry_class = KFR.Hard_quota; retry_after = Some 600.0 } )
    ; "repeated generation", KFR.Rotate_now { rotate = KFR.Generation_repeated }
    ; ( "provider capacity (#38061)"
      , KFR.Retry_after_observed { retry_class = KFR.Provider_capacity; retry_after = Some 5.0 } )
    ]
;;

let test_other_failures_without_a_suffix_keep_the_cadence () =
  List.iter
    (fun (label, route) -> check_decision label None (decide route))
    [ ( "network transient"
      , KFR.Retry_after_observed
          { retry_class = KFR.Network_transient; retry_after = None } )
    ; ( "empty completion"
      , KFR.Retry_after_observed
          { retry_class =
              KFR.Empty_completion { stop_reason = Agent_core.Types.EndTurn }
          ; retry_after = None
          } )
    ; ( "server error"
      , KFR.Retry_after_observed { retry_class = KFR.Server_error; retry_after = None } )
    ; ( "provider capacity (#38061)"
      , KFR.Retry_after_observed { retry_class = KFR.Provider_capacity; retry_after = None } )
    ; ( "provider timeout"
      , KFR.Retry_after_observed
          { retry_class = KFR.Provider_timeout; retry_after = None } )
    ; "model unavailable", KFR.Rotate_now { rotate = KFR.Model_unavailable }
    ]
;;

(* #36583: the deferred suffix is the unfinished turn. It starts the next
   cycle even when no second Event Queue stimulus exists. Resting paths and
   ordinary cadence retain the previous acknowledged-pending rule, so #34653
   still prevents a queued wake from cutting a provider rest short. *)
let test_a_serving_deferred_suffix_starts_the_next_cycle_without_a_stimulus () =
  let continued =
    Some (Loop.Continue_on_deferred_lane { next_runtime_id = "lane-b" })
  in
  let waiting =
    Some
      (Loop.Wait_for_path_release
         { release_at = now +. 60.0
         ; waiting_on = "lane-a"
         })
  in
  let pending_calls = ref 0 in
  check bool
    "deferred unfinished input starts without acknowledging stimuli"
    true
    (Loop.For_testing.next_cycle_starts_now
       ~after_failure:continued
       ~stimuli_acked:false
       ~pending_stimulus:(fun () ->
         incr pending_calls;
         false));
  check int "the deferred path does not inspect the Event Queue" 0 !pending_calls;
  List.iter
    (fun (label, after_failure) ->
       check bool
         label
         false
         (Loop.For_testing.next_cycle_starts_now
            ~after_failure
            ~stimuli_acked:false
            ~pending_stimulus:(fun () ->
              incr pending_calls;
              true)))
    [ "a resting path with unacked stimuli keeps sleeping", waiting
    ; "ordinary cadence with unacked stimuli keeps sleeping", None
    ];
  check int "unacked outcomes do not inspect the Event Queue" 0 !pending_calls;
  List.iter
    (fun (label, after_failure, stimuli_acked, pending_stimulus, expected) ->
       check bool
         label
         expected
         (Loop.For_testing.next_cycle_starts_now
            ~after_failure
            ~stimuli_acked
            ~pending_stimulus:(fun () -> pending_stimulus)))
    [ "deferred unfinished input starts without a stimulus", continued, false, false, true
    ; "a resting path keeps sleeping", waiting, false, true, false
    ; "an acknowledged pending stimulus retains the existing wake", waiting, true, true, true
    ; "ordinary cadence keeps sleeping without a pending stimulus", None, true, false, false
    ; "ordinary cadence retains the existing wake", None, true, true, true
    ]
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
  let empty_completion =
    Agent_core.Error.Provider
      (Llm_provider.Error.EmptyCompletion
         { provider = "openrouter"
         ; stop_reason = Agent_core.Types.EndTurn
         ; detail = "empty assistant turn"
         })
    |> KFR.route_of_error ~boundary:KFR.Agent_core_execution
  in
  [ "typed empty completion", empty_completion
  ; "no progress truncated", KFR.Rotate_now { rotate = KFR.No_progress_truncated }
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
  ; ( "refusal body not received"
    , KFR.Rotate_now { rotate = KFR.Refusal_body_not_received } )
  ; "context overflow", exhausted_route "context overflow" KFR.Context_overflow
  ; "configuration mismatch", exhausted_route "configuration mismatch" KFR.Config_mismatch
  ; "provider integration", exhausted_route "provider integration" KFR.Provider_integration
  ; "internal opaque", exhausted_route "internal opaque" KFR.Internal_opaque
    (* The history was refused before dispatch (#38456). A rejected Gate
       resolution reaches this refusal; retiring its wake would leave the
       model never told of the rejection. *)
  ; "transcript refused", exhausted_route "transcript refused" KFR.Transcript_refused
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
    ; ( "next dispatch after a failed cycle"
      , [ test_case
            "a refusal without a suffix waits for the failed path"
            `Quick
            test_a_refusal_without_a_suffix_waits_for_the_failed_path
        ; test_case
            "a suffix on a serving path continues without waiting"
            `Quick
            test_a_suffix_on_a_serving_path_continues_without_waiting
        ; test_case
            "other failures without a suffix keep the cadence"
            `Quick
            test_other_failures_without_a_suffix_keep_the_cadence
        ; test_case
            "a serving deferred suffix starts without another stimulus"
            `Quick
            test_a_serving_deferred_suffix_starts_the_next_cycle_without_a_stimulus
        ] )
    ]
;;
