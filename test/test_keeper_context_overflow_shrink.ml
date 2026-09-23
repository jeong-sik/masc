(** Tests for #27320 — context-overflow feedback shrink on the
    official-client lanes.

    {!Keeper_turn_driver_try_provider.context_overflow_shrink_sequence} is
    the pure same-runtime retry policy. The suite injects a fake [attempt]
    callback so the halving sequence, the walk to the floor, the
    same-run-retry-authority gate, and the "only a typed overflow retries"
    rule are verified without an Eio-backed provider.

    [Keeper_claude_code_runtime] and [Keeper_codex_runtime] wire it to their
    real provider call, which has no unit-level fixture
    in this suite — see [test_keeper_turn_driver_failover.ml] for the
    candidate-rotation layer's equivalent boundary. The Agent Core lane's
    retry is [carried_range_eviction_sequence], covered in
    [test_keeper_carried_range_eviction.ml]. *)

module Try_provider = Masc.Keeper_turn_driver_try_provider

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

(* Every capacity leaves room for history unless a test says otherwise. *)
let always_admits_history ~capacity:_ = true

let no_shrink_expected ~capacity:_ = fail "unexpected shrink retry"

(* {1 context_overflow_shrink_sequence} *)

let test_halves_capacity_on_repeated_overflow_until_success () =
  let attempted_capacities = ref [] in
  let attempt ~capacity =
    attempted_capacities := capacity :: !attempted_capacities;
    if capacity <= 128 then Ok "done" else Error (context_overflow ())
  in
  let shrink_events = ref [] in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:(fun ~shrink_attempt ~previous_capacity ~capacity ->
        shrink_events :=
          (shrink_attempt, previous_capacity, capacity) :: !shrink_events)
      ~attempt
      ()
  in
  check bool "eventually succeeds" true (result = Ok "done");
  check (list int) "capacity halves each retry: 1024, 512, 256, 128"
    [ 1024; 512; 256; 128 ]
    (List.rev !attempted_capacities);
  check
    (list (triple int int int))
    "shrink events carry (attempt, previous, next) in order"
    [ 1, 1024, 512; 2, 512, 256; 3, 256, 128 ]
    (List.rev !shrink_events)
;;

(* The walk goes on while the lane names a strictly smaller view and stops
   the moment it cannot; six halvings here, every one attempted. *)
let test_walks_until_no_smaller_view_is_named () =
  let attempted_capacities = ref [] in
  let attempt ~capacity =
    attempted_capacities := capacity :: !attempted_capacities;
    Error (context_overflow ())
  in
  let smallest_view = 16 in
  let shrink_count = ref 0 in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_capacity:(fun ~capacity ~default_capacity ->
        (* The lane names the halved view until the smallest one; after that
           it names the rejected view itself, which is no smaller view. *)
        if capacity <= smallest_view then capacity else default_capacity)
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ ->
        incr shrink_count)
      ~attempt
      ()
  in
  check bool "the last (unshrinkable) overflow is returned unchanged" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check (list int) "every named view was attempted, down to the smallest"
    [ 1024; 512; 256; 128; 64; 32; 16 ]
    (List.rev !attempted_capacities);
  check int "one shrink retry per named view" 6 !shrink_count
;;

let test_non_overflow_error_never_shrinks () =
  let attempts = ref 0 in
  let attempt ~capacity:_ =
    incr attempts;
    Error (network_error ())
  in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity ->
        no_shrink_expected ~capacity)
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
     candidate walk applies via [same_run_retry_allowed] /
     [checkpoint_progress]: once AGENT_CORE has mutated agent state at a
     durable checkpoint stage, a same-run retry (shrink included) must not
     fire. *)
  let attempts = ref 0 in
  let attempt ~capacity:_ =
    incr attempts;
    Error (context_overflow ())
  in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:(fun () -> false)
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity ->
        no_shrink_expected ~capacity)
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
  let attempt ~capacity =
    attempted_capacities := capacity :: !attempted_capacities;
    if capacity <= 200 then Ok "done" else Error (context_overflow ())
  in
  let sentinel = max_int in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:sentinel
      ~same_run_retry_authorized:always_authorized
      ~shrink_capacity:(fun ~capacity ~default_capacity ->
        if capacity = sentinel then 400 else default_capacity)
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ -> ())
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
      ~starting_capacity:400
      ~same_run_retry_authorized:always_authorized
      ~shrink_capacity:(fun ~capacity ~default_capacity:_ ->
        capacity)
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ ->
          incr shrink_events)
      ~attempt:(fun ~capacity ->
        attempted_capacities := capacity :: !attempted_capacities;
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

(* The floor is the last view: once the ordinary halving would reach or
   pass it, the floor is attempted instead, and nothing is attempted below
   it. *)
let test_the_floor_is_the_last_view () =
  let attempted_capacities = ref [] in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:always_authorized
      ~final_shrink_capacity:(fun ~capacity:_ -> Some 17)
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ -> ())
      ~attempt:(fun ~capacity ->
        attempted_capacities := capacity :: !attempted_capacities;
        Error (context_overflow ()))
      ()
  in
  check bool "the floor overflow is preserved" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check
    (list int)
    "halving runs until it would pass the floor, then the floor is asked once"
    [ 1024; 512; 256; 128; 64; 32; 17 ]
    (List.rev !attempted_capacities)
;;


(* #31684, measured on keeper edgar.a.poe: a 469638-byte non-history reserve
   (tool schemas + system prompt + the unmeasured-field allowance) against a
   524288-byte declared cap. Halving cannot help — 262144 is already smaller
   than the reserve — yet the sequence spent every attempt discovering that,
   and the keeper failed the same way on every turn. The admissibility
   verdict ends the sequence at the first proposal the reserve rules out. *)
let test_a_reserve_larger_than_the_next_capacity_stops_the_shrink () =
  let reserve_bytes = 469_638 in
  let attempted_capacities = ref [] in
  let shrink_count = ref 0 in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:524_288
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:(fun ~capacity -> reserve_bytes < capacity)
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ ->
          incr shrink_count)
      ~attempt:(fun ~capacity ->
        attempted_capacities := capacity :: !attempted_capacities;
        Error (context_overflow ()))
      ()
  in
  check bool "the original overflow reaches the lane walk unchanged" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check (list int) "only the declared capacity is dispatched" [ 524_288 ]
    (List.rev !attempted_capacities);
  check int "no shrink retry fires" 0 !shrink_count
;;

(* An admissible first step still shrinks, and the sequence stops at the
   first inadmissible one rather than at a fixed attempt count. *)
let test_the_shrink_stops_at_the_first_inadmissible_step () =
  let attempted_capacities = ref [] in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:(fun ~capacity -> capacity >= 512)
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ -> ())
      ~attempt:(fun ~capacity ->
        attempted_capacities := capacity :: !attempted_capacities;
        Error (context_overflow ()))
      ()
  in
  check bool "the surviving overflow is returned" true
    (match result with
     | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) -> true
     | Error _ | Ok _ -> false);
  check (list int) "512 is admissible and dispatched; 256 is not" [ 1024; 512 ]
    (List.rev !attempted_capacities)
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
            "walks until no smaller view is named"
            `Quick
            test_walks_until_no_smaller_view_is_named
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
            "the floor is the last view"
            `Quick
            test_the_floor_is_the_last_view
        ; test_case
            "a reserve larger than the next capacity stops the shrink"
            `Quick
            test_a_reserve_larger_than_the_next_capacity_stops_the_shrink
        ; test_case
            "the shrink stops at the first inadmissible step"
            `Quick
            test_the_shrink_stops_at_the_first_inadmissible_step
        ] )
    ]
;;
