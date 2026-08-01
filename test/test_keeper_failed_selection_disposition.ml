(** Source-disposal decision tests for
    [Keeper_heartbeat_loop.failed_selection_terminal_detail] (#26546).

    With automatic overflow-compaction recovery removed, the heartbeat owns
    exactly one terminalization opinion for a failed turn holding a pending
    Event Queue selection: a typed context-overflow terminal route with no
    deferred runtime lane consumes the selection; every other failure shape
    preserves it. These tests pin each preserving class independently so a
    refactor cannot silently widen the consuming arm back to a blanket
    [Exhausted_visible_alive] match (the 2026-08-01 review regression). *)

open Alcotest

module KFR = Keeper_runtime_failure_route
module Turn = Masc.Keeper_unified_turn
module Loop = Masc.Keeper_heartbeat_loop

let overflow_error =
  Agent_sdk.Error.Api
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
    ~route:(KFR.route_of_error ~boundary:KFR.Oas_execution overflow_error)
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
  match Loop.failed_selection_terminal_detail (overflow_failure ()) with
  | Some detail ->
    check bool "detail is non-empty" true (String.length detail > 0)
  | None ->
    fail
      "context overflow with no recovery successor must terminalize the \
       selection: retrying re-dispatches the same bounded payload every \
       heartbeat"
;;

let test_overflow_with_deferred_lane_preserves () =
  check
    (option string)
    "a frozen successor lane keeps the selection bound to it"
    None
    (Loop.failed_selection_terminal_detail
       (overflow_failure ~deferred_runtime_lane:deferred_lane ()))
;;

let preserving_terminal_classes =
  [ "config_mismatch", KFR.Config_mismatch
  ; "internal_opaque", KFR.Internal_opaque
  ; "deterministic_request", KFR.Deterministic_request
  ; "terminal_effect_runtime_failure", KFR.Terminal_effect_runtime_failure
  ]
;;

let test_other_terminal_classes_preserve () =
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
         (option string)
         (label ^ " terminal preserves the selection")
         None
         (Loop.failed_selection_terminal_detail
            (failure
               ~route
               ~source_disposition:Turn.Follow_failure_route
               overflow_error)))
    preserving_terminal_classes
;;

let test_retryable_route_preserves () =
  let route =
    KFR.Retry_after_observed
      { retry_class = KFR.Network_transient; retry_after = None }
  in
  check
    (option string)
    "retryable route stays pending for the next cycle"
    None
    (Loop.failed_selection_terminal_detail
       (failure
          ~route
          ~source_disposition:Turn.Follow_failure_route
          overflow_error))
;;

let test_transcript_corruption_owned_elsewhere () =
  check
    (option string)
    "transcript corruption is consumed by its own pause path"
    None
    (Loop.failed_selection_terminal_detail
       (failure
          ~route:(KFR.route_of_error ~boundary:KFR.Oas_execution overflow_error)
          ~source_disposition:
            (Turn.Pause_after_transcript_corruption { detail = "corrupt" })
          overflow_error))
;;

let () =
  run
    "keeper_failed_selection_disposition"
    [ ( "failed_selection_terminal_detail"
      , [ test_case
            "overflow without successor terminalizes"
            `Quick
            test_overflow_without_successor_terminalizes
        ; test_case
            "overflow with deferred lane preserves"
            `Quick
            test_overflow_with_deferred_lane_preserves
        ; test_case
            "other terminal classes preserve"
            `Quick
            test_other_terminal_classes_preserve
        ; test_case
            "retryable route preserves"
            `Quick
            test_retryable_route_preserves
        ; test_case
            "transcript corruption owned elsewhere"
            `Quick
            test_transcript_corruption_owned_elsewhere
        ] )
    ]
;;
