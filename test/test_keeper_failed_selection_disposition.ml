(** Source-disposal decision tests for
    [Keeper_heartbeat_loop.failed_source_disposition] (#26546).

    With automatic overflow-compaction recovery removed, the heartbeat owns
    typed liveness disposition for a failed turn holding a pending Event Queue
    selection: a frozen successor preserves it; without a successor every
    failed source receives a terminal observation,
    an effect-fenced provider failure quarantines that source even if a stale
    successor exists, and transcript corruption alone pauses the Keeper. *)

open Alcotest

module KFR = Keeper_runtime_failure_route
module Turn = Masc.Keeper_unified_turn
module Loop = Masc.Keeper_heartbeat_loop

let overflow_error =
  Agent_core.Error.Api
    (ContextOverflow { message = "exceeded"; limit = Some 32768 })
;;

let failure ?deferred_runtime_lane ~route ~source_disposition error =
  { Turn.error
  ; runtime_id = "lane-a"
  ; route
  ; source_disposition
  ; deferred_runtime_lane
  }
;;

let overflow_failure ?deferred_runtime_lane () =
  (* Route through the real classifier so this test also pins
     "typed ContextOverflow maps to the Context_overflow terminal". *)
  failure
    ?deferred_runtime_lane
    ~route:(KFR.route_of_error ~boundary:KFR.Agent_core_execution overflow_error)
    ~source_disposition:Turn.Follow_failure_route
    overflow_error
;;

let deferred_lane =
  Masc.Keeper_turn_driver.For_testing.make_deferred_runtime_lane
    ~assignment_id:"assignment-1"
    ~failed_runtime_id:"lane-a"
    ~next_runtime_id:"lane-b"
    ~later_runtime_ids:[]
    ~failure:overflow_error
;;

let test_overflow_without_successor_terminalizes () =
  match Loop.failed_source_disposition (overflow_failure ()) with
  | Loop.Quarantine_source { detail } ->
    check bool "detail is non-empty" true (String.length detail > 0)
  | Loop.Preserve_for_deferred_runtime
  | Loop.Pause_keeper_for_integrity _ ->
    fail
      "context overflow with no recovery successor must terminalize the \
       selection: retrying re-dispatches the same bounded payload every \
       heartbeat"
;;

let test_overflow_with_deferred_lane_preserves () =
  check bool "a frozen successor lane keeps the selection bound to it" true
    (match
       Loop.failed_source_disposition
         (overflow_failure ~deferred_runtime_lane:deferred_lane ())
     with
     | Loop.Preserve_for_deferred_runtime -> true
     | Loop.Quarantine_source _
     | Loop.Pause_keeper_for_integrity _ ->
       false)
;;

let test_effect_fenced_failure_terminalizes_exact_source () =
  let error =
    Masc.Keeper_turn_driver.core_error_of_masc_internal_error
      (Masc.Keeper_turn_driver.Provider_attempt_effect_fenced
         { runtime_id = "effect-owner"
         ; effect_disposition =
             Masc.Keeper_provider_attempt_effect.Observation_unavailable
         ; diagnostic = "provider failed after dispatch"
         })
  in
  let route =
    KFR.route_of_error ~boundary:KFR.Masc_execution error
  in
  match
    Loop.failed_source_disposition
      (failure
         ~deferred_runtime_lane:deferred_lane
         ~route
         ~source_disposition:Turn.Follow_failure_route
         error)
  with
  | Loop.Quarantine_source { detail } ->
    check bool "detail is non-empty" true (String.length detail > 0)
  | Loop.Preserve_for_deferred_runtime
  | Loop.Pause_keeper_for_integrity _ ->
    fail
      "effect-fenced failure must terminalize the exact failed source instead \
       of replaying it on the next heartbeat"
;;

let preserving_terminal_classes =
  [ "internal_opaque", KFR.Internal_opaque
  ; "deterministic_request", KFR.Deterministic_request
  ; "terminal_effect_runtime_failure", KFR.Terminal_effect_runtime_failure
  ]
;;

let test_other_terminal_classes_quarantine_source () =
  List.iter
    (fun (label, terminal) ->
       let route =
         KFR.Exhausted_visible_alive
           { terminal
           ; provenance = KFR.Masc_internal_error
           ; detail = label
           }
       in
       check
         bool
         (label ^ " terminal quarantines only the source")
         true
         (match
            Loop.failed_source_disposition
              (failure
                 ~route
                 ~source_disposition:Turn.Follow_failure_route
                 overflow_error)
          with
          | Loop.Quarantine_source { detail } -> String.length detail > 0
          | Loop.Preserve_for_deferred_runtime
          | Loop.Pause_keeper_for_integrity _ ->
            false))
    preserving_terminal_classes
;;

let exhausted_configuration_classes =
  [ "config_mismatch", KFR.Config_mismatch
  ; "provider_integration", KFR.Provider_integration
  ]
;;

let test_exhausted_configuration_classes_quarantine_source () =
  List.iter
    (fun (label, terminal) ->
       let route =
         KFR.Exhausted_visible_alive
           { terminal
           ; provenance = KFR.Masc_internal_error
           ; detail = label
           }
       in
       check bool (label ^ " quarantines without stopping the Keeper") true
         (match
            Loop.failed_source_disposition
              (failure
                 ~route
                 ~source_disposition:Turn.Follow_failure_route
                 overflow_error)
          with
          | Loop.Quarantine_source _ -> true
          | Loop.Preserve_for_deferred_runtime
          | Loop.Pause_keeper_for_integrity _ ->
            false))
    exhausted_configuration_classes
;;

let test_unavailable_runtime_without_successor_terminalizes () =
  let route =
    KFR.Rotate_now { rotate = KFR.Network_unavailable }
  in
  check bool "no successor means no implicit re-entry" true
    (match
       Loop.failed_source_disposition
         (failure
            ~route
            ~source_disposition:Turn.Follow_failure_route
            overflow_error)
     with
     | Loop.Quarantine_source _ -> true
     | Loop.Preserve_for_deferred_runtime
     | Loop.Pause_keeper_for_integrity _ ->
       false)
;;

let test_transcript_corruption_pauses_keeper () =
  check bool "transcript corruption is the explicit Keeper pause path" true
    (match
       Loop.failed_source_disposition
         (failure
            ~route:
              (KFR.route_of_error
                 ~boundary:KFR.Agent_core_execution
                 overflow_error)
            ~source_disposition:
              (Turn.Pause_after_transcript_corruption { detail = "corrupt" })
            overflow_error)
     with
     | Loop.Pause_keeper_for_integrity { detail } ->
       String.equal detail "corrupt"
     | Loop.Preserve_for_deferred_runtime
     | Loop.Quarantine_source _ ->
       false)
;;

let test_defer_pending_rotates_within_urgency_lane () =
  let stimulus post_id : Keeper_event_queue.stimulus =
    { post_id
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 1.0
    ; payload = Keeper_event_queue.Bootstrap
    }
  in
  let queue =
    [ stimulus "source-a"; stimulus "source-b"; stimulus "source-c" ]
    |> List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty
  in
  let state =
    Keeper_event_queue_state.with_pending queue Keeper_event_queue_state.empty
  in
  let selection =
    match Keeper_event_queue_state.pending_selections state with
    | selection :: _ -> selection
    | [] -> fail "missing pending selection"
  in
  let deferred, incarnation =
    match Keeper_event_queue_state.defer_pending ~selection state with
    | Ok result -> result
    | Error detail -> fail detail
  in
  check
    (list string)
    "transient source moves behind independent peers"
    [ "source-b"; "source-c"; "source-a" ]
    (deferred
     |> Keeper_event_queue_state.pending
     |> Keeper_event_queue.to_list
     |> List.map (fun source -> source.Keeper_event_queue.post_id));
  check bool "deferred source receives a new incarnation" true
    (Int64.compare incarnation selection.admitted_revision > 0)
;;

let () =
  run
    "keeper_failed_selection_disposition"
    [ ( "failed_source_disposition"
      , [ test_case
            "overflow without successor terminalizes"
            `Quick
            test_overflow_without_successor_terminalizes
        ; test_case
            "overflow with deferred lane preserves"
            `Quick
            test_overflow_with_deferred_lane_preserves
        ; test_case
            "effect-fenced failure terminalizes the exact source"
            `Quick
            test_effect_fenced_failure_terminalizes_exact_source
        ; test_case
            "other terminal classes quarantine source"
            `Quick
            test_other_terminal_classes_quarantine_source
        ; test_case
            "exhausted configuration classes quarantine source"
            `Quick
            test_exhausted_configuration_classes_quarantine_source
        ; test_case
            "unavailable runtime without successor terminalizes"
            `Quick
            test_unavailable_runtime_without_successor_terminalizes
        ; test_case
            "transcript corruption pauses Keeper"
            `Quick
            test_transcript_corruption_pauses_keeper
        ; test_case
            "defer rotates within urgency lane"
            `Quick
            test_defer_pending_rotates_within_urgency_lane
        ] )
    ]
;;
