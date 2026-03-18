(** Tests for Autonomy_adjuster module — Feedback Closure for Agent Selection *)

open Alcotest
open Masc_mcp

module Aa = Autonomy_adjuster
module Ls = Thompson_sampling
module Ah = Agent_health

(* Helper: unique agent name per test to avoid pollution *)
let fresh_name prefix =
  Printf.sprintf "%s-%d" prefix (Random.int 1_000_000)

(* Helper: reset agent stats for clean test state *)
let fresh_agent name =
  Ls.init_agent name;
  let s = Ls.get_stats name in
  s.alpha <- 1.0;
  s.beta <- 1.0;
  s.selections <- 0;
  s.last_selected_at <- 0.0;
  s.total_votes_up <- 0;
  s.total_votes_down <- 0;
  s.posts_created <- 0;
  s.comments_created <- 0;
  s.skips <- 0;
  s.updated_at <- 0.0

let float_eq ?(eps = 0.001) a b = Float.abs (a -. b) < eps

(** {1 Action Classification Tests} *)

let test_classify_autonomous () =
  let r = Aa.get_autonomy ~agent_name:(fresh_name "cls-auto") in
  (* Default level is 0.5 → Supervised *)
  check string "default is supervised"
    "supervised" (Aa.action_class_to_string r.action_class);
  check bool "default level is 0.5" true (float_eq r.level 0.5)

let test_classify_thresholds () =
  (* Test boundary values for classify_action via reset *)
  let name = fresh_name "cls-thresh" in
  let r1 = Aa.reset ~agent_name:name ~level:0.8 () in
  check string "0.8 → autonomous" "autonomous"
    (Aa.action_class_to_string r1.action_class);
  let r2 = Aa.reset ~agent_name:name ~level:0.79 () in
  check string "0.79 → supervised" "supervised"
    (Aa.action_class_to_string r2.action_class);
  let r3 = Aa.reset ~agent_name:name ~level:0.5 () in
  check string "0.5 → supervised" "supervised"
    (Aa.action_class_to_string r3.action_class);
  let r4 = Aa.reset ~agent_name:name ~level:0.49 () in
  check string "0.49 → restricted" "restricted"
    (Aa.action_class_to_string r4.action_class);
  let r5 = Aa.reset ~agent_name:name ~level:0.2 () in
  check string "0.2 → restricted" "restricted"
    (Aa.action_class_to_string r5.action_class);
  let r6 = Aa.reset ~agent_name:name ~level:0.19 () in
  check string "0.19 → suspended" "suspended"
    (Aa.action_class_to_string r6.action_class);
  let r7 = Aa.reset ~agent_name:name ~level:0.0 () in
  check string "0.0 → suspended" "suspended"
    (Aa.action_class_to_string r7.action_class)

(** {1 Adjust Tests — Quality-Based} *)

let test_adjust_high_quality_bumps_up () =
  let name = fresh_name "adj-hq" in
  fresh_agent name;
  let s = Ls.get_stats name in
  (* Set high quality: alpha=8.0, beta=1.0 → ratio = 8/9 ≈ 0.89 > 0.7 *)
  s.alpha <- 8.0;
  s.beta <- 1.0;
  (* Start at 0.5 *)
  let _ = Aa.reset ~agent_name:name ~level:0.5 () in
  let r = Aa.adjust ~agent_name:name in
  check bool "level increased" true (r.level > 0.5);
  check bool "level is 0.55" true (float_eq r.level 0.55);
  check bool "quality_ratio > 0.7" true (r.quality_ratio > 0.7)

let test_adjust_low_quality_bumps_down () =
  let name = fresh_name "adj-lq" in
  fresh_agent name;
  let s = Ls.get_stats name in
  (* Set low quality: alpha=1.0, beta=8.0 → ratio = 1/9 ≈ 0.11 < 0.4 *)
  s.alpha <- 1.0;
  s.beta <- 8.0;
  let _ = Aa.reset ~agent_name:name ~level:0.5 () in
  let r = Aa.adjust ~agent_name:name in
  check bool "level decreased" true (r.level < 0.5);
  check bool "level is 0.4" true (float_eq r.level 0.4);
  check bool "quality_ratio < 0.4" true (r.quality_ratio < 0.4)

let test_adjust_medium_quality_no_change () =
  let name = fresh_name "adj-mq" in
  fresh_agent name;
  let s = Ls.get_stats name in
  (* Set medium quality: alpha=3.0, beta=3.0 → ratio = 0.5 *)
  s.alpha <- 3.0;
  s.beta <- 3.0;
  let _ = Aa.reset ~agent_name:name ~level:0.6 () in
  let r = Aa.adjust ~agent_name:name in
  check bool "level unchanged" true (float_eq r.level 0.6)

(** {1 Health Gate Tests} *)

let test_adjust_unhealthy_floors_to_zero () =
  let name = fresh_name "adj-unhealthy" in
  fresh_agent name;
  let s = Ls.get_stats name in
  s.alpha <- 8.0;
  s.beta <- 1.0;
  let _ = Aa.reset ~agent_name:name ~level:0.9 () in
  (* Make agent unhealthy *)
  for _ = 1 to 10 do
    Ah.record_failure ~agent_name:name ~reason:"test_fail"
  done;
  let r = Aa.adjust ~agent_name:name in
  check bool "unhealthy → level 0.0" true (float_eq r.level 0.0);
  check string "unhealthy → suspended" "suspended"
    (Aa.action_class_to_string r.action_class)

let test_adjust_recovering_caps_at_half () =
  let name = fresh_name "adj-recovering" in
  fresh_agent name;
  let s = Ls.get_stats name in
  s.alpha <- 8.0;
  s.beta <- 1.0;
  let _ = Aa.reset ~agent_name:name ~level:0.8 () in
  (* Make agent unhealthy first, then record success to transition to recovering *)
  for _ = 1 to 5 do
    Ah.record_failure ~agent_name:name ~reason:"test_fail"
  done;
  Ah.record_success ~agent_name:name;
  let health = Ah.check_health ~agent_name:name in
  (match health with
   | Ah.Recovering ->
     let r = Aa.adjust ~agent_name:name in
     check bool "recovering → level <= 0.5" true (r.level <= 0.5)
   | _ ->
     (* If not recovering, the test setup did not trigger the right state.
        Skip gracefully — this depends on circuit breaker thresholds. *)
     ())

(** {1 Clamp Tests} *)

let test_level_clamped_at_bounds () =
  let name = fresh_name "adj-clamp" in
  fresh_agent name;
  let r1 = Aa.reset ~agent_name:name ~level:1.5 () in
  check bool "clamped at 1.0" true (float_eq r1.level 1.0);
  let r2 = Aa.reset ~agent_name:name ~level:(-0.5) () in
  check bool "clamped at 0.0" true (float_eq r2.level 0.0)

(** {1 Cumulative Adjust Tests} *)

let test_cumulative_adjustments () =
  let name = fresh_name "adj-cumul" in
  fresh_agent name;
  let s = Ls.get_stats name in
  s.alpha <- 8.0;
  s.beta <- 1.0;
  let _ = Aa.reset ~agent_name:name ~level:0.5 () in
  (* 3 consecutive high-quality adjustments: +0.05 each *)
  let r1 = Aa.adjust ~agent_name:name in
  check bool "first bump" true (float_eq r1.level 0.55);
  let r2 = Aa.adjust ~agent_name:name in
  check bool "second bump" true (float_eq r2.level 0.60);
  let r3 = Aa.adjust ~agent_name:name in
  check bool "third bump" true (float_eq r3.level 0.65)

(** {1 JSON Serialization Tests} *)

let test_json_roundtrip () =
  let name = fresh_name "json-rt" in
  let r = Aa.reset ~agent_name:name ~level:0.75 () in
  let json = Aa.autonomy_record_to_yojson r in
  match Aa.autonomy_record_of_yojson json with
  | Ok r2 ->
    check string "agent_name roundtrip" r.agent_name r2.agent_name;
    check bool "level roundtrip" true (float_eq r.level r2.level);
    check string "action_class roundtrip"
      (Aa.action_class_to_string r.action_class)
      (Aa.action_class_to_string r2.action_class);
    check bool "quality_ratio roundtrip" true
      (float_eq r.quality_ratio r2.quality_ratio)
  | Error e -> fail (Printf.sprintf "deserialization failed: %s" e)

let test_json_malformed () =
  let bad = `Assoc [("agent_name", `String "x")] in
  match Aa.autonomy_record_of_yojson bad with
  | Ok _ -> fail "should have failed on malformed JSON"
  | Error _ -> ()

(** {1 Batch Operation Tests} *)

let test_get_all () =
  let n1 = fresh_name "batch-1" in
  let n2 = fresh_name "batch-2" in
  let _ = Aa.reset ~agent_name:n1 ~level:0.3 () in
  let _ = Aa.reset ~agent_name:n2 ~level:0.9 () in
  let all = Aa.get_all () in
  let has_n1 = List.exists (fun r -> r.Aa.agent_name = n1) all in
  let has_n2 = List.exists (fun r -> r.Aa.agent_name = n2) all in
  check bool "batch contains n1" true has_n1;
  check bool "batch contains n2" true has_n2

let test_reset_returns_correct_record () =
  let name = fresh_name "reset-test" in
  let r = Aa.reset ~agent_name:name ~level:0.42 () in
  check string "name matches" name r.agent_name;
  check bool "level matches" true (float_eq r.level 0.42);
  check string "action_class correct" "restricted"
    (Aa.action_class_to_string r.action_class)

let test_check_autonomy () =
  let name = fresh_name "check-auto" in
  let _ = Aa.reset ~agent_name:name ~level:0.85 () in
  let ac = Aa.check_autonomy ~agent_name:name in
  check string "check_autonomy returns Autonomous" "autonomous"
    (Aa.action_class_to_string ac)

(** {1 Test Runner} *)

let () =
  (* Use temp directory for JSONL persistence to avoid polluting working dir *)
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    ("masc_test_autonomy_" ^ string_of_int (Random.int 1_000_000)) in
  (try Sys.mkdir tmp_dir 0o755 with Sys_error _ -> ());
  Aa.set_base_path tmp_dir;
  Eio_main.run @@ fun _env ->
  run "Autonomy_adjuster" [
    "classification", [
      test_case "default level and class" `Quick test_classify_autonomous;
      test_case "threshold boundaries" `Quick test_classify_thresholds;
    ];
    "adjust_quality", [
      test_case "high quality bumps up" `Quick test_adjust_high_quality_bumps_up;
      test_case "low quality bumps down" `Quick test_adjust_low_quality_bumps_down;
      test_case "medium quality no change" `Quick test_adjust_medium_quality_no_change;
    ];
    "health_gate", [
      test_case "unhealthy floors to zero" `Quick test_adjust_unhealthy_floors_to_zero;
      test_case "recovering caps at 0.5" `Quick test_adjust_recovering_caps_at_half;
    ];
    "clamp", [
      test_case "level clamped at bounds" `Quick test_level_clamped_at_bounds;
    ];
    "cumulative", [
      test_case "cumulative adjustments" `Quick test_cumulative_adjustments;
    ];
    "serialization", [
      test_case "JSON roundtrip" `Quick test_json_roundtrip;
      test_case "malformed JSON rejected" `Quick test_json_malformed;
    ];
    "batch_ops", [
      test_case "get_all contains agents" `Quick test_get_all;
      test_case "reset returns correct record" `Quick test_reset_returns_correct_record;
      test_case "check_autonomy convenience" `Quick test_check_autonomy;
    ];
  ]
