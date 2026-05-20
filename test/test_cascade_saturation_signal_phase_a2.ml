(** Phase A.2 sanity tests — env flag default + metric name format.

    RFC-0153 Phase A.2 is additive only; this test verifies the
    minimum contract that Phase B/C will consume:
    - [Env_config_keeper.CascadeSaturationSignal.enabled] defaults to
      false when [MASC_CASCADE_SATURATION_SIGNAL_ENABLED] is unset.
    - [Keeper_metrics.metric_keeper_cascade_saturation_signal] follows
      the [masc_keeper_*_total] naming convention. *)

open Masc_mcp

let test_env_flag_defaults_off () =
  (* masc-mcp test/dune scrubs externally-visible MASC_* env vars for
     the test process, so the flag is observed as unset here. If a
     sibling test leaks a non-empty value, skip rather than mutate the
     environment (OCaml stdlib's [Unix] module exposes no [unsetenv]). *)
  match Sys.getenv_opt "MASC_CASCADE_SATURATION_SIGNAL_ENABLED" with
  | Some v when v <> "" -> Alcotest.skip ()
  | _ ->
      Alcotest.(check bool)
        "default false"
        false
        (Env_config_keeper.CascadeSaturationSignal.enabled ())

let test_metric_name_format () =
  let name = Keeper_metrics.metric_keeper_cascade_saturation_signal in
  Alcotest.(check string)
    "metric name exact"
    "masc_keeper_cascade_saturation_signal_total"
    name

let test_metric_name_naming_convention () =
  let name = Keeper_metrics.metric_keeper_cascade_saturation_signal in
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
