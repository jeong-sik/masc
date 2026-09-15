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

let sample ?(awaiting_approval = false) ~last_progress_at ~active_tool_count () =
  Some { Try_provider.last_progress_at; active_tool_count; awaiting_approval }
;;

let threshold_sec = 900.0
let attempt_started_at = 1_000_000.0

(* The attempt never waited for its admission permit. *)
let no_wait = Llm_provider.Provider_admission.Before_any_wait

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
       ~permit_wait:no_wait
       ~sample:(sample ~last_progress_at:(now -. 6.0) ~active_tool_count:0 ()))
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
       ~permit_wait:no_wait
       ~sample:(sample ~last_progress_at:(now -. 3_900.0) ~active_tool_count:0 ()))
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
       ~permit_wait:no_wait
       ~sample:(sample ~last_progress_at:(now -. 200.0) ~active_tool_count:1 ()))
;;

let test_the_threshold_boundary_is_exclusive () =
  let now = attempt_started_at +. threshold_sec in
  check bool "exactly at the threshold is not yet a stall" false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:no_wait
       ~sample:
         (sample ~last_progress_at:(now -. threshold_sec) ~active_tool_count:0 ()))
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
       ~permit_wait:no_wait
       ~sample:None);
  check bool "no sample, elapsed within the threshold, is not a stall" false
    (Try_provider.attempt_stalled
       ~now:(attempt_started_at +. 500.0)
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:no_wait
       ~sample:None)
;;

let test_a_bounded_permit_wait_is_not_a_stall () =
  (* A turn queued behind another keeper's stream refreshes no progress
     signal while it waits, and the wait has a deadline of its own, the
     admission bound; the watchdog stands down so that bound alone ends it,
     as [Queue], instead of the two racing for the same threshold. Only
     bounded waits write the cell, so the fallback with no sample stands
     down too without leaving anything unbounded. *)
  let now = attempt_started_at +. threshold_sec +. 1.0 in
  let waiting = Llm_provider.Provider_admission.Waiting_for_permit in
  check bool "queued past the threshold, with a sample, is not a stall" false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:waiting
       ~sample:(sample ~last_progress_at:(now -. threshold_sec -. 1.0) ~active_tool_count:0 ()));
  check bool "queued past the threshold, with no sample, is not a stall" false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:waiting
       ~sample:None)
;;

let test_the_watchdog_counts_from_the_end_of_the_permit_wait () =
  (* The wait's end is the instant the attempt's own budgets start from: a
     stream granted late runs under its first-event budget from the grant.
     The watchdog counts from that instant too, so a long queue is not
     charged to the provider the moment the permit comes; the silence that
     is a stall is the silence after the grant. *)
  let settled_at = attempt_started_at +. threshold_sec -. 1.0 in
  let settled = Llm_provider.Provider_admission.Wait_settled_at settled_at in
  let stale_sample = sample ~last_progress_at:attempt_started_at ~active_tool_count:0 () in
  let just_after_the_grant = settled_at +. threshold_sec -. 1.0 in
  check bool "a threshold of silence before the grant is not a stall after it" false
    (Try_provider.attempt_stalled
       ~now:just_after_the_grant
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:settled
       ~sample:stale_sample);
  check bool "nor is it with no sample" false
    (Try_provider.attempt_stalled
       ~now:just_after_the_grant
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:settled
       ~sample:None);
  let a_threshold_after_the_grant = settled_at +. threshold_sec +. 1.0 in
  check bool "a threshold of silence after the grant is a stall" true
    (Try_provider.attempt_stalled
       ~now:a_threshold_after_the_grant
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:settled
       ~sample:stale_sample);
  check bool "and with no sample" true
    (Try_provider.attempt_stalled
       ~now:a_threshold_after_the_grant
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:settled
       ~sample:None);
  (* A wait that settled before the attempt's own anchor changes nothing. *)
  let settled_early = Llm_provider.Provider_admission.Wait_settled_at (attempt_started_at -. 1.0) in
  check bool "a settle instant before the attempt started is not an anchor" true
    (Try_provider.attempt_stalled
       ~now:(attempt_started_at +. threshold_sec +. 1.0)
       ~threshold_sec
       ~attempt_started_at
       ~permit_wait:settled_early
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


(* A call held at the approval gate raises neither signal the predicate reads.
   The gate runs at pre_tool_use and ToolCalled -- what raises
   active_tool_count -- is published inside execute_admitted, which the gate
   runs before. So without this exclusion a keeper waiting on a person is
   indistinguishable from a provider that stopped answering, and with a
   deadline configured under the 180s approval bound the attempt is cancelled
   and the loss filed against the provider. The provider had answered. *)
let test_an_approval_wait_is_not_a_provider_stall () =
  let now = attempt_started_at +. 200.0 in
  check bool "waiting on an operator is not the provider going quiet" false
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec:60.0
       ~attempt_started_at
       ~permit_wait:no_wait
       ~sample:
         (sample
            ~awaiting_approval:true
            ~last_progress_at:(now -. 120.0)
            ~active_tool_count:0
            ()))
;;

(* The exclusion is not a way to switch the deadline off. Once the wait
   settles -- answered, denied, or timed out by the approval registry's own
   bound -- the same silence is a stall again. *)
let test_the_same_silence_stalls_once_the_wait_settles () =
  let now = attempt_started_at +. 200.0 in
  check bool "the identical reading stalls when no wait is open" true
    (Try_provider.attempt_stalled
       ~now
       ~threshold_sec:60.0
       ~attempt_started_at
       ~permit_wait:no_wait
       ~sample:
         (sample
            ~awaiting_approval:false
            ~last_progress_at:(now -. 120.0)
            ~active_tool_count:0
            ()))
;;

let test_yielded_provider_ignores_missing_tool_observation () =
  let now = attempt_started_at +. 4_000.0 in
  List.iter (fun observation ->
    check bool "main provider yielded; missing tool mirror is not a stall" false
      (Try_provider.provider_lease_stalled
         ~lease_phase:Try_provider.Provider_yielded ~now ~threshold_sec
         ~attempt_started_at ~permit_wait:no_wait ~sample:observation))
    [None; sample ~last_progress_at:attempt_started_at ~active_tool_count:0 ()]
;;

let test_provider_lease_callbacks_work_without_downstream () =
  let now = ref attempt_started_at in
  let phase, yield, resume = Try_provider.For_testing.observe_provider_lease
    ~now:(fun () -> !now) ~on_yield:None ~on_resume:None in
  yield ();
  now := !now +. 4_000.0;
  check bool "yield is tracked without optional callbacks" true
    (Atomic.get phase = Try_provider.Provider_yielded);
  resume ();
  check bool "resume starts the new inference window" true
    (Atomic.get phase = Try_provider.Provider_active_since !now)
;;

let test_provider_lease_callbacks_preserve_order_and_failure () =
  let now = ref attempt_started_at in
  let yielded = ref false in
  let phase, yield, resume = Try_provider.For_testing.observe_provider_lease
    ~now:(fun () -> !now)
    ~on_yield:(Some (fun () -> yielded := true))
    ~on_resume:(Some (fun () -> now := !now +. 4_000.0)) in
  yield ();
  check bool "original yield callback ran" true !yielded;
  resume ();
  check bool "baseline is stamped after downstream resume work" true
    (Atomic.get phase = Try_provider.Provider_active_since !now);
  let failure = Failure "resume rejected" in
  let phase, yield, resume = Try_provider.For_testing.observe_provider_lease
    ~now:(fun () -> !now) ~on_yield:None
    ~on_resume:(Some (fun () -> raise failure)) in
  yield ();
  check_raises "downstream failure propagates" failure resume;
  check bool "failed resume does not claim active inference" true
    (Atomic.get phase = Try_provider.Provider_yielded)
;;

let test_resumed_provider_gets_its_own_progress_window () =
  let resumed_at = attempt_started_at +. 4_000.0 in
  let lease_phase = Try_provider.Provider_active_since resumed_at in
  List.iter (fun observation ->
    check bool "time spent in the tool is excluded after resume" false
      (Try_provider.provider_lease_stalled ~lease_phase
         ~now:(resumed_at +. threshold_sec) ~threshold_sec
         ~attempt_started_at ~permit_wait:no_wait ~sample:observation);
    check bool "silent main provider still times out after resume" true
      (Try_provider.provider_lease_stalled ~lease_phase
         ~now:(resumed_at +. threshold_sec +. 1.0) ~threshold_sec
         ~attempt_started_at ~permit_wait:no_wait ~sample:observation))
    [None; sample ~last_progress_at:attempt_started_at ~active_tool_count:0 ()]
;;

let test_resumed_provider_retains_later_stream_progress () =
  let resumed_at = attempt_started_at +. 4_000.0 in
  let now = resumed_at +. threshold_sec +. 100.0 in
  check bool "fresh stream progress takes precedence over resume time" false
    (Try_provider.provider_lease_stalled
       ~lease_phase:(Try_provider.Provider_active_since resumed_at)
       ~now ~threshold_sec ~attempt_started_at ~permit_wait:no_wait
       ~sample:(sample ~last_progress_at:(now -. 1.0) ~active_tool_count:0 ()))
;;

(* {1 preempt_pre_first_token -- the first-token-wait preemption verdict (#36203/RFC-0441)} *)

let test_pre_first_token_with_a_person_queued_preempts () =
  check bool "no first event yet and a person waits -> preempt" true
    (Try_provider.preempt_pre_first_token ~first_event_seen:false ~person_queued:true)
;;

let test_first_event_seen_never_preempts () =
  (* Once the provider has produced anything, the tool-boundary yield owns the
     handover; preemption must not fire even with a person queued. *)
  check bool "first event seen and a person waits -> do not preempt" false
    (Try_provider.preempt_pre_first_token ~first_event_seen:true ~person_queued:true)
;;

let test_no_one_queued_never_preempts () =
  check bool "pre-first-token but no one queued -> do not preempt" false
    (Try_provider.preempt_pre_first_token ~first_event_seen:false ~person_queued:false)
;;

let test_first_event_seen_and_no_one_queued_never_preempts () =
  check bool "first event seen and no one queued -> do not preempt" false
    (Try_provider.preempt_pre_first_token ~first_event_seen:true ~person_queued:false)
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
        ; test_case "yielded lease excludes missing tool observations" `Quick
            test_yielded_provider_ignores_missing_tool_observation
        ; test_case "lease callbacks work without downstream observers" `Quick
            test_provider_lease_callbacks_work_without_downstream
        ; test_case "lease callbacks preserve ordering and failures" `Quick
            test_provider_lease_callbacks_preserve_order_and_failure
        ; test_case "resumed lease has its own progress window" `Quick
            test_resumed_provider_gets_its_own_progress_window
        ; test_case "resumed lease keeps later stream progress" `Quick
            test_resumed_provider_retains_later_stream_progress
        ; test_case "a wedged attempt is stalled" `Quick
            test_a_wedged_attempt_is_stalled
        ; test_case "a tool in flight is not a stall" `Quick
            test_a_tool_in_flight_is_not_a_stall
        ; test_case "an approval wait is not a provider stall" `Quick
            test_an_approval_wait_is_not_a_provider_stall
        ; test_case "the same silence stalls once the wait settles" `Quick
            test_the_same_silence_stalls_once_the_wait_settles
        ; test_case "the threshold boundary is exclusive" `Quick
            test_the_threshold_boundary_is_exclusive
        ; test_case "a missing sample falls back to elapsed" `Quick
            test_a_missing_sample_falls_back_to_elapsed
        ; test_case "a bounded permit wait is not a stall" `Quick
            test_a_bounded_permit_wait_is_not_a_stall
        ; test_case
            "the watchdog counts from the end of the permit wait"
            `Quick
            test_the_watchdog_counts_from_the_end_of_the_permit_wait
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
    ; ( "preempt_pre_first_token"
      , [ test_case "a person queued pre-first-token preempts" `Quick
            test_pre_first_token_with_a_person_queued_preempts
        ; test_case "first event seen never preempts" `Quick
            test_first_event_seen_never_preempts
        ; test_case "no one queued never preempts" `Quick
            test_no_one_queued_never_preempts
        ; test_case "first event seen and no one queued never preempts" `Quick
            test_first_event_seen_and_no_one_queued_never_preempts
        ] )
    ]
;;
