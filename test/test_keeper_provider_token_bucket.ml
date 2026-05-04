(** Unit tests for [Keeper_provider_token_bucket].

    The bucket is the I3 (Rate-respect) primitive in the future
    keeper-liveness scheduler. These tests pin its contract independent
    of any scheduler integration so future PRs can rely on the semantics
    even as call sites evolve. *)

open Masc_mcp

(* Controllable clock: tests advance this directly to make refill behaviour
   deterministic. *)
let clock_ref = ref 0.0
let now () = !clock_ref
let advance dt = clock_ref := !clock_ref +. dt

let reset_clock () = clock_ref := 0.0

(* ------------------------------------------------------------------ *)
(* Pure refill arithmetic                                              *)
(* ------------------------------------------------------------------ *)

let test_refilled_caps_at_capacity () =
  let actual =
    Keeper_provider_token_bucket.refilled
      ~current_tokens:5.0
      ~capacity:10
      ~refill_rate:100.0
      ~elapsed_sec:1.0
  in
  Alcotest.(check (float 0.0001))
    "raw 5+100=105 capped at 10"
    10.0
    actual

let test_refilled_negative_elapsed_no_change () =
  (* Clock skew defence: time moving backward must never inflate tokens. *)
  let actual =
    Keeper_provider_token_bucket.refilled
      ~current_tokens:3.5
      ~capacity:10
      ~refill_rate:1.0
      ~elapsed_sec:(-2.0)
  in
  Alcotest.(check (float 0.0001))
    "negative elapsed leaves tokens unchanged"
    3.5
    actual

let test_refilled_zero_elapsed_no_change () =
  let actual =
    Keeper_provider_token_bucket.refilled
      ~current_tokens:7.0
      ~capacity:10
      ~refill_rate:1.0
      ~elapsed_sec:0.0
  in
  Alcotest.(check (float 0.0001)) "zero elapsed leaves tokens unchanged" 7.0 actual

let test_refilled_partial_under_capacity () =
  let actual =
    Keeper_provider_token_bucket.refilled
      ~current_tokens:2.0
      ~capacity:10
      ~refill_rate:0.5
      ~elapsed_sec:4.0
  in
  Alcotest.(check (float 0.0001)) "2 + 0.5*4 = 4.0" 4.0 actual

(* ------------------------------------------------------------------ *)
(* Constructor invariants                                              *)
(* ------------------------------------------------------------------ *)

let test_create_starts_full () =
  reset_clock ();
  let t =
    Keeper_provider_token_bucket.create
      ~provider:"anthropic"
      ~capacity:5
      ~refill_rate:1.0
      ~now
  in
  Alcotest.(check (float 0.0001))
    "fresh bucket starts at full capacity"
    5.0
    (Keeper_provider_token_bucket.tokens_available t)

let test_create_rejects_zero_capacity () =
  Alcotest.check_raises
    "capacity 0 rejected"
    (Invalid_argument
       "Keeper_provider_token_bucket.create: capacity must be >= 1")
    (fun () ->
      ignore
        (Keeper_provider_token_bucket.create
           ~provider:"x"
           ~capacity:0
           ~refill_rate:1.0
           ~now))

let test_create_rejects_zero_refill () =
  Alcotest.check_raises
    "refill_rate 0 rejected"
    (Invalid_argument
       "Keeper_provider_token_bucket.create: refill_rate must be > 0.0")
    (fun () ->
      ignore
        (Keeper_provider_token_bucket.create
           ~provider:"x"
           ~capacity:1
           ~refill_rate:0.0
           ~now))

(* ------------------------------------------------------------------ *)
(* Acquire semantics                                                   *)
(* ------------------------------------------------------------------ *)

let test_acquire_drains_then_fails () =
  reset_clock ();
  let t =
    Keeper_provider_token_bucket.create
      ~provider:"codex_cli"
      ~capacity:3
      ~refill_rate:0.001 (* effectively no refill within test horizon *)
      ~now
  in
  Alcotest.(check bool) "1st acquire ok" true
    (Keeper_provider_token_bucket.try_acquire t);
  Alcotest.(check bool) "2nd acquire ok" true
    (Keeper_provider_token_bucket.try_acquire t);
  Alcotest.(check bool) "3rd acquire ok" true
    (Keeper_provider_token_bucket.try_acquire t);
  Alcotest.(check bool) "4th acquire fails when drained" false
    (Keeper_provider_token_bucket.try_acquire t)

let test_acquire_recovers_after_refill () =
  reset_clock ();
  let t =
    Keeper_provider_token_bucket.create
      ~provider:"glm"
      ~capacity:1
      ~refill_rate:1.0
      ~now
  in
  Alcotest.(check bool) "drain initial token" true
    (Keeper_provider_token_bucket.try_acquire t);
  Alcotest.(check bool) "empty immediately after" false
    (Keeper_provider_token_bucket.try_acquire t);
  advance 1.5;
  Alcotest.(check bool) "refilled after 1.5s at 1tps (>=1.0 token)" true
    (Keeper_provider_token_bucket.try_acquire t)

let test_rate_respect_invariant () =
  (* I3: dispatched(p, W) <= rate_limit(p) * |W|.
     Run for [horizon] seconds at fine-grained polling, count successful
     acquires, assert <= capacity + rate * horizon. *)
  reset_clock ();
  let capacity = 5 in
  let refill_rate = 2.0 in
  let horizon = 10.0 in
  let step = 0.1 in
  let t =
    Keeper_provider_token_bucket.create
      ~provider:"anthropic"
      ~capacity
      ~refill_rate
      ~now
  in
  let dispatched = ref 0 in
  let elapsed = ref 0.0 in
  while !elapsed < horizon do
    if Keeper_provider_token_bucket.try_acquire t then incr dispatched;
    advance step;
    elapsed := !elapsed +. step
  done;
  let theoretical_max =
    capacity + int_of_float (refill_rate *. horizon)
  in
  let observed = !dispatched in
  Alcotest.(check bool)
    (Printf.sprintf
       "I3: observed dispatches (%d) must not exceed capacity+rate*horizon (%d)"
       observed
       theoretical_max)
    true
    (observed <= theoretical_max)

let test_provider_label_preserved () =
  reset_clock ();
  let t =
    Keeper_provider_token_bucket.create
      ~provider:"my-provider-tag"
      ~capacity:1
      ~refill_rate:1.0
      ~now
  in
  Alcotest.(check string)
    "provider tag round-trips"
    "my-provider-tag"
    (Keeper_provider_token_bucket.provider t)

(* ------------------------------------------------------------------ *)
(* Concurrent acquire (cross-fiber safety)                             *)
(* ------------------------------------------------------------------ *)

let test_concurrent_acquire_no_overdraw () =
  (* I3 still holds when N parallel domains race for the same bucket.
     Without the mutex, lazy refill + decrement could double-count. *)
  reset_clock ();
  let capacity = 100 in
  let t =
    Keeper_provider_token_bucket.create
      ~provider:"shared"
      ~capacity
      ~refill_rate:0.001 (* near-zero refill: only initial 100 tokens available *)
      ~now
  in
  let n_domains = 4 in
  let attempts_per_domain = 200 in
  let success_counts = Array.make n_domains 0 in
  let domains =
    Array.init n_domains (fun i ->
        Domain.spawn (fun () ->
            for _ = 1 to attempts_per_domain do
              if Keeper_provider_token_bucket.try_acquire t then
                success_counts.(i) <- success_counts.(i) + 1
            done))
  in
  Array.iter Domain.join domains;
  let total_success = Array.fold_left (+) 0 success_counts in
  Alcotest.(check bool)
    (Printf.sprintf
       "total successful acquires (%d) must equal capacity (%d) — no overdraw"
       total_success
       capacity)
    true
    (total_success = capacity)

(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run
    "keeper_provider_token_bucket"
    [
      ( "refill_arithmetic"
      , [ Alcotest.test_case "caps at capacity" `Quick
            test_refilled_caps_at_capacity
        ; Alcotest.test_case "negative elapsed unchanged" `Quick
            test_refilled_negative_elapsed_no_change
        ; Alcotest.test_case "zero elapsed unchanged" `Quick
            test_refilled_zero_elapsed_no_change
        ; Alcotest.test_case "partial refill under capacity" `Quick
            test_refilled_partial_under_capacity
        ] )
    ; ( "constructor"
      , [ Alcotest.test_case "starts full" `Quick test_create_starts_full
        ; Alcotest.test_case "rejects zero capacity" `Quick
            test_create_rejects_zero_capacity
        ; Alcotest.test_case "rejects non-positive refill rate" `Quick
            test_create_rejects_zero_refill
        ] )
    ; ( "acquire_semantics"
      , [ Alcotest.test_case "drains then fails" `Quick
            test_acquire_drains_then_fails
        ; Alcotest.test_case "recovers after refill" `Quick
            test_acquire_recovers_after_refill
        ; Alcotest.test_case "I3 rate-respect over 10s window" `Quick
            test_rate_respect_invariant
        ; Alcotest.test_case "provider label preserved" `Quick
            test_provider_label_preserved
        ] )
    ; ( "concurrency"
      , [ Alcotest.test_case "no overdraw under 4-domain race" `Quick
            test_concurrent_acquire_no_overdraw
        ] )
    ]
;;
