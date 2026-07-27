(* Whether a cycle's selected stimulus leaves the pending queue.

   A selection that stays pending is re-selected on the next cycle, so an
   arm answering [false] asserts that running the same stimulus again can
   produce a different outcome. For a route the SSOT already calls
   deterministic that assertion is false, and the keeper spends provider
   turns forever. *)

open Alcotest

module Loop = Masc.Keeper_heartbeat_loop
module Cycle = Masc.Keeper_heartbeat_loop_cycle
module Route = Keeper_runtime_failure_route
module Turn = Masc.Keeper_unified_turn

let meta () =
  Masc_test_deps.meta_of_json_fixture
    (`Assoc [ "name", `String "keeper"; "trace_id", `String "trace-keeper" ])
  |> Result.get_ok
;;

let failure ~route ~disposition =
  { Turn.error = Agent_sdk.Error.Internal "deterministic rejection"
  ; runtime_id = "runtime"
  ; route
  ; source_lease_disposition = disposition
  ; deferred_runtime_lane = None
  }
;;

let exhausted =
  Route.Exhausted_visible_alive
    { terminal = Route.Deterministic_request
    ; provenance = Route.Oas_api_error
    ; detail = "request body rejected"
    }
;;

let retryable =
  Route.Retry_after_observed { retry_class = Route.Rate_limited; retry_after = None }
;;

let rotatable = Route.Rotate_now { rotate = Route.Auth_failed }

let settled ~route ~disposition =
  Loop.For_testing.selection_is_settled
    (Some (Cycle.Failed { meta = meta (); failure = failure ~route ~disposition }))
;;

let test_exhausted_route_settles_its_selection () =
  List.iter
    (fun (label, disposition) ->
       check
         bool
         (label ^ ": a deterministically exhausted selection does not stay pending")
         true
         (settled ~route:exhausted ~disposition))
    [ "follow_failure_route", Turn.Follow_failure_route
    ; ( "follow_failure_route_after_no_compaction"
      , Turn.Follow_failure_route_after_no_compaction
          { reason = Keeper_event_queue_state.No_eligible_history } )
    ]
;;

let test_recoverable_routes_keep_their_selection () =
  List.iter
    (fun (label, route) ->
       check
         bool
         (label ^ ": a route that another attempt can satisfy stays pending")
         false
         (settled ~route ~disposition:Turn.Follow_failure_route))
    [ "retry_after_observed", retryable; "rotate_now", rotatable ]
;;

let test_route_decides_only_when_the_disposition_defers_to_it () =
  check
    bool
    "an in-turn acknowledgement settles regardless of route"
    true
    (settled ~route:retryable ~disposition:Turn.Acknowledge_after_in_turn_handling);
  check
    bool
    "a transcript pause keeps its selection even when the route is exhausted"
    false
    (settled
       ~route:exhausted
       ~disposition:(Turn.Pause_after_transcript_corruption { detail = "orphan" }))
;;

let test_non_failure_outcomes_are_unchanged () =
  check
    bool
    "a completed cycle settles"
    true
    (Loop.For_testing.selection_is_settled (Some (Cycle.Completed (meta ()))));
  check
    bool
    "a cancelled cycle keeps its selection"
    false
    (Loop.For_testing.selection_is_settled (Some (Cycle.Cancelled (meta ()))));
  check
    bool
    "no outcome keeps its selection"
    false
    (Loop.For_testing.selection_is_settled None)
;;

let () =
  run
    "Keeper selection settlement"
    [ ( "route"
      , [ test_case
            "exhausted route settles its selection"
            `Quick
            test_exhausted_route_settles_its_selection
        ; test_case
            "recoverable routes keep their selection"
            `Quick
            test_recoverable_routes_keep_their_selection
        ; test_case
            "route decides only when the disposition defers to it"
            `Quick
            test_route_decides_only_when_the_disposition_defers_to_it
        ; test_case
            "non-failure outcomes are unchanged"
            `Quick
            test_non_failure_outcomes_are_unchanged
        ] )
    ]
;;
