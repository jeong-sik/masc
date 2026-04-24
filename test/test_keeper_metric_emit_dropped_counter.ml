(* #10047: Verify masc_keeper_metric_emit_dropped_total counter is
   registered and increments correctly per keeper/channel/site labels. The
   actual silent-swallow sites in [keeper_turn.ml] /
   [keeper_unified_turn.ml] only fire on exception, which requires a
   full keeper fixture; here we just exercise the counter plumbing to
   ensure the registration and labels are wired. *)

open Alcotest

module P = Masc_mcp.Prometheus

let labels ~site ~channel =
  [ ("keeper", "test_keeper"); ("channel", channel); ("site", site) ]

let value_for ~site ~channel =
  P.metric_value_or_zero P.metric_keeper_metric_emit_dropped
    ~labels:(labels ~site ~channel) ()

let test_registration_returns_zero_baseline () =
  (* Counter must be registered so [metric_value_or_zero] resolves to
     0.0 rather than None (the distinction between "undefined metric"
     and "defined but never incremented"). *)
  let msg = value_for ~site:"keeper_turn_msg" ~channel:"turn" in
  let cyc =
    value_for ~site:"keeper_unified_turn" ~channel:"scheduled_autonomous"
  in
  check (float 1e-9) "keeper_turn_msg baseline" 0.0 msg;
  check (float 1e-9) "keeper_unified_turn baseline" 0.0 cyc

let test_increment_per_site_label () =
  let before_msg = value_for ~site:"keeper_turn_msg" ~channel:"turn" in
  let before_cyc =
    value_for ~site:"keeper_unified_turn" ~channel:"scheduled_autonomous"
  in
  P.inc_counter P.metric_keeper_metric_emit_dropped
    ~labels:(labels ~site:"keeper_turn_msg" ~channel:"turn") ();
  P.inc_counter P.metric_keeper_metric_emit_dropped
    ~labels:(labels ~site:"keeper_turn_msg" ~channel:"turn") ();
  P.inc_counter P.metric_keeper_metric_emit_dropped
    ~labels:(labels ~site:"keeper_unified_turn" ~channel:"scheduled_autonomous")
    ();
  let after_msg = value_for ~site:"keeper_turn_msg" ~channel:"turn" in
  let after_cyc =
    value_for ~site:"keeper_unified_turn" ~channel:"scheduled_autonomous"
  in
  check (float 1e-9) "keeper_turn_msg +2" (before_msg +. 2.0) after_msg;
  check (float 1e-9) "keeper_unified_turn +1" (before_cyc +. 1.0) after_cyc

let () =
  run "keeper_metric_emit_dropped"
    [
      ( "10047",
        [
          test_case "registered (baseline = 0)" `Quick
            test_registration_returns_zero_baseline;
          test_case "increment per keeper/channel/site labels" `Quick
            test_increment_per_site_label;
        ] );
    ]
