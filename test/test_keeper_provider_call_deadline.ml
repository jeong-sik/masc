(** Tests for #27349 -- provider-call wall-clock deadline + in-flight
    elapsed-time observation.

    Two units, both pure and Eio-free:

    - {!Masc.Keeper_heartbeat_loop_in_turn_pulse.in_flight_elapsed_ms} /
      [since_last_progress_ms]: the raw elapsed-time facts the heartbeat
      pulse carries every tick. No threshold lives in these functions --
      they only compute a delta, floored at zero for clock-skew safety.
    - The synthetic [Api (Timeout { phase = Some Wall_clock })] value that
      [Keeper_turn_driver_try_provider.run_try_provider] constructs when the
      operator-configured deadline fires: this proves (not just documents)
      that it joins the EXISTING declared-lane candidate rotation
      ([Runtime_attempt_fsm.should_try_next]) and the EXISTING post-hoc
      provider-timeout observation channel
      ([Keeper_provider_runtime_boundary.is_provider_timeout_error]) without
      any change to either classifier.

    The Eio.Time.with_timeout_exn wrap itself has no unit fixture, matching
    this file's existing coverage boundary (no test calls [run_try_provider]
    directly either -- see test_keeper_turn_driver_failover.ml for the
    candidate-rotation layer's equivalent boundary). *)

module Pulse = Masc.Keeper_heartbeat_loop_in_turn_pulse

open Alcotest

(* {1 in_flight_elapsed_ms / since_last_progress_ms} *)

let test_in_flight_elapsed_ms_computes_delta () =
  check (float 0.001) "12.5s since start is 12500ms" 12_500.0
    (Pulse.in_flight_elapsed_ms ~now_ts:1_000_012.5 ~started_at:1_000_000.0)
;;

let test_in_flight_elapsed_ms_floors_at_zero () =
  (* Clock skew or a registry read racing a fresh [started_at] stamp must
     never report a negative "elapsed" to a consumer. *)
  check (float 0.001) "now before started_at floors at 0" 0.0
    (Pulse.in_flight_elapsed_ms ~now_ts:999_999.0 ~started_at:1_000_000.0)
;;

let test_since_last_progress_ms_computes_delta () =
  check (float 0.001) "25 minutes since last progress is 1_500_000ms"
    1_500_000.0
    (Pulse.since_last_progress_ms ~now_ts:1_001_500.0 ~last_progress_at:1_000_000.0)
;;

let test_since_last_progress_ms_floors_at_zero () =
  check (float 0.001) "now before last_progress_at floors at 0" 0.0
    (Pulse.since_last_progress_ms ~now_ts:999_000.0 ~last_progress_at:1_000_000.0)
;;

let test_a_steadily_progressing_turn_stays_near_zero () =
  (* The #27349 design point: a long-running but healthy turn (last progress
     1s ago) reads near zero, distinguishable at a glance from a stalled one
     (last progress unbounded minutes ago), even though both may have the
     same large [in_flight_elapsed_ms]. *)
  let now_ts = 1_000_002.0 in
  let started_at = 1_000_000.0 in
  let last_progress_at = 1_000_001.999 in
  check (float 0.001) "in-flight elapsed is large" 2_000.0
    (Pulse.in_flight_elapsed_ms ~now_ts ~started_at);
  check (float 0.001) "since-last-progress stays small" 1.0
    (Pulse.since_last_progress_ms ~now_ts ~last_progress_at)
;;

(* {1 the synthetic Wall_clock timeout joins existing paths} *)

let wall_clock_timeout () =
  Masc_agent_core.Error.Api
    (Llm_provider.Retry.Timeout
       { message = "provider call exceeded the configured wall-clock deadline"
       ; phase = Some Llm_provider.Http_client.Wall_clock
       })
;;

let test_wall_clock_timeout_carries_the_wall_clock_phase () =
  match wall_clock_timeout () with
  | Masc_agent_core.Error.Api (Llm_provider.Retry.Timeout { phase; _ }) ->
    check bool "phase is Wall_clock" true
      (match phase with
       | Some Llm_provider.Http_client.Wall_clock -> true
       | Some _ | None -> false)
  | _ -> fail "expected Api (Timeout _)"
;;

let test_wall_clock_timeout_joins_existing_candidate_rotation () =
  let http_error =
    Masc.Keeper_turn_driver_try_runtime.sdk_error_to_http_error
      (wall_clock_timeout ())
  in
  match http_error with
  | Some err ->
    check bool
      "a same-lane deadline timeout retries the next declared-lane candidate"
      true
      (Runtime_attempt_fsm.should_try_next err)
  | None -> fail "expected the timeout to map to an http_error"
;;

let test_wall_clock_timeout_joins_existing_provider_timeout_observation () =
  check bool
    "the existing post-hoc provider-timeout observation channel recognizes it"
    true
    (Masc.Keeper_provider_runtime_boundary.is_provider_timeout_error
       (wall_clock_timeout ()))
;;

let test_non_timeout_error_does_not_trip_the_observation_channel () =
  check bool
    "an unrelated error is not misclassified as a provider timeout"
    false
    (Masc.Keeper_provider_runtime_boundary.is_provider_timeout_error
       (Masc_agent_core.Error.Api
          (Llm_provider.Retry.ContextOverflow { message = "exceeded"; limit = None })))
;;

let () =
  run
    "keeper_provider_call_deadline"
    [ ( "elapsed_ms"
      , [ test_case "computes in-flight delta" `Quick
            test_in_flight_elapsed_ms_computes_delta
        ; test_case "floors in-flight delta at zero" `Quick
            test_in_flight_elapsed_ms_floors_at_zero
        ; test_case "computes since-last-progress delta" `Quick
            test_since_last_progress_ms_computes_delta
        ; test_case "floors since-last-progress delta at zero" `Quick
            test_since_last_progress_ms_floors_at_zero
        ; test_case "a steadily progressing turn stays near zero" `Quick
            test_a_steadily_progressing_turn_stays_near_zero
        ] )
    ; ( "wall_clock_timeout_integration"
      , [ test_case "carries the Wall_clock phase" `Quick
            test_wall_clock_timeout_carries_the_wall_clock_phase
        ; test_case "joins existing candidate rotation" `Quick
            test_wall_clock_timeout_joins_existing_candidate_rotation
        ; test_case "joins existing provider-timeout observation" `Quick
            test_wall_clock_timeout_joins_existing_provider_timeout_observation
        ; test_case "a non-timeout error is not misclassified" `Quick
            test_non_timeout_error_does_not_trip_the_observation_channel
        ] )
    ]
;;
