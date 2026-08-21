(** Tests for #27320 — context-overflow feedback shrink.

    Two units are covered directly:

    - {!Keeper_turn_driver_try_provider.context_overflow_shrink_sequence}:
      the pure same-runtime retry policy. Injects a fake [attempt] callback
      so the halving sequence, the attempt cap, the same-run-retry-authority
      gate, and the "only a typed overflow retries" rule are verified
      without an Eio-backed provider.
    - {!Keeper_context_overflow_shrink_state}: the process-local (keeper,
      runtime) memory of the last capacity that succeeded.

    [run_try_provider_with_context_overflow_shrink] itself wires these two
    together with the real [run_try_provider]/[Runtime_agent.run] provider
    call, which (like [run_try_provider] before it) has no unit-level
    fixture in this suite — see [test_keeper_turn_driver_failover.ml] for
    the candidate-rotation layer's equivalent boundary. *)

module Try_provider = Masc.Keeper_turn_driver_try_provider
module Shrink_state = Masc.Keeper_context_overflow_shrink_state

open Alcotest

let context_overflow ?(limit = Some 32_768) () =
  Agent_core.Error.Api
    (ContextOverflow { message = "exceeded"; limit })
;;

let network_error () =
  Agent_core.Error.Api
    (NetworkError
       { message = "Connection_reset"
       ; kind = Llm_provider.Http_client.Connection_refused
       })
;;

let always_authorized () = true

let no_shrink_expected ~capacity_bytes:_ = fail "unexpected shrink retry"

(* {1 context_overflow_shrink_sequence} *)

let test_halves_capacity_on_repeated_overflow_until_success () =
  let attempted_capacities = ref [] in
  let attempt ~capacity_bytes =
    attempted_capacities := capacity_bytes :: !attempted_capacities;
    if capacity_bytes <= 128 then Ok "done" else Error (context_overflow ())
  in
  let recorded_success = ref None in
  let shrink_events = ref [] in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~record_success:(fun ~capacity_bytes -> recorded_success := Some capacity_bytes)
      ~on_shrink_retry:(fun ~shrink_attempt ~previous_capacity_bytes ~capacity_bytes ->
        shrink_events :=
          (shrink_attempt, previous_capacity_bytes, capacity_bytes) :: !shrink_events)
      ~attempt
      ()
  in
  check bool "eventually succeeds" true (result = Ok "done");
  check (list int) "capacity halves each retry: 1024, 512, 256, 128"
    [ 1024; 512; 256; 128 ]
    (List.rev !attempted_capacities);
  check (option int) "records the capacity that succeeded" (Some 128) !recorded_success;
  check
    (list (triple int int int))
    "shrink events carry (attempt, previous, next) in order"
    [ 1, 1024, 512; 2, 512, 256; 3, 256, 128 ]
    (List.rev !shrink_events)
;;

let test_stops_at_the_named_attempt_cap_then_falls_through () =
  let attempted_capacities = ref [] in
  let attempt ~capacity_bytes =
    attempted_capacities := capacity_bytes :: !attempted_capacities;
    Error (context_overflow ())
  in
  let shrink_count = ref 0 in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~record_success:(fun ~capacity_bytes:_ -> fail "overflow never succeeds here")
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes:_ ->
        incr shrink_count)
      ~attempt
      ()
  in
  check bool "the last (unshrinkable) overflow is returned unchanged" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check int "exactly the named cap worth of shrink retries fired"
    Try_provider.For_testing.context_overflow_shrink_max_attempts
    !shrink_count;
  let expected_attempts_count =
    Try_provider.For_testing.context_overflow_shrink_max_attempts + 1
  in
  check int "one initial attempt plus one per shrink retry"
    expected_attempts_count
    (List.length !attempted_capacities);
  let divisor = Try_provider.For_testing.context_overflow_shrink_divisor in
  let rec expected capacity n =
    if n = 0 then [ capacity ] else capacity :: expected (capacity / divisor) (n - 1)
  in
  check (list int) "capacities halve down to the cap"
    (expected 1024 Try_provider.For_testing.context_overflow_shrink_max_attempts)
    (List.rev !attempted_capacities)
;;

let test_non_overflow_error_never_shrinks () =
  let attempts = ref 0 in
  let attempt ~capacity_bytes:_ =
    incr attempts;
    Error (network_error ())
  in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~record_success:(fun ~capacity_bytes:_ -> fail "network error never succeeds")
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes ->
        no_shrink_expected ~capacity_bytes)
      ~attempt
      ()
  in
  check int "attempted exactly once" 1 !attempts;
  check bool "the network error propagates unchanged" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.NetworkError _)) -> true
     | _ -> false)
;;

let test_checkpoint_boundary_blocks_shrink_even_on_overflow () =
  (* Mirrors the exact same-run retry authority gate the declared-lane
     candidate walk applies via [checkpoint_allows_candidate_transition] /
     [checkpoint_stage_observed]: once AGENT_CORE has mutated agent state at a
     durable checkpoint stage, a same-run retry (shrink included) must not
     fire. *)
  let attempts = ref 0 in
  let attempt ~capacity_bytes:_ =
    incr attempts;
    Error (context_overflow ())
  in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:(fun () -> false)
      ~record_success:(fun ~capacity_bytes:_ -> fail "no success expected")
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes ->
        no_shrink_expected ~capacity_bytes)
      ~attempt
      ()
  in
  check int "attempted exactly once" 1 !attempts;
  check bool "the overflow propagates unchanged" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | _ -> false)
;;

let test_custom_shrink_replaces_only_the_exceptional_start () =
  let attempted_capacities = ref [] in
  let attempt ~capacity_bytes =
    attempted_capacities := capacity_bytes :: !attempted_capacities;
    if capacity_bytes <= 200 then Ok "done" else Error (context_overflow ())
  in
  let sentinel = max_int in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:sentinel
      ~same_run_retry_authorized:always_authorized
      ~shrink_capacity:(fun ~capacity_bytes ~default_capacity_bytes ->
        if capacity_bytes = sentinel then 400 else default_capacity_bytes)
      ~record_success:(fun ~capacity_bytes:_ -> ())
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes:_ -> ())
      ~attempt
      ()
  in
  check bool "eventually succeeds" true (result = Ok "done");
  check
    (list int)
    "custom start then shared default halving"
    [ sentinel; 400; 200 ]
    (List.rev !attempted_capacities)
;;

let test_non_decreasing_custom_shrink_does_not_repeat_provider_attempt () =
  let attempted_capacities = ref [] in
  let shrink_events = ref 0 in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:400
      ~same_run_retry_authorized:always_authorized
      ~shrink_capacity:(fun ~capacity_bytes ~default_capacity_bytes:_ ->
        capacity_bytes)
      ~record_success:(fun ~capacity_bytes:_ -> fail "overflow never succeeds here")
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes:_ ->
          incr shrink_events)
      ~attempt:(fun ~capacity_bytes ->
        attempted_capacities := capacity_bytes :: !attempted_capacities;
        Error (context_overflow ()))
      ()
  in
  check bool "the original overflow is preserved" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check (list int) "the provider sees one request" [ 400 ]
    (List.rev !attempted_capacities);
  check int "no false shrink event is emitted" 0 !shrink_events
;;

let test_last_retry_uses_the_measured_floor () =
  let attempted_capacities = ref [] in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~final_shrink_capacity:(fun ~capacity_bytes:_ -> Some 17)
      ~record_success:(fun ~capacity_bytes:_ -> fail "overflow never succeeds here")
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes:_ -> ())
      ~attempt:(fun ~capacity_bytes ->
        attempted_capacities := capacity_bytes :: !attempted_capacities;
        Error (context_overflow ()))
      ()
  in
  check bool "the floor overflow is preserved" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check
    (list int)
    "the final bounded dispatch jumps to the measured floor"
    [ 1024; 512; 256; 17 ]
    (List.rev !attempted_capacities)
;;

(* {1 Keeper_context_overflow_shrink_state} *)

let test_state_defaults_to_max_capacity_when_unseen () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  check int "no memory yet: falls back to the declared cap" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"sangsu" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let test_state_remembers_last_success () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"sangsu" ~runtime_id:"agent_core-primary" ~capacity_bytes:131_072;
  check int "next turn starts from the remembered capacity" 131_072
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"sangsu" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let test_state_clamps_a_remembered_value_above_the_current_cap () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"sangsu" ~runtime_id:"agent_core-primary" ~capacity_bytes:2_097_152;
  check int "a stale remembered value never exceeds the current declared cap"
    1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"sangsu" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let test_state_is_keyed_per_keeper_and_runtime () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"sangsu" ~runtime_id:"agent_core-primary" ~capacity_bytes:131_072;
  check int "a different runtime on the same keeper is unaffected" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"sangsu" ~runtime_id:"agent_core-fallback" ~max_capacity_bytes:1_048_576);
  check int "the same runtime id on a different keeper is unaffected" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"analyst" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let () =
  run
    "keeper_context_overflow_shrink"
    [ ( "context_overflow_shrink_sequence"
      , [ test_case
            "halves capacity on repeated overflow until success"
            `Quick
            test_halves_capacity_on_repeated_overflow_until_success
        ; test_case
            "stops at the named attempt cap then falls through"
            `Quick
            test_stops_at_the_named_attempt_cap_then_falls_through
        ; test_case
            "a non-overflow error never shrinks"
            `Quick
            test_non_overflow_error_never_shrinks
        ; test_case
            "a checkpoint boundary blocks shrink even on overflow"
            `Quick
            test_checkpoint_boundary_blocks_shrink_even_on_overflow
        ; test_case
            "custom shrink replaces only the exceptional start"
            `Quick
            test_custom_shrink_replaces_only_the_exceptional_start
        ; test_case
            "a non-decreasing custom shrink does not repeat the provider attempt"
            `Quick
            test_non_decreasing_custom_shrink_does_not_repeat_provider_attempt
        ; test_case
            "the last retry uses the measured floor"
            `Quick
            test_last_retry_uses_the_measured_floor
        ] )
    ; ( "shrink_state"
      , [ test_case
            "defaults to max capacity when unseen"
            `Quick
            test_state_defaults_to_max_capacity_when_unseen
        ; test_case
            "remembers last success"
            `Quick
            test_state_remembers_last_success
        ; test_case
            "clamps a remembered value above the current cap"
            `Quick
            test_state_clamps_a_remembered_value_above_the_current_cap
        ; test_case
            "is keyed per (keeper, runtime)"
            `Quick
            test_state_is_keyed_per_keeper_and_runtime
        ] )
    ]
;;
