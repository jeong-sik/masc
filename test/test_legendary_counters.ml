open Masc_mcp

let test_initial_zero () =
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "gate_diff_total" 0 s.gate_diff_total;
  Alcotest.(check int) "gate_diff_agree" 0 s.gate_diff_agree;
  Alcotest.(check int)
    "gate_diff_legacy_allow_shadow_deny" 0 s.gate_diff_legacy_allow_shadow_deny;
  Alcotest.(check int)
    "gate_diff_legacy_deny_shadow_allow" 0 s.gate_diff_legacy_deny_shadow_allow;
  Alcotest.(check int)
    "gate_diff_shadow_cannot_parse" 0 s.gate_diff_shadow_cannot_parse;
  Alcotest.(check int) "auto_bg_observed" 0 s.auto_bg_observed;
  Alcotest.(check int)
    "auto_bg_would_have_promoted" 0 s.auto_bg_would_have_promoted

let test_gate_diff_buckets () =
  Legendary_counters.reset ();
  Legendary_counters.incr_gate_diff `Agree;
  Legendary_counters.incr_gate_diff `Agree;
  Legendary_counters.incr_gate_diff `Legacy_allow_shadow_deny;
  Legendary_counters.incr_gate_diff `Legacy_deny_shadow_allow;
  Legendary_counters.incr_gate_diff `Shadow_cannot_parse;
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "total = 5" 5 s.gate_diff_total;
  Alcotest.(check int) "agree = 2" 2 s.gate_diff_agree;
  Alcotest.(check int)
    "legacy_allow_shadow_deny = 1" 1 s.gate_diff_legacy_allow_shadow_deny;
  Alcotest.(check int)
    "legacy_deny_shadow_allow = 1" 1 s.gate_diff_legacy_deny_shadow_allow;
  Alcotest.(check int)
    "shadow_cannot_parse = 1" 1 s.gate_diff_shadow_cannot_parse

let test_auto_bg_observed () =
  Legendary_counters.reset ();
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:false;
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:false;
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:true;
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "auto_bg_observed = 3" 3 s.auto_bg_observed;
  Alcotest.(check int)
    "auto_bg_would_have_promoted = 1" 1 s.auto_bg_would_have_promoted

let test_snapshot_json_shape () =
  Legendary_counters.reset ();
  Legendary_counters.incr_gate_diff `Legacy_allow_shadow_deny;
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:true;
  let json =
    Legendary_counters.snapshot_to_json (Legendary_counters.snapshot ())
  in
  (* Serialize and check stable field presence. *)
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "has gate_diff_total" true
    (Astring.String.is_infix ~affix:"\"gate_diff_total\":1" s);
  Alcotest.(check bool)
    "has legacy_allow_shadow_deny" true
    (Astring.String.is_infix
       ~affix:"\"gate_diff_legacy_allow_shadow_deny\":1" s);
  Alcotest.(check bool)
    "has auto_bg_would_have_promoted" true
    (Astring.String.is_infix
       ~affix:"\"auto_bg_would_have_promoted\":1" s)

let test_reset () =
  Legendary_counters.incr_gate_diff `Agree;
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:true;
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "post-reset total" 0 s.gate_diff_total;
  Alcotest.(check int) "post-reset auto_bg_observed" 0 s.auto_bg_observed;
  Alcotest.(check int)
    "post-reset would_have_promoted" 0 s.auto_bg_would_have_promoted

let () =
  Alcotest.run "legendary_counters"
    [
      ( "basic",
        [
          Alcotest.test_case "initial zero" `Quick test_initial_zero;
          Alcotest.test_case "gate_diff buckets" `Quick test_gate_diff_buckets;
          Alcotest.test_case "auto_bg observed" `Quick test_auto_bg_observed;
          Alcotest.test_case "snapshot JSON shape" `Quick
            test_snapshot_json_shape;
          Alcotest.test_case "reset" `Quick test_reset;
        ] );
    ]
