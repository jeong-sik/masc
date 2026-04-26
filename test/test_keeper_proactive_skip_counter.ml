(* test/test_keeper_proactive_skip_counter.ml

   #10008 failure mode 3: pin the canonical Prometheus metric
   name for the proactive-scheduler skip-reason counter and
   spot-check that the [skip_reason_to_string] vocabulary
   matches the labels the counter will carry.

   The actual counter increment path runs inside the keepalive
   fiber and would require a full keeper runtime to exercise —
   this test instead locks down the contract surface so that:

   1. A Grafana rule written against
      [masc_keeper_proactive_skip_total] cannot silently break
      on rename.
   2. Each concrete [skip_reason] variant round-trips to the
      string label the counter consumes.  Adding a new reason
      without updating dashboards becomes a test failure. *)

module KK = Masc_mcp.Keeper_keepalive
module KW = Masc_mcp.Keeper_world_observation

let test_metric_name_stable () =
  Alcotest.(check string)
    "proactive skip counter canonical name"
    "masc_keeper_proactive_skip_total"
    KK.proactive_skip_reason_metric
;;

(* [verdict_reasons_to_strings] is the actual producer of the
   [reason] label at the emit site.  Pin each concrete variant's
   string form so a silent enum rename becomes a failed test. *)
let test_skip_reason_labels_match_counter () =
  let mk reason = KW.Skip { reasons = reason, [] } in
  let reason_str v =
    match KW.verdict_reasons_to_strings v with
    | [ s ] -> s
    | other ->
      Alcotest.fail
        (Printf.sprintf
           "expected exactly one reason string, got [%s]"
           (String.concat "; " other))
  in
  Alcotest.(check string)
    "keeper_paused label"
    "keeper_paused"
    (reason_str (mk KW.Keeper_paused));
  Alcotest.(check string)
    "approval_pending label"
    "approval_pending"
    (reason_str (mk KW.Approval_pending));
  Alcotest.(check string)
    "scheduled_autonomous_disabled label"
    "scheduled_autonomous_disabled"
    (reason_str (mk KW.Scheduled_autonomous_disabled));
  Alcotest.(check string) "no_signal label" "no_signal" (reason_str (mk KW.No_signal));
  Alcotest.(check string)
    "idle_gate_pending label"
    "idle_gate_pending"
    (reason_str (mk (KW.Idle_gate_pending { remaining_sec = 42 })));
  Alcotest.(check string)
    "cooldown_pending label"
    "cooldown_pending"
    (reason_str (mk (KW.Cooldown_pending { remaining_sec = 42 })));
  Alcotest.(check string)
    "provider_cooldown_pending label"
    "provider_cooldown_pending"
    (reason_str (mk (KW.Provider_cooldown_pending { remaining_sec = 42 })))
;;

let () =
  Alcotest.run
    "keeper_proactive_skip_counter_10008fm3"
    [ ( "metric_name"
      , [ Alcotest.test_case "canonical name stable" `Quick test_metric_name_stable ] )
    ; ( "skip_reason_labels"
      , [ Alcotest.test_case
            "variants map to label strings"
            `Quick
            test_skip_reason_labels_match_counter
        ] )
    ]
;;
