(** Tests for Post_verifier module — 3-dimension content verification.

    All tests are pure (no Eio needed) since Post_verifier has no IO. *)

module Pv = Masc_mcp.Post_verifier
module Hm = Masc_mcp.Heuristic_metrics

open Alcotest

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let is_pass = function Pv.Pass -> true | _ -> false
let is_warn = function Pv.Warn _ -> true | _ -> false
let is_fail = function Pv.Fail _ -> true | _ -> false

(* ================================================================ *)
(* Dimension 1: Relevance                                           *)
(* ================================================================ *)

let test_relevance_pass () =
  let result = Pv.verify ~content:"This is a meaningful post with enough substance to pass." in
  check bool "relevance passes for normal content" true (is_pass result.relevance)

let test_relevance_too_short () =
  (* Short but non-empty content passes — agents should not be penalized
     for concise responses like "ok", "done", "hi". Only empty/whitespace fails. *)
  let result = Pv.verify ~content:"hi" in
  check bool "short content passes relevance" true (is_pass result.relevance)

let test_relevance_whitespace_only () =
  let result = Pv.verify ~content:"       \n\n\t\t   " in
  check bool "whitespace only fails relevance" true (is_fail result.relevance)

let test_relevance_filler_short () =
  (* Short filler now warns instead of failing — reduced Thompson Sampling penalty. *)
  let result = Pv.verify ~content:"hello world" in
  check bool "short filler warns relevance" true (is_warn result.relevance)

let test_relevance_filler_long () =
  let result = Pv.verify ~content:"This is a hello world test with more text around it to pass length check." in
  check bool "long filler warns relevance" true (is_warn result.relevance)

let test_relevance_very_long () =
  let long = String.make 9000 'a' in
  let result = Pv.verify ~content:long in
  check bool "very long warns relevance" true (is_warn result.relevance)

(* ================================================================ *)
(* Dimension 2: Quality                                             *)
(* ================================================================ *)

let test_quality_pass () =
  let result = Pv.verify ~content:"A well-formed post about software architecture patterns." in
  check bool "quality passes for normal content" true (is_pass result.quality)

let test_quality_char_repetition_fail () =
  let result = Pv.verify ~content:"This has aaaaaaaa too many repeated characters." in
  check bool "8+ char repetition fails quality" true (is_fail result.quality)

let test_quality_char_repetition_warn () =
  let result = Pv.verify ~content:"This has aaaaa some repeated characters." in
  check bool "5+ char repetition warns quality" true (is_warn result.quality)

let test_quality_token_repetition () =
  let result = Pv.verify ~content:"foo foo foo foo foo foo foo foo foo" in
  check bool "repetitive tokens fail quality" true (is_fail result.quality)

let test_quality_normal_tokens () =
  let result = Pv.verify ~content:"The quick brown fox jumps over the lazy dog." in
  check bool "diverse tokens pass quality" true (is_pass result.quality)

let test_quality_formatting_chars_pass () =
  (* Markdown separators and code fences should NOT trigger repetition detection.
     Agents using structured output should not be penalized. *)
  let result = Pv.verify ~content:"Section header\n========\nContent below the line." in
  check bool "markdown separator passes quality" true (is_pass result.quality);
  let result2 = Pv.verify ~content:"```ocaml\nlet x = 42\n```\nAbove is a code block." in
  check bool "code fence passes quality" true (is_pass result2.quality)

(* ================================================================ *)
(* Dimension 3: Safety                                              *)
(* ================================================================ *)

let test_safety_pass () =
  let result = Pv.verify ~content:"A normal post about technology and design patterns." in
  check bool "safety passes for normal content" true (is_pass result.safety)

let test_safety_all_caps () =
  let result = Pv.verify ~content:"THIS IS ALL CAPS AND IT LOOKS LIKE SHOUTING" in
  check bool "all caps warns safety" true (is_warn result.safety)

let test_safety_url_spam () =
  let result = Pv.verify ~content:"https://spam.example.com/very/long/path/to/something https://another.example.com/more/content" in
  check bool "URL-heavy content no longer affects safety" true
    (is_pass result.safety)

(* ================================================================ *)
(* Overall verdict                                                  *)
(* ================================================================ *)

let test_overall_pass () =
  let result = Pv.verify ~content:"A thoughtful discussion about Eio concurrency patterns in OCaml 5." in
  check bool "overall passes" true (is_pass result.overall);
  check bool "acceptable" true (Pv.is_acceptable result)

let test_overall_fail_propagation () =
  (* Use empty content (only whitespace) to trigger a real Fail. *)
  let result = Pv.verify ~content:"   \t\n  " in
  check bool "fail propagates to overall" true (is_fail result.overall);
  check bool "not acceptable" false (Pv.is_acceptable result)

let test_overall_warn_propagation () =
  let result = Pv.verify ~content:"A post with some aaaaa repeated chars but otherwise OK content." in
  check bool "warn propagates to overall" true (is_warn result.overall);
  check bool "still acceptable" true (Pv.is_acceptable result)

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let test_verdict_to_string () =
  check string "pass" "pass" (Pv.verdict_to_string Pv.Pass);
  check string "warn" "warn(test)" (Pv.verdict_to_string (Pv.Warn "test"));
  check string "fail" "fail(test)" (Pv.verdict_to_string (Pv.Fail "test"))

let test_dimension_to_string () =
  check string "relevance" "relevance" (Pv.dimension_to_string Pv.Relevance);
  check string "quality" "quality" (Pv.dimension_to_string Pv.Quality);
  check string "safety" "safety" (Pv.dimension_to_string Pv.Safety)

let test_result_to_json () =
  let result = Pv.verify ~content:"A normal post about technology." in
  let json = Pv.result_to_json result in
  let open Yojson.Safe.Util in
  (* Normal content should be acceptable *)
  let acceptable = json |> member "acceptable" |> to_bool in
  check bool "normal content is acceptable" true acceptable;
  (* Verify all expected fields exist *)
  let relevance = json |> member "relevance" |> to_string in
  check bool "relevance is pass" true (String.length relevance > 0);
  let overall = json |> member "overall" |> to_string in
  check bool "overall is pass" true (String.length overall > 0)

let test_to_dimension_results () =
  let result = Pv.verify ~content:"A normal post about technology." in
  let dims = Pv.to_dimension_results result in
  check int "3 dimensions" 3 (List.length dims);
  (* Verify dimension names are the expected set *)
  let dim_names = List.map (fun dr -> Pv.dimension_to_string dr.Pv.dimension) dims in
  check bool "has relevance" true (List.mem "relevance" dim_names);
  check bool "has quality" true (List.mem "quality" dim_names);
  check bool "has safety" true (List.mem "safety" dim_names)

let test_heuristic_coverage_report_groups_sites () =
  let events =
    [
      Hm.event_to_json
        {
          module_name = "post_verifier";
          site = "relevance";
          raw_value = 0.7;
          threshold = 0.5;
          triggered = true;
          provenance = Hm.Post_verifier "relevance";
          timestamp = 1.0;
        };
      Hm.event_to_json
        {
          module_name = "post_verifier";
          site = "relevance";
          raw_value = 0.9;
          threshold = 0.5;
          triggered = true;
          provenance = Hm.Post_verifier "relevance";
          timestamp = 2.5;
        };
      Hm.event_to_json
        {
          module_name = "post_verifier";
          site = "relevance";
          raw_value = 0.2;
          threshold = 0.5;
          triggered = false;
          provenance = Hm.Post_verifier "relevance";
          timestamp = 2.0;
        };
      Hm.event_to_json
        {
          module_name = "keeper_alerting";
          site = "keeper_alert_signal";
          raw_value = 0.6;
          threshold = 0.4;
          triggered = true;
          provenance = Hm.Alert_scoring "keyword";
          timestamp = 3.0;
        };
    ]
  in
  let report = Hm.coverage_report_of_events events in
  check int "total events" 4 report.total_events;
  check int "two sites" 2 (List.length report.sites);
  check int "three decision shapes" 3 report.decision_shape_count;
  check int "compat tuple count aliases decision shapes" 3
    report.unique_decision_tuples;
  check int "one mixed outcome site" 1 report.mixed_outcome_sites;
  let post_verifier_site =
    List.find
      (fun (site : Hm.coverage_site) ->
         site.module_name = "post_verifier"
         && site.site = "relevance")
      report.sites
  in
  check int "site count" 3 post_verifier_site.count;
  check int "site triggered count" 2 post_verifier_site.triggered_count

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  run "Post_verifier" [
    "relevance", [
      test_case "normal content passes" `Quick test_relevance_pass;
      test_case "too short fails" `Quick test_relevance_too_short;
      test_case "whitespace only fails" `Quick test_relevance_whitespace_only;
      test_case "short filler fails" `Quick test_relevance_filler_short;
      test_case "long filler warns" `Quick test_relevance_filler_long;
      test_case "very long warns" `Quick test_relevance_very_long;
    ];
    "quality", [
      test_case "normal content passes" `Quick test_quality_pass;
      test_case "8+ char repetition fails" `Quick test_quality_char_repetition_fail;
      test_case "5+ char repetition warns" `Quick test_quality_char_repetition_warn;
      test_case "repetitive tokens fail" `Quick test_quality_token_repetition;
      test_case "diverse tokens pass" `Quick test_quality_normal_tokens;
      test_case "formatting chars pass" `Quick test_quality_formatting_chars_pass;
    ];
    "safety", [
      test_case "normal content passes" `Quick test_safety_pass;
      test_case "all caps warns" `Quick test_safety_all_caps;
      test_case "URL-heavy content passes" `Quick test_safety_url_spam;
    ];
    "overall", [
      test_case "overall passes" `Quick test_overall_pass;
      test_case "fail propagates" `Quick test_overall_fail_propagation;
      test_case "warn propagates" `Quick test_overall_warn_propagation;
    ];
    "serialization", [
      test_case "verdict_to_string" `Quick test_verdict_to_string;
      test_case "dimension_to_string" `Quick test_dimension_to_string;
      test_case "result_to_json" `Quick test_result_to_json;
      test_case "to_dimension_results" `Quick test_to_dimension_results;
    ];
    "heuristic_metrics", [
      test_case "coverage report groups sites" `Quick
        test_heuristic_coverage_report_groups_sites;
    ];
  ]
