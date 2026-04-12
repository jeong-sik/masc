(** Regression test for [Keeper_keepalive.should_log_manual_reconcile_skip].

    Background: on 2026-04-12 /loop observed 266 copies of the
    [keepalive turn skipped for <keeper>: manual reconcile pending]
    INFO log in /tmp/masc-min-p-restart.log over a 14-minute window —
    6 stuck keepers × ~30s scheduled tick rate = ~42 lines/min of
    drain-only noise. Operators cannot auto-clear the blocker (by
    design — [Keeper_manual_reconcile.clear] is the only escape and
    it's an MCP tool), but they also cannot diagnose anything else
    while the skip log floods every terminal tail.

    Fix: the log is rate-limited per keeper to [skip_log_throttle_sec]
    (60s). The first call per window emits INFO; subsequent calls
    within the window demote to DEBUG (silent unless operator opted
    in). This test pins the window semantics so a refactor cannot
    regress back to unbounded log rate. *)

module KK = Masc_mcp.Keeper_keepalive

(** Reset the module-global throttle table before every test so
    test-order dependencies cannot leak state between cases. *)
let with_fresh_throttle test_body () =
  KK.reset_skip_log_throttle ();
  test_body ()

let test_first_call_logs () =
  let name = "keeper_alpha" in
  let now = 1_000_000.0 in
  Alcotest.(check bool) "first call emits INFO" true
    (KK.should_log_manual_reconcile_skip ~now name)

let test_second_call_within_window_throttled () =
  let name = "keeper_beta" in
  let t0 = 2_000_000.0 in
  (* Prime the window. *)
  let _ = KK.should_log_manual_reconcile_skip ~now:t0 name in
  (* 30s later — inside the 60s window, must be throttled. *)
  Alcotest.(check bool) "30s in-window call throttled" false
    (KK.should_log_manual_reconcile_skip ~now:(t0 +. 30.0) name)

let test_call_after_window_logs_again () =
  let name = "keeper_gamma" in
  let t0 = 3_000_000.0 in
  let _ = KK.should_log_manual_reconcile_skip ~now:t0 name in
  (* 61s later — past the 60s window, must re-emit INFO. *)
  Alcotest.(check bool) "61s post-window call re-emits" true
    (KK.should_log_manual_reconcile_skip ~now:(t0 +. 61.0) name)

let test_per_keeper_isolation () =
  let name_a = "keeper_delta_a" in
  let name_b = "keeper_delta_b" in
  let t0 = 4_000_000.0 in
  let _ = KK.should_log_manual_reconcile_skip ~now:t0 name_a in
  (* Keeper B's first call — must NOT be throttled by A's window. *)
  Alcotest.(check bool) "per-keeper window isolation" true
    (KK.should_log_manual_reconcile_skip ~now:t0 name_b)

let test_repeated_throttle_within_window () =
  let name = "keeper_epsilon" in
  let t0 = 5_000_000.0 in
  let _ = KK.should_log_manual_reconcile_skip ~now:t0 name in
  (* Five calls in quick succession inside the window. *)
  let throttled =
    List.init 5 (fun i ->
      KK.should_log_manual_reconcile_skip ~now:(t0 +. float_of_int i) name)
  in
  Alcotest.(check (list bool))
    "all in-window repeats throttled"
    [ false; false; false; false; false ] throttled

let test_reset_clears_all_entries () =
  (* Populate several keepers, reset, confirm every entry went back to
     "never logged" state. Pins [reset_skip_log_throttle] semantics. *)
  let now = 6_000_000.0 in
  let names = [ "reset_a"; "reset_b"; "reset_c" ] in
  List.iter
    (fun name ->
      let _ = KK.should_log_manual_reconcile_skip ~now name in
      ())
    names;
  KK.reset_skip_log_throttle ();
  let re_logged =
    List.map (fun name -> KK.should_log_manual_reconcile_skip ~now name) names
  in
  Alcotest.(check (list bool))
    "every entry re-emits after reset"
    [ true; true; true ] re_logged

let () =
  Alcotest.run "Keeper_keepalive_skip_log_throttle"
    [
      ( "should_log_manual_reconcile_skip",
        [
          Alcotest.test_case "first call logs" `Quick
            (with_fresh_throttle test_first_call_logs);
          Alcotest.test_case "second call in window throttled" `Quick
            (with_fresh_throttle test_second_call_within_window_throttled);
          Alcotest.test_case "post-window re-emits" `Quick
            (with_fresh_throttle test_call_after_window_logs_again);
          Alcotest.test_case "per-keeper isolation" `Quick
            (with_fresh_throttle test_per_keeper_isolation);
          Alcotest.test_case "repeated throttle in window" `Quick
            (with_fresh_throttle test_repeated_throttle_within_window);
          Alcotest.test_case "reset clears entries" `Quick
            (with_fresh_throttle test_reset_clears_all_entries);
        ] );
    ]
