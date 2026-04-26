(** #9645 root cause (companion to PR #10056 retry-count bump and
    PR #10201 acquire-failed counter): the lock backoff sequence was
    DETERMINISTIC.  Every retry slept exactly [delay], with [delay]
    doubling up to a cap.  When 17 actors (16 keepers + orchestrator
    GC) collided on [tasks:.backlog] they all retried at the same
    instants, so 50 attempts decayed into 50 contention spikes
    instead of 50 independent attempts.

    Marc Brooker, "Exponential Backoff And Jitter", AWS Architecture
    Blog (2015): full jitter (sleep ∈ [0, delay], delay still doubles)
    is the standard fix for retry storms.  Production systems
    (envoy, AWS SDK, kubernetes client-go) all ship this.

    These tests pin the contract that [backoff_with_jitter] enforces
    the [0, delay] interval and produces variance.  Behaviour in the
    main acquire loop is left to the existing #9645 metric — once
    contention drops we expect the [acquire-failed] counter to fall. *)

module C = Coord_utils_ops

(* 1. Range invariants ------------------------------------------- *)

let test_jitter_within_zero_and_delay () =
  let delay = 0.5 in
  for _ = 1 to 1_000 do
    let v = C.backoff_with_jitter delay in
    Alcotest.(check bool) (Printf.sprintf "0.0 <= %f" v) true (v >= 0.0);
    Alcotest.(check bool) (Printf.sprintf "%f < %f" v delay) true (v < delay)
  done
;;

let test_zero_delay_returns_zero () =
  Alcotest.(check (float 0.0)) "delay=0 stays 0" 0.0 (C.backoff_with_jitter 0.0)
;;

let test_negative_delay_returned_unchanged () =
  (* Defensive: caller never passes negative, but if it did the
     function must not call into [Random.State.float] which would
     raise [Invalid_argument]. *)
  Alcotest.(check (float 0.0))
    "negative delay echoed"
    (-1.0)
    (C.backoff_with_jitter (-1.0))
;;

(* 2. Variance: jitter actually desynchronises -------------------- *)

let test_produces_variance_at_fixed_delay () =
  (* Without jitter every call would return [delay] — zero variance.
     With full jitter the mean of 1000 samples on [0, 0.5] should be
     close to 0.25.  We allow generous slack so the test is not
     flaky on any RNG seed. *)
  let n = 1_000 in
  let delay = 0.5 in
  let sum = ref 0.0 in
  let unique = Hashtbl.create n in
  for _ = 1 to n do
    let v = C.backoff_with_jitter delay in
    sum := !sum +. v;
    Hashtbl.replace unique v ()
  done;
  let mean = !sum /. float_of_int n in
  Alcotest.(check bool)
    (Printf.sprintf "mean %f near 0.25 (jitter active)" mean)
    true
    (mean > 0.15 && mean < 0.35);
  (* Sanity check: at least 100 distinct floats out of 1000 samples
     proves the distribution is not collapsed to a single value
     (which would happen if jitter were a no-op). *)
  Alcotest.(check bool)
    (Printf.sprintf "uniques %d > 100" (Hashtbl.length unique))
    true
    (Hashtbl.length unique > 100)
;;

(* 3. Different domains use different RNG state ------------------- *)

let test_per_domain_rng_independent () =
  (* Each Domain.spawn gets its own [Random.State] via DLS.  Two
     domains drawing 50 samples each must produce two distinct
     sequences (extremely high probability under independent
     [make_self_init] seeds; flake budget << 1e-50). *)
  let collect () =
    let buf = Buffer.create 256 in
    for _ = 1 to 50 do
      Buffer.add_string buf (Printf.sprintf "%.6f," (C.backoff_with_jitter 1.0))
    done;
    Buffer.contents buf
  in
  let d1 = Domain.spawn collect in
  let d2 = Domain.spawn collect in
  let s1 = Domain.join d1 in
  let s2 = Domain.join d2 in
  Alcotest.(check bool) "two domains produce different sequences" true (s1 <> s2)
;;

let () =
  Alcotest.run
    "distributed_lock_backoff_jitter_9645"
    [ ( "range"
      , [ Alcotest.test_case
            "0 <= jitter < delay"
            `Quick
            test_jitter_within_zero_and_delay
        ; Alcotest.test_case "zero delay echoes zero" `Quick test_zero_delay_returns_zero
        ; Alcotest.test_case
            "negative delay echoed"
            `Quick
            test_negative_delay_returned_unchanged
        ] )
    ; ( "variance"
      , [ Alcotest.test_case
            "mean near delay/2 + many uniques"
            `Quick
            test_produces_variance_at_fixed_delay
        ] )
    ; ( "per-domain"
      , [ Alcotest.test_case
            "domains have independent state"
            `Quick
            test_per_domain_rng_independent
        ] )
    ]
;;
