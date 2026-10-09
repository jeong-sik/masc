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
       ; kind = Llm_provider.Http_client.Connection_reset
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
      ~on_memory_capacity_refusal:(fun ~refusal:_ -> fail "unauthorized memory reprojection")
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
      ~on_memory_capacity_refusal:(fun ~refusal:_ -> fail "unauthorized memory reprojection")
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

let request_body_refused () =
  Agent_core.Error.Api
    (Agent_core.Retry.InvalidRequest
       { message = "input_too_large"
       ; reason = Agent_core.Retry.Request_body_refused_by_provider { status = 413 }
       })
;;

(* The Codex app-server refuses an oversized turn/start input before any tool
   runs; the typed body refusal walks the same ladder as a window overflow. *)
let test_body_refusal_shrinks_until_success () =
  let attempted_capacities = ref [] in
  let attempt ~capacity =
    attempted_capacities := capacity :: !attempted_capacities;
    if capacity <= 256 then Ok "done" else Error (request_body_refused ())
  in
  let result =
    Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024
      ~same_run_retry_authorized:always_authorized
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ -> ())
      ~attempt
      ()
  in
  check bool "eventually succeeds" true (result = Ok "done");
  check (list int) "capacity halves on each body refusal" [ 1024; 512; 256 ]
    (List.rev !attempted_capacities)
;;

(* After a tool effect the retry authority is closed: a body refusal must not
   replay the turn on a smaller view. *)
let test_body_refusal_after_effect_never_shrinks () =
  let attempts = ref 0 in
  let attempt ~capacity:_ =
    incr attempts;
    Error (request_body_refused ())
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
  check bool "the body refusal propagates unchanged" true
    (match result with
     | Error
         (Agent_core.Error.Api
           (Agent_core.Retry.InvalidRequest
             { reason = Agent_core.Retry.Request_body_refused_by_provider _; _ })) ->
       true
     | _ -> false)
;;

let test_memory_reprojection_retries_without_shrinking_history () =
  let capacities = ref [] in
  let reset = ref false in
  let refusal = context_overflow () in
  let result = Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024 ~same_run_retry_authorized:always_authorized
      ~on_memory_capacity_refusal:(fun ~refusal:observed ->
        check bool "reprojection receives the exact typed refusal" true (observed = refusal);
        Ok Masc.Keeper_memory_delivery_reprojection.Reprojected)
      ~on_memory_retry:(fun () -> reset := true)
      ~shrink_capacity:(fun ~capacity ~default_capacity:_ -> capacity)
      ~shrink_admits_history:(fun ~capacity:_ -> false)
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ ->
        fail "memory-only retry must not claim a history shrink")
      ~attempt:(fun ~capacity ->
        capacities := capacity :: !capacities;
        if !reset then Ok "reprojected request" else Error refusal) () in
  check bool "recovery reset precedes the retry" true (result = Ok "reprojected request");
  check (list int) "memory-only retry preserves history capacity" [1024;1024]
    (List.rev !capacities)
;;

let test_unchanged_memory_needs_a_real_history_target () =
  List.iter (fun next_capacity ->
    let capacities = ref [] in
    let callbacks = ref 0 in
    let refusal = context_overflow () in
    let result = Try_provider.context_overflow_shrink_sequence
        ~starting_capacity:1024 ~same_run_retry_authorized:always_authorized
        ~on_memory_capacity_refusal:(fun ~refusal:_ ->
          incr callbacks;
          Ok Masc.Keeper_memory_delivery_reprojection.Unchanged)
        ~on_memory_retry:(fun () -> fail "unchanged memory cannot authorize a retry")
        ~shrink_capacity:(fun ~capacity ~default_capacity:_ ->
          match next_capacity with None -> capacity | Some next -> next)
        ~shrink_admits_history:always_admits_history
        ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ -> ())
        ~attempt:(fun ~capacity ->
          capacities := capacity :: !capacities;
          if capacity < 1024 then Ok "history reduced" else Error refusal) () in
    check int "memory selection considered once for the refusal" 1 !callbacks;
    match next_capacity with
    | None ->
      check bool "unchanged memory preserves the original refusal" true (result = Error refusal);
      check (list int) "no invented half-capacity request" [1024] (List.rev !capacities)
    | Some target ->
      check bool "existing history shrink remains available" true (result = Ok "history reduced");
      check (list int) "only the measured history target is retried" [1024;target]
        (List.rev !capacities)) [None;Some 512]
;;

let test_memory_receipt_failure_stops_retry_with_original_refusal () =
  let attempts = ref 0 in
  let refusal = context_overflow () in
  let result = Try_provider.context_overflow_shrink_sequence
      ~starting_capacity:1024 ~same_run_retry_authorized:always_authorized
      ~on_memory_capacity_refusal:(fun ~refusal:_ -> Error "receipt persistence failed")
      ~on_memory_retry:(fun () -> fail "unpersisted selection cannot reset recovery")
      ~shrink_admits_history:always_admits_history
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ ->
        fail "receipt failure cannot fall through to history retry")
      ~attempt:(fun ~capacity:_ -> incr attempts; Error refusal) () in
  check bool "provider refusal remains the reported error" true (result = Error refusal);
  check int "no request follows failed receipt persistence" 1 !attempts
;;

let () =
  run
    "keeper_context_overflow_shrink"
    [ ( "context_overflow_shrink_sequence"
      , [ test_case
            "a body refusal shrinks until success"
            `Quick
            test_body_refusal_shrinks_until_success
        ; test_case
            "a body refusal after an effect never shrinks"
            `Quick
            test_body_refusal_after_effect_never_shrinks
        ; test_case "memory reprojection retries at unchanged history capacity" `Quick
            test_memory_reprojection_retries_without_shrinking_history
        ; test_case "unchanged memory requires a real history target" `Quick
            test_unchanged_memory_needs_a_real_history_target
        ; test_case "failed memory receipt preserves the provider refusal" `Quick
            test_memory_receipt_failure_stops_retry_with_original_refusal
        ; test_case
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
