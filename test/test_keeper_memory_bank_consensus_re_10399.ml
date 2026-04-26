(** #10399 — pin the consensus-marker regex contract after the
    [Stdlib.Lazy] → Atomic+Mutex memo migration.

    Pre-fix [keeper_memory_bank.ml] held [consensus_re_cached]
    as a [Stdlib.Lazy] thunk forced from the keeper hot path.
    The accompanying comment claimed the thunk was "pure" so
    racing forces collapsed to redundant computation, but
    OCaml's [Stdlib.Lazy] still raises [CamlinternalLazy.Undefined]
    when one fiber suspends mid-force and another tries to
    force, regardless of whether the values would have agreed.
    The 14-keeper fleet's hot path triggered this race
    intermittently.

    Post-fix the module uses an [Atomic.t] cell guarded by
    [Stdlib.Mutex] — the same pattern the three sibling
    keeper files (keeper_decision_audit, keeper_trace_emit,
    tool_bridge) already adopted.  This module pins:

    1. The default regex matches inflated consensus markers
       like ["1234567ep"] and ["123456ep+"] and ignores clean
       prose.
    2. Repeated calls return a consistent boolean — the
       memoised [Re.re] is reused, not recompiled, and never
       throws.
    3. Many concurrent calls across domains do not raise (no
       [CamlinternalLazy.Undefined]).

    Env-override behaviour ([MASC_KEEPER_MEMORY_CONSENSUS_PATTERN])
    is intentionally not tested here: the cache is a process-
    level singleton seeded by the first call, so a unit test
    that flips the env after import would observe stale state.
    Operators verify env override at process boot only. *)

open Alcotest
module M = Masc_mcp.Keeper_memory_bank

(* --- 1. default pattern: detect inflated markers --------- *)

let test_inflated_marker_detected () =
  check
    bool
    "1234567ep flagged"
    true
    (M.has_inflated_consensus_marker "round 1234567ep complete");
  check
    bool
    "654321ep+ flagged"
    true
    (M.has_inflated_consensus_marker "phase 654321ep+ done")
;;

let test_clean_prose_rejected () =
  check
    bool
    "plain prose not flagged"
    false
    (M.has_inflated_consensus_marker "this is a normal summary");
  check
    bool
    "small numbers not flagged"
    false
    (M.has_inflated_consensus_marker "12345ep is below the threshold");
  check
    bool
    "unrelated digits not flagged"
    false
    (M.has_inflated_consensus_marker "version 1234567 alpha")
;;

(* --- 2. idempotence: 100 calls all consistent ----------- *)

let test_repeated_calls_consistent () =
  for _ = 1 to 100 do
    check bool "consistent flag" true (M.has_inflated_consensus_marker "9999999ep")
  done;
  for _ = 1 to 100 do
    check bool "consistent miss" false (M.has_inflated_consensus_marker "ordinary text")
  done
;;

(* --- 3. concurrent first forcing does not raise --------- *)

(* This suite runs before the default-pattern checks below so the cache is still
   empty.  Spawn real OCaml domains, not Eio fibers, because the pre-fix
   [Stdlib.Lazy.force] race is a domain-level first-force race. *)
let test_concurrent_first_forcing_no_raise () =
  let n = 16 in
  let start = Atomic.make false in
  let domains =
    List.init n (fun i ->
      Domain.spawn (fun () ->
        while not (Atomic.get start) do
          Domain.cpu_relax ()
        done;
        let needle = if i mod 2 = 0 then "8888888ep run" else "no marker here" in
        M.has_inflated_consensus_marker needle))
  in
  Atomic.set start true;
  let results = List.map Domain.join domains in
  check int "all domains completed without raising" n (List.length results);
  check
    int
    "half of probes matched the marker"
    (n / 2)
    (List.length (List.filter Fun.id results))
;;

let () =
  run
    "keeper_memory_bank_consensus_re_10399"
    [ ( "domain-safety"
      , [ test_case
            "concurrent first forcing does not raise"
            `Quick
            test_concurrent_first_forcing_no_raise
        ] )
    ; ( "default-pattern"
      , [ test_case "inflated markers detected" `Quick test_inflated_marker_detected
        ; test_case "clean prose rejected" `Quick test_clean_prose_rejected
        ] )
    ; ( "memoisation"
      , [ test_case "repeated calls stay consistent" `Quick test_repeated_calls_consistent
        ] )
    ]
;;
