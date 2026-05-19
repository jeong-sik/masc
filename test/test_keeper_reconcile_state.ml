(** Invariants for [Keeper_reconcile_state] (TOML reconcile back-off).

    Targets the reconcile state machine in isolation; the call site in
    [keeper_runtime.ml] is covered indirectly via build-time exhaustive
    match on [record_outcome]. *)

module R = Masc_mcp.Keeper_reconcile_state

let setup_test () = R.reset_all_for_test ()

(* Sample error strings that mirror the production message from the
   2026-05-18 system_log slice (P6 config drift). *)
let drift_error =
  "cascade_name 'tier-group.ollama_cloud_stable' is system-only \
   (keeper_assignable=false); keepers must reference an assignable cascade"
;;

let other_error =
  "cascade_name 'tier-group.glm_strict' is system-only (keeper_assignable=false); \
   keepers must reference an assignable cascade"
;;

(* ===== First / Repeated / Threshold ============================== *)

let test_first_call_returns_first () =
  setup_test ();
  let outcome =
    R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0
  in
  Alcotest.(check bool)
    "first failure returns `First"
    true
    (outcome = `First);
  match R.peek_for_test ~keeper:"alpha" with
  | None -> Alcotest.fail "entry should exist after first failure"
  | Some (count, disabled, _digest) ->
      Alcotest.(check int) "counter is 1" 1 count;
      Alcotest.(check bool) "not disabled" false disabled
;;

let test_second_call_returns_repeated () =
  setup_test ();
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let outcome =
    R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0
  in
  Alcotest.(check bool)
    "second failure returns `Repeated"
    true
    (outcome = `Repeated)
;;

let test_threshold_disable_at_default () =
  setup_test ();
  (* default_disable_threshold = 10. The 10th call crosses the threshold;
     attempts 1..9 are `First then `Repeated x8. *)
  let outcomes =
    List.init R.default_disable_threshold (fun _ ->
      R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0)
  in
  let last = List.nth outcomes (R.default_disable_threshold - 1) in
  Alcotest.(check bool)
    "10th failure returns `Threshold_disable"
    true
    (last = `Threshold_disable);
  Alcotest.(check bool)
    "keeper is disabled after threshold"
    true
    (R.is_disabled ~keeper:"alpha");
  (* After crossing, subsequent failures stay disabled and report
     `Repeated (not another threshold-cross). Idempotent. *)
  let after = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  Alcotest.(check bool)
    "post-threshold call returns `Repeated"
    true
    (after = `Repeated);
  Alcotest.(check bool)
    "keeper stays disabled"
    true
    (R.is_disabled ~keeper:"alpha")
;;

(* ===== Fingerprint isolation between errors ====================== *)

let test_different_error_resets_to_first () =
  setup_test ();
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let outcome =
    R.record_failure ~keeper:"alpha" ~error:other_error ~toml_mtime:1.0
  in
  Alcotest.(check bool)
    "different error string resets counter and returns `First"
    true
    (outcome = `First);
  match R.peek_for_test ~keeper:"alpha" with
  | None -> Alcotest.fail "entry should still exist"
  | Some (count, disabled, _digest) ->
      Alcotest.(check int) "counter reset to 1" 1 count;
      Alcotest.(check bool) "not disabled after reset" false disabled
;;

(* ===== mtime change clears state ================================ *)

let test_reset_on_mtime_change () =
  setup_test ();
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let reset = R.reset_on_mtime_change ~keeper:"alpha" ~new_mtime:2.0 in
  Alcotest.(check bool) "reset fires on mtime change" true reset;
  Alcotest.(check (option (triple int bool string)))
    "entry is cleared after reset"
    None
    (R.peek_for_test ~keeper:"alpha");
  let outcome =
    R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:2.0
  in
  Alcotest.(check bool)
    "next failure after reset is `First again"
    true
    (outcome = `First)
;;

let test_reset_noop_when_mtime_unchanged () =
  setup_test ();
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let reset = R.reset_on_mtime_change ~keeper:"alpha" ~new_mtime:1.0 in
  Alcotest.(check bool) "no reset when mtime unchanged" false reset;
  match R.peek_for_test ~keeper:"alpha" with
  | None -> Alcotest.fail "entry should still exist"
  | Some (count, _disabled, _digest) ->
      Alcotest.(check int) "counter unchanged" 1 count
;;

let test_reset_noop_when_no_entry () =
  setup_test ();
  let reset = R.reset_on_mtime_change ~keeper:"ghost" ~new_mtime:1.0 in
  Alcotest.(check bool) "no reset when no entry exists" false reset
;;

let test_disabled_keeper_resets_on_mtime () =
  setup_test ();
  for _ = 1 to R.default_disable_threshold do
    let (_ : R.record_outcome) =
      R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0
    in
    ()
  done;
  Alcotest.(check bool)
    "keeper disabled at threshold"
    true
    (R.is_disabled ~keeper:"alpha");
  let reset = R.reset_on_mtime_change ~keeper:"alpha" ~new_mtime:2.0 in
  Alcotest.(check bool) "mtime change clears disabled state" true reset;
  Alcotest.(check bool)
    "keeper no longer disabled"
    false
    (R.is_disabled ~keeper:"alpha")
;;

(* ===== Per-keeper isolation ===================================== *)

let test_keeper_isolation () =
  setup_test ();
  for _ = 1 to R.default_disable_threshold do
    let (_ : R.record_outcome) =
      R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0
    in
    ()
  done;
  Alcotest.(check bool)
    "alpha disabled"
    true
    (R.is_disabled ~keeper:"alpha");
  Alcotest.(check bool)
    "beta untouched"
    false
    (R.is_disabled ~keeper:"beta");
  let outcome =
    R.record_failure ~keeper:"beta" ~error:drift_error ~toml_mtime:1.0
  in
  Alcotest.(check bool)
    "beta first failure independent of alpha state"
    true
    (outcome = `First)
;;

(* ===== Success clears state ===================================== *)

let test_record_success_clears_state () =
  setup_test ();
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  let _ = R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0 in
  R.record_success ~keeper:"alpha";
  Alcotest.(check (option (triple int bool string)))
    "state cleared by record_success"
    None
    (R.peek_for_test ~keeper:"alpha");
  let outcome =
    R.record_failure ~keeper:"alpha" ~error:drift_error ~toml_mtime:1.0
  in
  Alcotest.(check bool)
    "next failure is `First"
    true
    (outcome = `First)
;;

(* ===== Digest stability against whitespace drift ================ *)

let test_digest_stable_under_whitespace_collapse () =
  setup_test ();
  let e1 =
    "cascade_name 'tier-group.foo'  is   system-only  \
     (keeper_assignable=false)"
  in
  let e2 = "cascade_name 'tier-group.foo' is system-only (keeper_assignable=false)" in
  let _ = R.record_failure ~keeper:"alpha" ~error:e1 ~toml_mtime:1.0 in
  let outcome = R.record_failure ~keeper:"alpha" ~error:e2 ~toml_mtime:1.0 in
  Alcotest.(check bool)
    "whitespace-only differences treated as same fingerprint"
    true
    (outcome = `Repeated)
;;

(* ===== Suite ==================================================== *)

let () =
  Alcotest.run
    "keeper_reconcile_state"
    [ ( "classification"
      , [ Alcotest.test_case "first call -> `First" `Quick test_first_call_returns_first
        ; Alcotest.test_case
            "second call -> `Repeated"
            `Quick
            test_second_call_returns_repeated
        ; Alcotest.test_case
            "10th call -> `Threshold_disable, then idempotent"
            `Quick
            test_threshold_disable_at_default
        ; Alcotest.test_case
            "different error resets to `First"
            `Quick
            test_different_error_resets_to_first
        ] )
    ; ( "mtime reset"
      , [ Alcotest.test_case
            "mtime change clears state"
            `Quick
            test_reset_on_mtime_change
        ; Alcotest.test_case
            "no reset when mtime unchanged"
            `Quick
            test_reset_noop_when_mtime_unchanged
        ; Alcotest.test_case
            "no reset when no entry exists"
            `Quick
            test_reset_noop_when_no_entry
        ; Alcotest.test_case
            "disabled keeper re-enabled by mtime change"
            `Quick
            test_disabled_keeper_resets_on_mtime
        ] )
    ; ( "per-keeper isolation"
      , [ Alcotest.test_case
            "alpha disabled does not affect beta"
            `Quick
            test_keeper_isolation
        ] )
    ; ( "success path"
      , [ Alcotest.test_case
            "record_success clears state"
            `Quick
            test_record_success_clears_state
        ] )
    ; ( "digest stability"
      , [ Alcotest.test_case
            "whitespace collapse keeps fingerprint stable"
            `Quick
            test_digest_stable_under_whitespace_collapse
        ] )
    ]
;;
