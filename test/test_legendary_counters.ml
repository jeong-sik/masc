open Masc_mcp

let test_initial_zero () =
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "auto_bg_observed" 0 s.auto_bg_observed;
  Alcotest.(check int)
    "auto_bg_would_have_promoted" 0 s.auto_bg_would_have_promoted;
  Alcotest.(check int) "typed_advisor_allow" 0 s.typed_advisor_allow;
  Alcotest.(check int)
    "shell_gate_worker_dev_tools_allow" 0 s.shell_gate_worker_dev_tools_allow

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
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:true;
  Legendary_counters.incr_typed_advisor Shell_ir_validator.Allow;
  let json =
    Legendary_counters.snapshot_to_json (Legendary_counters.snapshot ())
  in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "has auto_bg_would_have_promoted"
    true
    (Astring.String.is_infix
       ~affix:"\"auto_bg_would_have_promoted\":1" s);
  Alcotest.(check bool)
    "has typed_advisor_allow"
    true
    (Astring.String.is_infix ~affix:"\"typed_advisor_allow\":1" s);
  Alcotest.(check bool)
    "retired observer fields removed"
    false
    (Astring.String.is_infix ~affix:"legacy_allow_shadow" s)

let test_reset () =
  Legendary_counters.incr_auto_bg_observed ~promoted_candidate:true;
  Legendary_counters.incr_typed_advisor Shell_ir_validator.Allow;
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "post-reset auto_bg_observed" 0 s.auto_bg_observed;
  Alcotest.(check int)
    "post-reset would_have_promoted" 0 s.auto_bg_would_have_promoted;
  Alcotest.(check int) "post-reset typed_advisor" 0 s.typed_advisor_allow

let approx_eq ~eps a b = Float.abs (a -. b) <= eps

let check_ratio name ~expected actual =
  Alcotest.(check bool)
    (Printf.sprintf "%s ~= %.4f (got %.4f)" name expected actual)
    true
    (approx_eq ~eps:1e-9 expected actual)

let test_auto_bg_promotion_rate_zero_denominator () =
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  check_ratio "auto_bg_promotion_rate zero"
    ~expected:0.0 (Legendary_counters.auto_bg_promotion_rate s)

let test_auto_bg_promotion_rate_math () =
  Legendary_counters.reset ();
  for _ = 1 to 6 do
    Legendary_counters.incr_auto_bg_observed ~promoted_candidate:false
  done;
  for _ = 1 to 4 do
    Legendary_counters.incr_auto_bg_observed ~promoted_candidate:true
  done;
  let s = Legendary_counters.snapshot () in
  check_ratio "promotion_rate = 0.4"
    ~expected:0.4 (Legendary_counters.auto_bg_promotion_rate s)

let test_snapshot_to_json_with_ratios_shape () =
  Legendary_counters.reset ();
  let json =
    Legendary_counters.snapshot_to_json_with_ratios
      (Legendary_counters.snapshot ())
  in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "flat field preserved"
    true
    (Astring.String.is_infix ~affix:"\"auto_bg_observed\":0" s);
  Alcotest.(check bool)
    "ratios sibling present"
    true
    (Astring.String.is_infix ~affix:"\"ratios\":{" s);
  Alcotest.(check bool)
    "auto_bg_promotion_rate finite 0.0"
    true
    (Astring.String.is_infix ~affix:"\"auto_bg_promotion_rate\":0.0" s);
  Alcotest.(check bool)
    "retired ratios removed"
    false
    (Astring.String.is_infix ~affix:"parse_coverage" s)

let () =
  Alcotest.run "legendary_counters"
    [
      ( "basic",
        [
          Alcotest.test_case "initial zero" `Quick test_initial_zero;
          Alcotest.test_case "auto_bg observed" `Quick test_auto_bg_observed;
          Alcotest.test_case "snapshot JSON shape" `Quick
            test_snapshot_json_shape;
          Alcotest.test_case "reset" `Quick test_reset;
        ] );
      ( "derived_ratios",
        [
          Alcotest.test_case "zero denominator returns 0.0" `Quick
            test_auto_bg_promotion_rate_zero_denominator;
          Alcotest.test_case "auto_bg_promotion_rate math" `Quick
            test_auto_bg_promotion_rate_math;
          Alcotest.test_case "JSON with ratios sibling" `Quick
            test_snapshot_to_json_with_ratios_shape;
        ] );
    ]
