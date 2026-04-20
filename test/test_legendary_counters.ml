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
  Legendary_counters.incr_too_complex_by_tag "too_complex:redirect";
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "post-reset total" 0 s.gate_diff_total;
  Alcotest.(check int) "post-reset auto_bg_observed" 0 s.auto_bg_observed;
  Alcotest.(check int)
    "post-reset would_have_promoted" 0 s.auto_bg_would_have_promoted;
  Alcotest.(check int) "post-reset too_complex_redirect" 0 s.too_complex_redirect

let test_too_complex_prefixed_tag () =
  (* Shadow observer passes parse_tag strings straight through —
     "too_complex:redirect" must route to the redirect bucket. *)
  Legendary_counters.reset ();
  Legendary_counters.incr_too_complex_by_tag "too_complex:redirect";
  Legendary_counters.incr_too_complex_by_tag "too_complex:redirect";
  Legendary_counters.incr_too_complex_by_tag "too_complex:logic_op";
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "redirect = 2" 2 s.too_complex_redirect;
  Alcotest.(check int) "logic_op = 1" 1 s.too_complex_logic_op;
  Alcotest.(check int) "other untouched" 0 s.too_complex_other

let test_too_complex_bare_tag () =
  (* Callers may pass the bare reason name without the prefix. *)
  Legendary_counters.reset ();
  Legendary_counters.incr_too_complex_by_tag "heredoc";
  Legendary_counters.incr_too_complex_by_tag "here_string";
  Legendary_counters.incr_too_complex_by_tag "cmd_subst";
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "heredoc = 1" 1 s.too_complex_heredoc;
  Alcotest.(check int) "here_string = 1" 1 s.too_complex_here_string;
  Alcotest.(check int) "cmd_subst = 1" 1 s.too_complex_cmd_subst

let test_too_complex_parse_error () =
  (* parse_error is a distinct bucket — unclassifiable input that
     the post-hoc classifier could not attribute to a specific
     construct.  Must not collapse into too_complex_other. *)
  Legendary_counters.reset ();
  Legendary_counters.incr_too_complex_by_tag "parse_error";
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "parse_error = 1" 1 s.too_complex_parse_error;
  Alcotest.(check int) "other still 0" 0 s.too_complex_other

let test_too_complex_parse_aborted () =
  (* parse_aborted:<reason> (timeout/depth/token limit) → dedicated
     aborted bucket regardless of suffix. *)
  Legendary_counters.reset ();
  Legendary_counters.incr_too_complex_by_tag "parse_aborted:timeout_50ms";
  Legendary_counters.incr_too_complex_by_tag "parse_aborted:depth_limit";
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "parse_aborted = 2" 2 s.too_complex_parse_aborted

let test_too_complex_unknown_tag () =
  (* Unknown reason strings land in too_complex_other so the counter
     family always sums to the Shadow_cannot_parse total. *)
  Legendary_counters.reset ();
  Legendary_counters.incr_too_complex_by_tag "some_future_variant";
  Legendary_counters.incr_too_complex_by_tag "";
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "other = 2" 2 s.too_complex_other

let test_too_complex_json_shape () =
  (* All 15 new fields must serialise under stable names. *)
  Legendary_counters.reset ();
  Legendary_counters.incr_too_complex_by_tag "redirect";
  Legendary_counters.incr_too_complex_by_tag "arith_expansion";
  let json =
    Legendary_counters.snapshot_to_json (Legendary_counters.snapshot ())
  in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool) "has redirect" true
    (Astring.String.is_infix ~affix:"\"too_complex_redirect\":1" s);
  Alcotest.(check bool) "has arith_expansion" true
    (Astring.String.is_infix ~affix:"\"too_complex_arith_expansion\":1" s);
  Alcotest.(check bool) "has other (=0)" true
    (Astring.String.is_infix ~affix:"\"too_complex_other\":0" s)

let approx_eq ~eps a b = Float.abs (a -. b) <= eps

let check_ratio name ~expected actual =
  Alcotest.(check bool)
    (Printf.sprintf "%s ≈ %.4f (got %.4f)" name expected actual)
    true
    (approx_eq ~eps:1e-9 expected actual)

let test_ratios_zero_denominator () =
  (* Observer off / fresh process: every ratio must return a finite 0.0,
     not NaN / inf — shadow_counters JSON would fail to serialise
     otherwise. *)
  Legendary_counters.reset ();
  let s = Legendary_counters.snapshot () in
  check_ratio "disagree_ratio zero"
    ~expected:0.0 (Legendary_counters.disagree_ratio s);
  check_ratio "shadow_parse_coverage zero"
    ~expected:0.0 (Legendary_counters.shadow_parse_coverage s);
  check_ratio "auto_bg_promotion_rate zero"
    ~expected:0.0 (Legendary_counters.auto_bg_promotion_rate s)

let test_disagree_ratio_math () =
  (* 10 total = 6 agree + 3 disagree (2 legacy_allow_shadow_deny +
     1 legacy_deny_shadow_allow) + 1 shadow_cannot_parse.
     disagree_ratio should count only the two *disagreement* buckets
     — shadow_cannot_parse is its own category per the runbook. *)
  Legendary_counters.reset ();
  for _ = 1 to 6 do Legendary_counters.incr_gate_diff `Agree done;
  for _ = 1 to 2 do
    Legendary_counters.incr_gate_diff `Legacy_allow_shadow_deny
  done;
  Legendary_counters.incr_gate_diff `Legacy_deny_shadow_allow;
  Legendary_counters.incr_gate_diff `Shadow_cannot_parse;
  let s = Legendary_counters.snapshot () in
  Alcotest.(check int) "total = 10" 10 s.gate_diff_total;
  check_ratio "disagree_ratio = 3/10"
    ~expected:0.3 (Legendary_counters.disagree_ratio s)

let test_shadow_parse_coverage_math () =
  (* 100 total, 3 shadow_cannot_parse → coverage 0.97.  Exactly the
     runbook threshold for the MASC_BASH_AST_ONLY flip criterion. *)
  Legendary_counters.reset ();
  for _ = 1 to 97 do Legendary_counters.incr_gate_diff `Agree done;
  for _ = 1 to 3 do
    Legendary_counters.incr_gate_diff `Shadow_cannot_parse
  done;
  let s = Legendary_counters.snapshot () in
  check_ratio "coverage = 0.97"
    ~expected:0.97 (Legendary_counters.shadow_parse_coverage s)

let test_shadow_parse_coverage_full () =
  (* No parse failures → 1.0 (AST gate would parse everything
     observed so far). *)
  Legendary_counters.reset ();
  for _ = 1 to 5 do Legendary_counters.incr_gate_diff `Agree done;
  let s = Legendary_counters.snapshot () in
  check_ratio "coverage = 1.0"
    ~expected:1.0 (Legendary_counters.shadow_parse_coverage s)

let test_auto_bg_promotion_rate_math () =
  (* 10 observed, 4 would-have-promoted → 0.4.  Operator reads this
     and decides whether raising MASC_BLOCKING_BUDGET_MS is warranted
     before flipping MASC_BASH_AUTO_BG default. *)
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
      ( "too_complex_histogram",
        [
          Alcotest.test_case "prefixed tag" `Quick test_too_complex_prefixed_tag;
          Alcotest.test_case "bare tag" `Quick test_too_complex_bare_tag;
          Alcotest.test_case "parse_error dedicated bucket" `Quick
            test_too_complex_parse_error;
          Alcotest.test_case "parse_aborted dedicated bucket" `Quick
            test_too_complex_parse_aborted;
          Alcotest.test_case "unknown → other" `Quick test_too_complex_unknown_tag;
          Alcotest.test_case "JSON shape" `Quick test_too_complex_json_shape;
        ] );
      ( "derived_ratios",
        [
          Alcotest.test_case "zero denominator returns 0.0" `Quick
            test_ratios_zero_denominator;
          Alcotest.test_case "disagree_ratio math" `Quick
            test_disagree_ratio_math;
          Alcotest.test_case "shadow_parse_coverage math" `Quick
            test_shadow_parse_coverage_math;
          Alcotest.test_case "shadow_parse_coverage full" `Quick
            test_shadow_parse_coverage_full;
          Alcotest.test_case "auto_bg_promotion_rate math" `Quick
            test_auto_bg_promotion_rate_math;
        ] );
    ]
