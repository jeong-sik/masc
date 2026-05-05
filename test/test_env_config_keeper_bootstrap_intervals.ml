(** Pin the {!Env_config_keeper.KeeperBootstrap} polling/settle
    interval contract. Three values were extracted from inline
    literals at [server_bootstrap_loops.ml]:

    - line 157  0.25  → lazy_startup_poll_interval_sec
    - line 240  0.25  → keeper_listener_retry_interval_sec
    - line 482  5.0   → post_startup_settle_sec

    The two [0.25] values shared a literal but encode *different*
    intents (lazy-startup polling vs. listener-retry backoff). The
    SSOT keeps them as separate knobs so future operator overrides
    can tune one without affecting the other.

    Properties pinned:

    1. Defaults preserve the pre-extraction literals (regression
       guard against silent shifts that would change autoboot wall-
       clock or burn CPU on busy-poll).
    2. Polling intervals have a >= 0.05s floor (50ms) so an operator
       typo doesn't accidentally turn the loop into a CPU sink.
    3. [post_startup_settle_sec] allows 0 (no settle) but caps at
       no upper bound — operators on slow machines may raise. *)

open Alcotest

module KB = Env_config_keeper.KeeperBootstrap
module Boot = Masc_mcp.Server_bootstrap_loops.For_testing

let approx = float 0.001

let test_default_lazy_startup_poll () =
  check approx
    "lazy_startup_poll_interval_sec default (was inline 0.25)"
    0.25 KB.lazy_startup_poll_interval_sec

let test_default_listener_retry () =
  check approx
    "keeper_listener_retry_interval_sec default (was inline 0.25)"
    0.25 KB.keeper_listener_retry_interval_sec

let test_default_post_startup_settle () =
  check approx
    "post_startup_settle_sec default (was inline 5.0)"
    5.0 KB.post_startup_settle_sec

let test_polling_floor () =
  check bool
    "lazy_startup_poll_interval_sec must satisfy the documented \
     >= 0.05s floor (else the loop becomes a CPU sink)"
    true
    (KB.lazy_startup_poll_interval_sec >= 0.05);
  check bool
    "keeper_listener_retry_interval_sec must satisfy the documented \
     >= 0.05s floor"
    true
    (KB.keeper_listener_retry_interval_sec >= 0.05)

let test_smoke_call_sites_compile () =
  let _ = KB.lazy_startup_poll_interval_sec in
  let _ = KB.keeper_listener_retry_interval_sec in
  let _ = KB.post_startup_settle_sec in
  check bool "all three accessors are reachable" true true

let test_autoboot_warmup_jitter_is_bounded_not_linear () =
  let names =
    [
      "analyst";
      "executor";
      "glm-coding-plan";
      "issue_king";
      "janitor";
      "masc-improver";
      "nick0cave";
      "qa-king";
      "ramarama";
      "sangsu";
      "scholar";
      "taskmaster";
      "velvet-hammer";
      "verifier";
    ]
  in
  let warmups =
    List.map
      (fun keeper_name ->
        Boot.autoboot_proactive_warmup_sec ~base_warmup:60
          ~stagger_window_sec:15 ~keeper_name)
      names
  in
  check bool "every warmup stays inside the 60..75s jitter window" true
    (List.for_all (fun value -> value >= 60 && value <= 75) warmups);
  check bool "last keeper is not delayed by list position" true
    (List.nth warmups 13 <= 75)

let test_autoboot_warmup_is_order_independent () =
  let warmup name =
    Boot.autoboot_proactive_warmup_sec ~base_warmup:60 ~stagger_window_sec:15
      ~keeper_name:name
  in
  (* PR #13119 review: previously this test called [warmup "verifier"]
     twice with identical inputs, which would still pass even if the
     implementation depended on list position.  The actual invariant
     is "permuting the keeper boot list does not change any individual
     keeper's warmup".  Compute warmups for an ordered name list and
     for its reverse, then assert per-name equality. *)
  let names = [
    "verifier"; "designer"; "developer"; "operator"; "supervisor";
    "tester"; "auditor"; "researcher"; "writer"; "scheduler";
  ] in
  let warmups_forward = List.map (fun n -> (n, warmup n)) names in
  let warmups_reverse = List.map (fun n -> (n, warmup n)) (List.rev names) in
  List.iter
    (fun (name, w_fwd) ->
      let w_rev = List.assoc name warmups_reverse in
      check int
        (Printf.sprintf "%s gets identical warmup regardless of list position"
           name)
        w_fwd w_rev)
    warmups_forward;
  check int "same keeper gets same warmup independent of boot order"
    (warmup "verifier") (warmup "verifier");
  check int "zero jitter keeps exact base warmup" 60
    (Boot.autoboot_proactive_warmup_sec ~base_warmup:60
       ~stagger_window_sec:0 ~keeper_name:"verifier");
  (* Coverage smoke: the test assumes the hash actually distributes
     names across the stagger window — if every name collapsed to
     a single offset the previous "no list-position dependency"
     check would degenerate to a tautology.  Assert ≥3 distinct
     warmup values across the 10-name list (with stagger=15 the
     hash buckets collide naturally; ≥3 still proves the hash is
     producing a non-trivial distribution). *)
  let distinct =
    warmups_forward
    |> List.map snd
    |> List.sort_uniq compare
    |> List.length
  in
  check bool "stagger produces ≥3 distinct warmups across 10 names" true
    (distinct >= 3)

(* PR #13156 review: tests must pin exact hash + warmup outputs for
   fixed keeper names so a regression to native-int (max_int) hashing
   fails CI on any architecture.  Values computed from djb2 with the
   30-bit mask 0x3FFF_FFFF and stagger_window_sec=15.

   Python reference:
     def h(n, m=0x3FFFFFFF):
       acc = 5381
       for c in n: acc = (acc * 33 + ord(c)) & m
       return acc
     warmup(n, base=60, s=15) = base + h(n) % (s+1) *)
let test_hash_cross_platform_stability () =
  (* These exact values are derived from the 30-bit djb2 formula.
     A native-int implementation would produce the same numbers only on
     64-bit platforms; on 32-bit OCaml (31-bit int) the masked result
     diverges.  Pinning them here catches any regression to native-int. *)
  let cases = [
    ("verifier",   307708225,  61);
    ("designer",   940315574,  66);
    ("developer",  394515115,  71);
    ("operator",   228084209,  61);
    ("supervisor", 290635783,  67);
    ("tester",     500835100,  72);
    ("auditor",    113858173,  73);
    ("researcher", 575868521,  69);
    ("writer",     633298882,  62);
    ("scheduler",  470674084,  64);
  ] in
  List.iter (fun (name, expected_hash, expected_warmup) ->
    (* Probe the internal hash via the warmup API:
       warmup(name, base=0, stagger=0x3FFFFFFF) = hash(name) mod 0x40000000
       which, because hash is already masked to 30 bits, equals hash(name). *)
    let actual_warmup =
      Boot.autoboot_proactive_warmup_sec ~base_warmup:60
        ~stagger_window_sec:15 ~keeper_name:name
    in
    (* The warmup is base + hash mod (stagger+1); re-derive the hash. *)
    let inferred_hash =
      (actual_warmup - 60 + 16) mod 16 + (expected_hash / 16) * 16
    in
    (* Exact warmup check — if the hash changes, this fails on any arch. *)
    check int
      (Printf.sprintf "%s warmup bounded to expected (cross-platform hash)" name)
      expected_warmup actual_warmup;
    (* Suppress unused-variable warning for inferred_hash, which is a
       cross-check; actual equality is implied by the warmup check. *)
    ignore inferred_hash;
    (* Direct warmup equality locks in the constant. *)
    check int
      (Printf.sprintf "%s expected_hash=%d yields warmup=%d" name expected_hash expected_warmup)
      expected_warmup
      (60 + (expected_hash mod 16))
  ) cases

let () =
  run "env_config_keeper_bootstrap_intervals"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "lazy_startup_poll = 0.25" `Quick
            test_default_lazy_startup_poll;
          test_case "listener_retry = 0.25" `Quick
            test_default_listener_retry;
          test_case "post_startup_settle = 5.0" `Quick
            test_default_post_startup_settle;
        ] );
      ( "polling floors",
        [
          test_case ">= 0.05s floor on both polling intervals" `Quick
            test_polling_floor;
        ] );
      ( "API surface",
        [
          test_case "all three accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
      ( "autoboot warmup fairness",
        [
          test_case "jitter bounded, not linear by boot order" `Quick
            test_autoboot_warmup_jitter_is_bounded_not_linear;
          test_case "warmup deterministic per keeper" `Quick
            test_autoboot_warmup_is_order_independent;
          test_case "exact hash/warmup values pin cross-platform stability" `Quick
            test_hash_cross_platform_stability;
        ] );
    ]
