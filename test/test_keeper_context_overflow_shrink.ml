(** Tests for #27320 — context-overflow feedback shrink.

    Two units are covered directly:

    - {!Keeper_turn_driver_try_provider.context_overflow_shrink_sequence}:
      the pure same-runtime retry policy. Injects a fake [attempt] callback
      so the halving sequence, the walk to the floor, the same-run-retry-authority
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

(* Every capacity leaves room for history unless a test says otherwise. *)
let always_admits_history ~capacity_bytes:_ = true

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
      ~shrink_admits_history:always_admits_history
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

(* No attempt count: the walk goes on while the lane names a strictly
   smaller view and stops the moment it cannot. Six halvings here would have
   been cut at three by the count this replaces. *)
let test_walks_until_no_smaller_view_is_named () =
  let attempted_capacities = ref [] in
  let attempt ~capacity_bytes =
    attempted_capacities := capacity_bytes :: !attempted_capacities;
    Error (context_overflow ())
  in
  let smallest_view = 16 in
  let shrink_count = ref 0 in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_capacity:(fun ~capacity_bytes ~default_capacity_bytes ->
        (* The lane names the halved view until the smallest one; after that
           it names the rejected view itself, which is no smaller view. *)
        if capacity_bytes <= smallest_view then capacity_bytes else default_capacity_bytes)
      ~shrink_admits_history:always_admits_history
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
  check (list int) "every named view was attempted, down to the smallest"
    [ 1024; 512; 256; 128; 64; 32; 16 ]
    (List.rev !attempted_capacities);
  check int "one shrink retry per named view" 6 !shrink_count
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
      ~shrink_admits_history:always_admits_history
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
     candidate walk applies via [same_run_retry_allowed] /
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
      ~shrink_admits_history:always_admits_history
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
      ~shrink_admits_history:always_admits_history
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
      ~shrink_admits_history:always_admits_history
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

(* The floor is the last view: once the ordinary halving would reach or
   pass it, the floor is attempted instead, and nothing is attempted below
   it. *)
let test_the_floor_is_the_last_view () =
  let attempted_capacities = ref [] in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~final_shrink_capacity:(fun ~capacity_bytes:_ -> Some 17)
      ~shrink_admits_history:always_admits_history
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
      ~starting_capacity_bytes:524_288
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:(fun ~capacity_bytes -> reserve_bytes < capacity_bytes)
      ~record_success:(fun ~capacity_bytes:_ -> fail "overflow never succeeds here")
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes:_ ->
          incr shrink_count)
      ~attempt:(fun ~capacity_bytes ->
        attempted_capacities := capacity_bytes :: !attempted_capacities;
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
      ~starting_capacity_bytes:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:(fun ~capacity_bytes -> capacity_bytes >= 512)
      ~record_success:(fun ~capacity_bytes:_ -> fail "overflow never succeeds here")
      ~on_shrink_retry:
        (fun ~shrink_attempt:_ ~previous_capacity_bytes:_ ~capacity_bytes:_ -> ())
      ~attempt:(fun ~capacity_bytes ->
        attempted_capacities := capacity_bytes :: !attempted_capacities;
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

(* {1 Keeper_context_overflow_shrink_state} *)

let test_state_defaults_to_max_capacity_when_unseen () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  check int "no memory yet: falls back to the declared cap" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let test_state_remembers_last_success () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~capacity_bytes:131_072;
  check int "next turn starts from the remembered capacity" 131_072
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let test_state_clamps_a_remembered_value_above_the_current_cap () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~capacity_bytes:2_097_152;
  check int "a stale remembered value never exceeds the current declared cap"
    1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

(* The seed is the runtime's declared ceiling, and a caller that passes
   [max_int] instead opts out of every clamp above: a remembered value can
   never be stale, and the first attempt carries the whole history. The
   claude_code lane did exactly that until 2026-08-24, so a model declaring
   max-prompt-bytes=524288 learned its own ceiling from the provider's
   rejection, one full turn at a time. This pins what [max_capacity_bytes]
   means so the next lane that wires it reads the contract here. *)
let test_max_int_capacity_disables_the_clamp () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~capacity_bytes:8_388_608;
  check int "an unbounded cap keeps a value a declared cap would have clamped"
    8_388_608
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:max_int);
  check int "the same memory against a declared cap is clamped to it" 524_288
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:524_288)
;;

let test_state_is_keyed_per_keeper_and_runtime () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~capacity_bytes:131_072;
  check int "a different runtime on the same keeper is unaffected" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-fallback" ~max_capacity_bytes:1_048_576);
  check int "the same runtime id on a different keeper is unaffected" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"beta" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;


(* The memory is a claim that a turn completed at that size. An overflow at
   that size disproves it, and #31684 showed what keeping it costs: the pair
   re-entered at the disproved capacity every turn for the life of the
   process. *)
let test_state_forgets_a_disproved_capacity () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~capacity_bytes:131_072;
  Shrink_state.forget ~keeper_name:"alpha" ~runtime_id:"agent_core-primary";
  check int "the next turn starts from the declared cap again" 1_048_576
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
;;

let test_forget_leaves_other_pairs_intact () =
  Eio_main.run
  @@ fun _env ->
  Shrink_state.For_testing.reset ();
  Shrink_state.record_success
    ~keeper_name:"alpha" ~runtime_id:"agent_core-primary" ~capacity_bytes:131_072;
  Shrink_state.record_success
    ~keeper_name:"beta" ~runtime_id:"agent_core-primary" ~capacity_bytes:262_144;
  Shrink_state.forget ~keeper_name:"alpha" ~runtime_id:"agent_core-primary";
  check int "a different keeper keeps its own memory" 262_144
    (Shrink_state.starting_capacity_bytes
       ~keeper_name:"beta" ~runtime_id:"agent_core-primary" ~max_capacity_bytes:1_048_576)
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
            "max_int capacity disables the clamp"
            `Quick
            test_max_int_capacity_disables_the_clamp
        ; test_case
            "is keyed per (keeper, runtime)"
            `Quick
            test_state_is_keyed_per_keeper_and_runtime
        ; test_case
            "forgets a disproved capacity"
            `Quick
            test_state_forgets_a_disproved_capacity
        ; test_case
            "forget leaves other pairs intact"
            `Quick
            test_forget_leaves_other_pairs_intact
        ] )
    ]
;;
