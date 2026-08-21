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

    - {!Masc.Keeper_turn_driver_try_provider.attempt_stalled}: the stall
      verdict itself (#28417). #27349 measured the deadline against total
      elapsed time, which cannot separate "a turn that stopped" from "a turn
      that is taking a while"; the fixtures below are the two 2026-08-12
      production attempts that proved it, one of each kind.

    The Eio fiber race that applies the verdict has no unit fixture, matching
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

(* {1 attempt_stalled -- the verdict the deadline now applies (#28417)} *)

module Try_provider = Masc.Keeper_turn_driver_try_provider

let sample ~last_progress_at ~active_tool_count =
  Some { Try_provider.last_progress_at; active_tool_count }
;;

let threshold_sec = 900.0
let attempt_started_at = 1_000_000.0

let test_a_progressing_attempt_is_not_stalled () =
  (* Live, 2026-08-12 13:59:44Z: the attempt was cancelled 6 seconds after a
     successful masc_transition, with 30+ tool calls inside the window. Its
     ELAPSED time had reached the threshold -- which is exactly why the
     pre-#28417 axis killed it -- while its progress was 6 seconds old. *)
  let now = attempt_started_at +. threshold_sec +. 1.0 in
  check bool "progress 6s ago is not a stall, however long the attempt ran"
    false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec
       ~attempt_started_at
       ~sample:(sample ~last_progress_at:(now -. 6.0) ~active_tool_count:0))
;;

let test_a_wedged_attempt_is_stalled () =
  (* Live, 2026-08-12 10:04Z-11:10Z: zero trajectory events for 65 minutes.
     This is the class #27355 introduced the deadline for and it must still
     fire on the new axis. *)
  let now = attempt_started_at +. 4_000.0 in
  check bool "65 minutes without a progress signal is a stall" true
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec
       ~attempt_started_at
       ~sample:(sample ~last_progress_at:(now -. 3_900.0) ~active_tool_count:0))
;;

let test_a_tool_in_flight_is_not_a_stall () =
  (* One Execute ran 120s inside beta's window without refreshing the
     progress signal. A tool that has been issued but not completed is work,
     not a stall -- the exclusion [active_tool_count] has documented since
     RFC-0197 with no code reading it until now. *)
  let now = attempt_started_at +. 500.0 in
  check bool "a tool in flight suppresses the stall verdict" false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec:60.0
       ~attempt_started_at
       ~sample:(sample ~last_progress_at:(now -. 200.0) ~active_tool_count:1))
;;

let test_the_threshold_boundary_is_exclusive () =
  let now = attempt_started_at +. threshold_sec in
  check bool "exactly at the threshold is not yet a stall" false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec
       ~attempt_started_at
       ~sample:
         (sample ~last_progress_at:(now -. threshold_sec) ~active_tool_count:0))
;;

let test_a_missing_sample_falls_back_to_elapsed () =
  (* Losing the progress signal must not silently disable enforcement, so the
     verdict degrades to the pre-#28417 elapsed ceiling rather than to
     "never stalled". *)
  check bool "no sample, elapsed past the threshold, is a stall" true
    (Try_provider.attempt_stalled
       ~now:(attempt_started_at +. threshold_sec +. 1.0)
       ~threshold_sec
       ~attempt_started_at
       ~sample:None);
  check bool "no sample, elapsed within the threshold, is not a stall" false
    (Try_provider.attempt_stalled
       ~now:(attempt_started_at +. 500.0)
       ~threshold_sec
       ~attempt_started_at
       ~sample:None)
;;

(* {1 the synthetic Wall_clock timeout joins existing paths} *)

let wall_clock_timeout () =
  Agent_core.Error.Api
    (Llm_provider.Retry.Timeout
       { message = "provider call exceeded the configured wall-clock deadline"
       ; phase = Some Llm_provider.Http_client.Wall_clock
       })
;;

let test_wall_clock_timeout_carries_the_wall_clock_phase () =
  match wall_clock_timeout () with
  | Agent_core.Error.Api (Llm_provider.Retry.Timeout { phase; _ }) ->
    check bool "phase is Wall_clock" true
      (match phase with
       | Some Llm_provider.Http_client.Wall_clock -> true
       | Some _ | None -> false)
  | _ -> fail "expected Api (Timeout _)"
;;

let test_wall_clock_timeout_joins_existing_candidate_rotation () =
  let http_error =
    Masc.Keeper_turn_driver_try_runtime.core_error_to_http_error
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
       (Agent_core.Error.Api
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
    ; ( "attempt_stalled"
      , [ test_case "a progressing attempt is not stalled" `Quick
            test_a_progressing_attempt_is_not_stalled
        ; test_case "a wedged attempt is stalled" `Quick
            test_a_wedged_attempt_is_stalled
        ; test_case "a tool in flight is not a stall" `Quick
            test_a_tool_in_flight_is_not_a_stall
        ; test_case "the threshold boundary is exclusive" `Quick
            test_the_threshold_boundary_is_exclusive
        ; test_case "a missing sample falls back to elapsed" `Quick
            test_a_missing_sample_falls_back_to_elapsed
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
