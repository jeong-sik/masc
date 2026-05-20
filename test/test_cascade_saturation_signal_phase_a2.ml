(** Phase A.2 sanity tests — env flag default + metric name format.

    RFC-0153 Phase A.2 is additive only; this test verifies the
    minimum contract that Phase B/C will consume:
    - [Env_config_keeper.CascadeSaturationSignal.enabled] defaults to
      false when [MASC_CASCADE_SATURATION_SIGNAL_ENABLED] is unset.
    - [Keeper_metrics.metric_keeper_cascade_saturation_signal] follows
      the [masc_keeper_*_total] naming convention. *)

let test_env_flag_defaults_off () =
  (* Ensure the env var is unset for this test; if a sibling test
     leaks a value, [Sys.getenv_opt] would observe it. We do not
     mutate the environment here — masc-mcp test/dune already
     scrubs externally-visible MASC_* values. *)
  let unset =
    try
      Unix.unsetenv "MASC_CASCADE_SATURATION_SIGNAL_ENABLED";
      true
    with _ -> false
  in
  if not unset then
    Alcotest.skip ()
  else
    Alcotest.(check bool)
      "default false"
      false
      (Masc_mcp.Env_config_keeper.CascadeSaturationSignal.enabled ())

let test_metric_name_format () =
  let name = Masc_mcp.Keeper_metrics.metric_keeper_cascade_saturation_signal in
  Alcotest.(check string)
    "metric name exact"
    "masc_keeper_cascade_saturation_signal_total"
    name

let test_metric_name_naming_convention () =
  let name = Masc_mcp.Keeper_metrics.metric_keeper_cascade_saturation_signal in
  let starts_with prefix str =
    String.length str >= String.length prefix
    && String.sub str 0 (String.length prefix) = prefix
  in
  let ends_with suffix str =
    let lp = String.length suffix in
    let ls = String.length str in
    ls >= lp && String.sub str (ls - lp) lp = suffix
  in
  Alcotest.(check bool) "starts with masc_" true (starts_with "masc_" name);
  Alcotest.(check bool) "ends with _total" true (ends_with "_total" name)

let suite =
  [ ( "env-flag",
      [ Alcotest.test_case "default off" `Quick test_env_flag_defaults_off ] );
    ( "metric-name",
      [ Alcotest.test_case "exact" `Quick test_metric_name_format;
        Alcotest.test_case "convention" `Quick
          test_metric_name_naming_convention;
      ] );
  ]

let () = Alcotest.run "cascade_saturation_signal_phase_a2" suite
