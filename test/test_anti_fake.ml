(** Tests for Anti_fake — anti-fake test quality scoring. *)

module AF = Masc_mcp.Anti_fake

(* ── Helpers ────────────────────────────────────────────────── *)

let float_eps = Alcotest.testable
  (fun ppf v -> Fmt.pf ppf "%.4f" v)
  (fun a b -> Float.abs (a -. b) < 0.001)

let score content =
  AF.score_content ~file_path:"<test>" content

(* ── Test: vacuous assert true → fake ──────────────────────── *)

let test_assert_true_is_fake () =
  let content =
    {|let test_a () = assert true
let test_b () = assert true
let test_c () = assert true|}
  in
  let r = score content in
  Alcotest.(check string) "quality_tier" "fake" r.quality_tier;
  Alcotest.(check bool) "score < 0.3" true (r.final_score < 0.3);
  (* 3 findings for "assert true" *)
  Alcotest.(check int) "findings count" 3 (List.length r.findings);
  List.iter (fun f ->
    Alcotest.(check string) "pattern" "assert true" f.AF.pattern;
    match f.AF.severity with
    | AF.Critical -> ()
    | _ -> Alcotest.fail "expected Critical severity"
  ) r.findings

(* ── Test: proper Alcotest assertions → good ───────────────── *)

let test_alcotest_check_is_good () =
  let content =
    {|let test_create () =
  let v = create () in
  Alcotest.(check int) "initial" 0 v

let test_tick () =
  let v = tick () in
  Alcotest.(check int) "ticked" 1 v|}
  in
  let r = score content in
  Alcotest.(check bool) "score >= 0.5" true (r.final_score >= 0.5);
  Alcotest.(check string) "tier is good or excellent"
    (if r.final_score >= 0.8 then "excellent" else "good")
    r.quality_tier;
  (* No findings — no penalty patterns present *)
  Alcotest.(check int) "no penalties" 0 (List.length r.findings)

(* ── Test: mixed good and bad → intermediate ───────────────── *)

let test_mixed_score () =
  let content =
    {|let test_a () = assert true
let test_b () =
  Alcotest.(check int) "val" 42 (compute ())
let test_c () =
  let _ = ignored_result () in
  ()|}
  in
  let r = score content in
  (* Has both penalties and bonuses; score should be moderate *)
  Alcotest.(check bool) "has findings" true (List.length r.findings > 0);
  (* Not purely fake — the Alcotest.check rescues it somewhat *)
  Alcotest.(check bool) "score > 0.0" true (r.final_score > 0.0)

(* ── Test: empty file → base score 0.5 ────────────────────── *)

let test_empty_file () =
  let r = score "" in
  Alcotest.(check (float_eps)) "base score" 0.5 r.final_score;
  Alcotest.(check string) "tier" "good" r.quality_tier;
  Alcotest.(check int) "no findings" 0 (List.length r.findings);
  Alcotest.(check int) "total_lines" 1 r.total_lines;
  Alcotest.(check int) "test_lines" 0 r.test_lines

(* ── Test: quality tier boundaries ─────────────────────────── *)

let test_quality_tier_excellent () =
  Alcotest.(check string) "0.8" "excellent" (AF.quality_tier 0.8);
  Alcotest.(check string) "1.0" "excellent" (AF.quality_tier 1.0);
  Alcotest.(check string) "0.95" "excellent" (AF.quality_tier 0.95)

let test_quality_tier_good () =
  Alcotest.(check string) "0.5" "good" (AF.quality_tier 0.5);
  Alcotest.(check string) "0.79" "good" (AF.quality_tier 0.79)

let test_quality_tier_suspect () =
  Alcotest.(check string) "0.3" "suspect" (AF.quality_tier 0.3);
  Alcotest.(check string) "0.49" "suspect" (AF.quality_tier 0.49)

let test_quality_tier_fake () =
  Alcotest.(check string) "0.0" "fake" (AF.quality_tier 0.0);
  Alcotest.(check string) "0.29" "fake" (AF.quality_tier 0.29)

(* ── Test: roundtrip bonus ─────────────────────────────────── *)

let test_roundtrip_bonus () =
  let content =
    {|let test_roundtrip () =
  let encoded = encode value in
  let decoded = decode encoded in
  Alcotest.(check int) "roundtrip" value decoded|}
  in
  let r = score content in
  (* roundtrip (+0.15) + Alcotest.check (+0.15) on base 0.5 = 0.8 *)
  Alcotest.(check bool) "score >= 0.8" true (r.final_score >= 0.8);
  Alcotest.(check string) "tier" "excellent" r.quality_tier

(* ── Test: multiple penalties accumulate ────────────────────── *)

let test_penalties_accumulate () =
  let content =
    {|let test_a () = assert true
let test_b () = assert true
let _ = something ()
(* TODO: fix this test *)
(* FIXME: broken *)|}
  in
  let r = score content in
  (* 2 * (-0.3) + 1 * (-0.2) + 1 * (-0.15) + 1 * (-0.15) = -1.1 *)
  (* raw = 0.5 + (-1.1) = -0.6 → clamped to 0.0 *)
  Alcotest.(check (float_eps)) "clamped to 0.0" 0.0 r.final_score;
  Alcotest.(check string) "tier" "fake" r.quality_tier

(* ── Test: clamp ───────────────────────────────────────────── *)

let test_clamp () =
  Alcotest.(check (float_eps)) "within" 0.5 (AF.clamp 0.5 ~lo:0.0 ~hi:1.0);
  Alcotest.(check (float_eps)) "below" 0.0 (AF.clamp (-1.0) ~lo:0.0 ~hi:1.0);
  Alcotest.(check (float_eps)) "above" 1.0 (AF.clamp 2.0 ~lo:0.0 ~hi:1.0)

(* ── Test: bonus cap at 3 occurrences ──────────────────────── *)

let test_bonus_capped_at_3 () =
  let lines = List.init 5 (fun _ -> "Alcotest.(check int) \"v\" 1 1") in
  let content = String.concat "\n" lines in
  let r = score content in
  (* 5 occurrences but capped at 3: bonus = 0.15 * 3 = 0.45 *)
  (* base 0.5 + 0.45 = 0.95 *)
  Alcotest.(check (float_eps)) "capped bonus" 0.95 r.final_score

(* ── Test: summarize ───────────────────────────────────────── *)

let test_summarize_empty () =
  let s = AF.summarize [] in
  Alcotest.(check int) "total" 0 s.total_files;
  Alcotest.(check (float_eps)) "avg" 0.0 s.avg_score

let test_summarize_mixed () =
  let r1 = score "assert true\nassert true\nassert true" in
  let r2 = score "Alcotest.(check int) \"x\" 1 1" in
  let s = AF.summarize [r1; r2] in
  Alcotest.(check int) "total" 2 s.total_files;
  Alcotest.(check bool) "min <= max" true (s.min_score <= s.max_score);
  (* r1 is fake (score < 0.3) *)
  Alcotest.(check int) "fake_count" 1 s.fake_count

(* ── Test: JSON serialization round-trips key fields ────────── *)

let test_result_to_json () =
  let r = score "Alcotest.(check int) \"val\" 1 1" in
  let json = AF.result_to_json r in
  let open Yojson.Safe.Util in
  let file = json |> member "file" |> to_string in
  let tier = json |> member "quality_tier" |> to_string in
  let fs = json |> member "final_score" |> to_float in
  Alcotest.(check string) "file" "<test>" file;
  Alcotest.(check string) "tier" r.quality_tier tier;
  Alcotest.(check (float_eps)) "final_score" r.final_score fs

let test_summary_to_json () =
  let r = score "" in
  let s = AF.summarize [r] in
  let json = AF.summary_to_json s in
  let open Yojson.Safe.Util in
  let total = json |> member "total_files" |> to_int in
  Alcotest.(check int) "total_files" 1 total

(* ── Test: severity_to_string ──────────────────────────────── *)

let test_severity_to_string () =
  Alcotest.(check string) "info" "info" (AF.severity_to_string Info);
  Alcotest.(check string) "warning" "warning" (AF.severity_to_string Warning);
  Alcotest.(check string) "critical" "critical" (AF.severity_to_string Critical)

(* ── Test: test_lines count ────────────────────────────────── *)

let test_test_lines_count () =
  let content =
    {|let x = 1
Alcotest.(check int) "a" 1 1
let y = 2
assert true
let z = 3|}
  in
  let r = score content in
  (* line 2: Alcotest.check, line 4: assert true → 2 test lines *)
  Alcotest.(check int) "test_lines" 2 r.test_lines

(* ── Test: property-based testing patterns ─────────────────── *)

let test_property_bonus () =
  let content =
    {|let test_prop () =
  QCheck.Test.make ~count:100
    QCheck.int (fun n -> property_holds n)|}
  in
  let r = score content in
  (* QCheck appears twice (+0.1*2) + property (+0.1) on base 0.5 = 0.8 *)
  Alcotest.(check bool) "score >= 0.7" true (r.final_score >= 0.7);
  Alcotest.(check string) "tier" "excellent" r.quality_tier

(* ── Runner ─────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Anti_fake" [
    "scoring", [
      Alcotest.test_case "assert true is fake" `Quick test_assert_true_is_fake;
      Alcotest.test_case "Alcotest.check is good" `Quick test_alcotest_check_is_good;
      Alcotest.test_case "mixed score" `Quick test_mixed_score;
      Alcotest.test_case "empty file" `Quick test_empty_file;
      Alcotest.test_case "roundtrip bonus" `Quick test_roundtrip_bonus;
      Alcotest.test_case "penalties accumulate" `Quick test_penalties_accumulate;
      Alcotest.test_case "bonus capped at 3" `Quick test_bonus_capped_at_3;
      Alcotest.test_case "property bonus" `Quick test_property_bonus;
      Alcotest.test_case "test_lines count" `Quick test_test_lines_count;
    ];
    "quality_tier", [
      Alcotest.test_case "excellent" `Quick test_quality_tier_excellent;
      Alcotest.test_case "good" `Quick test_quality_tier_good;
      Alcotest.test_case "suspect" `Quick test_quality_tier_suspect;
      Alcotest.test_case "fake" `Quick test_quality_tier_fake;
    ];
    "clamp", [
      Alcotest.test_case "clamp" `Quick test_clamp;
    ];
    "summarize", [
      Alcotest.test_case "empty" `Quick test_summarize_empty;
      Alcotest.test_case "mixed" `Quick test_summarize_mixed;
    ];
    "json", [
      Alcotest.test_case "result_to_json" `Quick test_result_to_json;
      Alcotest.test_case "summary_to_json" `Quick test_summary_to_json;
      Alcotest.test_case "severity_to_string" `Quick test_severity_to_string;
    ];
  ]
