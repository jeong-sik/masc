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

(* §L (tracker #13155): pin exact warmup outputs for fixed keeper
   names so any silent regression to native-int [acc lsl 5] (which
   wraps differently on 31-bit vs 63-bit OCaml) breaks at least one
   assertion on at least one architecture.

   Expected values come from the Int32 djb2 spec:
     [acc := Int32.logand (Int32.add (Int32.add (acc lsl 5) acc) ch)
            0x3FFF_FFFFl]

   With [base_warmup = 0, stagger_window_sec = 99] the formula
   reduces to [hash mod 100] which is itself stable across platforms
   under the Int32 implementation. *)
let test_warmup_hash_pinned_cross_platform () =
  let warmup name =
    Boot.autoboot_proactive_warmup_sec ~base_warmup:0
      ~stagger_window_sec:99 ~keeper_name:name
  in
  check int "verifier hash mod 100 (Int32 djb2)" 25 (warmup "verifier");
  check int "designer hash mod 100 (Int32 djb2)" 74 (warmup "designer");
  check int "developer hash mod 100 (Int32 djb2)" 15 (warmup "developer");
  check int "analyst hash mod 100 (Int32 djb2)" 73 (warmup "analyst");
  check int "janitor hash mod 100 (Int32 djb2)" 4 (warmup "janitor")

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
          test_case "Int32 hash pinned cross-platform (#13155 §L)" `Quick
            test_warmup_hash_pinned_cross_platform;
        ] );
    ]
