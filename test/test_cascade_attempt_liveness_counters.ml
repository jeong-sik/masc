(** Tests for the cascade attempt-liveness Prometheus counters
    (RFC-0022 PR-2 §3).

    Pins the canonical metric names so a Grafana rule referring to
    [masc_cascade_attempt_liveness_kill_total] /
    [masc_cascade_attempt_liveness_observed_total] cannot silently
    break on a rename. Also exercises the auto-registration path
    (inc_counter creates the series on first call) so that a future
    refactor moving counter registration to an explicit init block
    will not silently regress these series. *)

module P = Masc_mcp.Prometheus

let test_kill_metric_name_stable () =
  Alcotest.(check string)
    "kill counter canonical name"
    "masc_cascade_attempt_liveness_kill_total"
    P.metric_cascade_attempt_liveness_kill

let test_observed_metric_name_stable () =
  Alcotest.(check string)
    "observed counter canonical name"
    "masc_cascade_attempt_liveness_observed_total"
    P.metric_cascade_attempt_liveness_observed

let test_kill_counter_increments () =
  let labels =
    [ ("mode", "observe");
      ("kind", "no_first_token");
      ("cascade", "test_cascade");
      ("provider", "test_provider") ]
  in
  let before =
    P.metric_value_or_zero P.metric_cascade_attempt_liveness_kill ~labels ()
  in
  P.inc_counter P.metric_cascade_attempt_liveness_kill ~labels ();
  let after =
    P.metric_value_or_zero P.metric_cascade_attempt_liveness_kill ~labels ()
  in
  Alcotest.(check (float 1e-6))
    "kill counter increments by 1.0"
    (before +. 1.0) after

let test_observed_counter_increments () =
  let labels =
    [ ("cascade", "test_cascade");
      ("provider", "test_provider");
      ("outcome", "success") ]
  in
  let before =
    P.metric_value_or_zero P.metric_cascade_attempt_liveness_observed
      ~labels ()
  in
  P.inc_counter P.metric_cascade_attempt_liveness_observed ~labels ();
  P.inc_counter P.metric_cascade_attempt_liveness_observed ~labels ();
  let after =
    P.metric_value_or_zero P.metric_cascade_attempt_liveness_observed
      ~labels ()
  in
  Alcotest.(check (float 1e-6))
    "observed counter increments by delta"
    (before +. 2.0) after

let () =
  Alcotest.run "cascade_attempt_liveness_counters"
    [
      ( "metric names",
        [
          Alcotest.test_case "kill name stable" `Quick
            test_kill_metric_name_stable;
          Alcotest.test_case "observed name stable" `Quick
            test_observed_metric_name_stable;
        ] );
      ( "registration",
        [
          Alcotest.test_case "kill increments" `Quick
            test_kill_counter_increments;
          Alcotest.test_case "observed increments" `Quick
            test_observed_counter_increments;
        ] );
    ]
