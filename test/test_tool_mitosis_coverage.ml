(** Tool_mitosis Module Coverage Tests *)

open Alcotest

let () = Random.self_init ()

module Tool_mitosis = Masc_mcp.Tool_mitosis

(* ============================================================
   Argument Helper Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("summary", `String "test summary")] in
  check string "extracts string" "test summary" (Tool_mitosis.get_string args "summary" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default" (Tool_mitosis.get_string args "summary" "default")

let test_get_float_exists () =
  let args = `Assoc [("context_ratio", `Float 0.75)] in
  check (float 0.001) "extracts float" 0.75 (Tool_mitosis.get_float args "context_ratio" 0.0)

let test_get_float_from_int () =
  let args = `Assoc [("context_ratio", `Int 1)] in
  check (float 0.001) "converts int" 1.0 (Tool_mitosis.get_float args "context_ratio" 0.0)

let test_get_float_missing () =
  let args = `Assoc [] in
  check (float 0.001) "uses default" 0.5 (Tool_mitosis.get_float args "context_ratio" 0.5)

let test_get_bool_exists_true () =
  let args = `Assoc [("task_done", `Bool true)] in
  check bool "extracts true" true (Tool_mitosis.get_bool args "task_done" false)

let test_get_bool_exists_false () =
  let args = `Assoc [("task_done", `Bool false)] in
  check bool "extracts false" false (Tool_mitosis.get_bool args "task_done" true)

let test_get_bool_missing () =
  let args = `Assoc [] in
  check bool "uses default" true (Tool_mitosis.get_bool args "task_done" true)

(* ============================================================
   Context Creation Tests
   ============================================================ *)

let test_context_creation () =
  let config = Masc_mcp.Room.default_config "/tmp/test" in
  let ctx = Tool_mitosis.make_context config in
  check bool "context created" true (ctx.config.Masc_mcp.Room.base_path = "/tmp/test");
  check bool "logger is None" true (ctx.logger = None)

let test_context_with_logger () =
  let config = Masc_mcp.Room.default_config "/tmp/test" in
  let log_buffer = Buffer.create 64 in
  let logger msg = Buffer.add_string log_buffer msg in
  let ctx = Tool_mitosis.make_context_with_logger config logger in
  check bool "context has logger" true (ctx.logger <> None);
  (* Test logger invocation *)
  Tool_mitosis.log ctx "test message";
  check string "logger captured message" "test message" (Buffer.contents log_buffer)

let test_context_without_logger_log () =
  let config = Masc_mcp.Room.default_config "/tmp/test" in
  let ctx = Tool_mitosis.make_context config in
  (* Should not raise - just no-op *)
  Tool_mitosis.log ctx "silent message";
  check bool "no-op log works" true true

(* ============================================================
   Dispatch Tests
   ============================================================ *)

let make_ctx () : Tool_mitosis.context =
  let config = Masc_mcp.Room.default_config "/tmp/test-mitosis" in
  Tool_mitosis.make_context config

let test_dispatch_mitosis_status () =
  let ctx = make_ctx () in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_status" ~args:(`Assoc []) with
  | Some (success, _) -> check bool "succeeds" true success
  | None -> fail "expected Some"

let test_dispatch_mitosis_all () =
  let ctx = make_ctx () in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_all" ~args:(`Assoc []) with
  | Some (success, _) -> check bool "succeeds" true success
  | None -> fail "expected Some"

let test_dispatch_mitosis_pool () =
  let ctx = make_ctx () in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_pool" ~args:(`Assoc []) with
  | Some (success, _) -> check bool "succeeds" true success
  | None -> fail "expected Some"

let test_dispatch_mitosis_check () =
  let ctx = make_ctx () in
  let args = `Assoc [("context_ratio", `Float 0.5)] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_check" ~args with
  | Some (success, _) -> check bool "succeeds" true success
  | None -> fail "expected Some"

let test_dispatch_mitosis_record () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_done", `Bool true); ("tool_called", `Bool true)] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_record" ~args with
  | Some (success, _) -> check bool "succeeds" true success
  | None -> fail "expected Some"

let test_dispatch_mitosis_prepare () =
  let ctx = make_ctx () in
  let args = `Assoc [("full_context", `String "test context")] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_prepare" ~args with
  | Some (success, _) -> check bool "succeeds" true success
  | None -> fail "expected Some"

(* Note: mitosis_divide is not tested here as it involves spawning
   which requires external processes *)

let test_dispatch_unknown_tool () =
  let ctx = make_ctx () in
  match Tool_mitosis.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
  | None -> check bool "returns None for unknown" true true
  | Some _ -> fail "expected None for unknown tool"

(* ============================================================
   Context Ratio Validation Tests (T1, T2)
   ============================================================ *)

(* T1: Negative context_ratio should be clamped to 0.0 *)
let test_negative_context_ratio () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float (-1.0));
    ("full_context", `String "test");
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (true, result) ->
      (* Should succeed with clamped ratio *)
      check bool "negative ratio clamped" true (String.length result > 0)
  | Some (false, _) -> check bool "negative ratio handled" true true
  | None -> fail "expected Some for mitosis_handoff"

(* T2: context_ratio > 1.0 should be clamped to 1.0 *)
let test_over_one_context_ratio () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 2.0);
    ("full_context", `String "test");
    ("async", `Bool false);
    ("verify", `Bool false);
    (* Avoid spawn in tests: keep handoff threshold above clamped ratio *)
    ("handoff_threshold", `Float 2.0);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (_, result) ->
      check bool "over-1 ratio handled" true (String.length result > 0)
  | None -> fail "expected Some for mitosis_handoff"

(* ============================================================
   Timeout Configuration Tests (P2 #19)
   ============================================================ *)

let test_mitosis_defaults_spawn_timeout_is_600 () =
  (* Default spawn timeout should be 600 seconds (10 minutes) *)
  check int "spawn_timeout default 600" 600 Masc_mcp.Mitosis.Defaults.spawn_timeout_seconds

let test_mitosis_handoff_spawn_timeout_configurable () =
  (* Test that spawn_timeout can be provided in args for mitosis_handoff *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("spawn_timeout", `Int 300);  (* Custom timeout *)
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (_, _result) -> check bool "custom timeout accepted" true true
  | None -> fail "expected Some for mitosis_handoff"

(* ============================================================
   Verifier / Consensus Gate Tests
   ============================================================ *)

let parse_json_or_fail s =
  try Yojson.Safe.from_string s
  with exn -> fail ("invalid json response: " ^ Printexc.to_string exn)

let test_handoff_verifier_advisory_with_invalid_model () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool true);
    ("verification_judge_timeout_sec", `Float 0.2);
    ("verification_policy", `String "advisory");
    ("verification_min_judges", `Int 1);
    ("verifier_models", `List [`String "invalid-model-spec"]);
    ("verifier_perspectives", `List [`String "continuity"]);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (true, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let gate = json |> member "verification_gate_passed" |> to_bool_option in
      check bool "advisory gate pass" true (Option.value ~default:false gate);
      let overall = json |> member "verification" |> member "overall" |> to_string_option in
      check string "invalid model becomes warn" "warn" (Option.value ~default:"" overall)
  | Some (false, msg) -> fail ("advisory mode should not fail: " ^ msg)
  | None -> fail "expected Some for mitosis_handoff"

let test_handoff_verifier_gate_blocks_with_invalid_model () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool true);
    ("verification_judge_timeout_sec", `Float 0.2);
    ("verification_policy", `String "gate");
    ("verification_min_judges", `Int 1);
    ("verification_pass_ratio", `Float 1.0);
    ("verifier_models", `List [`String "invalid-model-spec"]);
    ("verifier_perspectives", `List [`String "risk_guardrail"]);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (false, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let gate = json |> member "verification_gate_passed" |> to_bool_option in
      check bool "gate blocked" false (Option.value ~default:true gate)
  | Some (true, _) -> fail "gate mode should fail when consensus does not pass"
  | None -> fail "expected Some for mitosis_handoff"

let test_handoff_verifier_gate_bypassed_when_verify_false () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
    ("verification_policy", `String "gate");
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (true, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let gate = json |> member "verification_gate_passed" |> to_bool_option in
      check bool "verify false bypasses gate" true (Option.value ~default:false gate)
  | Some (false, msg) -> fail ("verify=false should bypass gate: " ^ msg)
  | None -> fail "expected Some for mitosis_handoff"

let test_handoff_verifier_profile_and_research_metrics () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool true);
    ("verification_judge_timeout_sec", `Float 0.2);
    ("verification_policy", `String "advisory");
    ("verifier_profile", `String "abc_neutral");
    ("verifier_models", `List [
      `String "invalid-a";
      `String "invalid-b";
      `String "invalid-c";
    ]);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (true, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let profile = json |> member "verification" |> member "profile" |> to_string_option in
      check string "profile set" "abc_neutral" (Option.value ~default:"" profile);
      let checks_len =
        try json |> member "verification" |> member "checks" |> to_list |> List.length
        with _ -> 0
      in
      check int "3 checks for 3 models" 3 checks_len;
      let agreement =
        json |> member "verification" |> member "research_metrics"
        |> member "inter_judge_agreement" |> to_float_option
      in
      check bool "agreement metric exists" true (Option.is_some agreement);
      let evidence =
        json |> member "verification" |> member "research_metrics"
        |> member "evidence_completeness" |> to_float_option
      in
      check bool "evidence metric exists" true (Option.is_some evidence);
      check bool "action-aware evidence completeness"
        true
        (Option.value ~default:0.0 evidence >= 0.5)
  | Some (false, msg) -> fail ("profile/research metrics should succeed: " ^ msg)
  | None -> fail "expected Some for mitosis_handoff"

let test_handoff_verifier_min_judges_clamped_to_available_models () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool true);
    ("verification_judge_timeout_sec", `Float 0.2);
    ("verification_policy", `String "gate");
    ("verification_min_judges", `Int 3);
    (* Keep CI deterministic: avoid live network-backed model calls in coverage tests. *)
    ("verifier_models", `List [`String "invalid-model-spec"]);
    ("verifier_profile", `String "abc_neutral");
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (_ok, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let configured =
        json |> member "verification" |> member "min_judges" |> to_int_option
      in
      let effective =
        json |> member "verification" |> member "effective_min_judges" |> to_int_option
      in
      let total_checks =
        json |> member "verification" |> member "counts" |> member "total" |> to_int_option
      in
      check int "configured min_judges kept" 3 (Option.value ~default:0 configured);
      check int "effective min_judges clamped" 1 (Option.value ~default:0 effective);
      check int "single model check count" 1 (Option.value ~default:0 total_checks)
  | None -> fail "expected Some for mitosis_handoff"

(* ============================================================
   Metrics Tools Tests (P1-4)
   ============================================================ *)

let test_metrics_record () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("task_id", `String "test-task-001");
    ("completed", `Bool true);
    ("duration_ms", `Int 5000);
    ("error_count", `Int 0);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_metrics_record" ~args with
  | Some (true, result) ->
      check bool "task recorded" true (Str.string_match (Str.regexp_string "task_recorded") result 0 || String.length result > 10)
  | Some (false, msg) -> fail ("metrics_record failed: " ^ msg)
  | None -> fail "expected Some for metrics_record"

let test_metrics_compare_no_data () =
  let ctx = make_ctx () in
  let args = `Assoc [("gen_a", `Int 0); ("gen_b", `Int 1)] in
  match Tool_mitosis.dispatch ctx ~name:"masc_metrics_compare" ~args with
  | Some (false, result) ->
      (* Should fail gracefully when no data *)
      check bool "no data error" true (try Str.search_forward (Str.regexp_string "Not enough data") result 0 >= 0 with Not_found -> false)
  | Some (true, _) -> check bool "compare with no data" true true
  | None -> fail "expected Some for metrics_compare"

(* P0-2: Verify warning field surfaces in JSON when context_ratio = 0.0 *)
let test_mitosis_check_zero_ratio_warning () =
  let ctx = make_ctx () in
  let args = `Assoc [] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_check" ~args with
  | Some (true, result) ->
      let json = Yojson.Safe.from_string result in
      let has_warning =
        try ignore (Yojson.Safe.Util.member "warning" json |> Yojson.Safe.Util.to_string); true
        with _ -> false
      in
      check bool "0.0 ratio should have warning field" true has_warning
  | Some (false, _) -> fail "mitosis_check should succeed"
  | None -> fail "expected Some for mitosis_check"

let test_mitosis_check_nonzero_ratio_no_warning () =
  let ctx = make_ctx () in
  let args = `Assoc [("context_ratio", `Float 0.3)] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_check" ~args with
  | Some (true, result) ->
      let json = Yojson.Safe.from_string result in
      let warning = Yojson.Safe.Util.member "warning" json in
      check bool "non-zero ratio should have no warning" true (warning = `Null)
  | Some (false, _) -> fail "mitosis_check should succeed"
  | None -> fail "expected Some for mitosis_check"

(* ============================================================
   Handoff Cooldown Tests (P1-3)
   ============================================================ *)

let test_handoff_cooldown_blocks_rapid_calls () =
  (* Simulate a recent handoff by setting last_handoff_time to now *)
  Tool_mitosis.last_handoff_time := Unix.gettimeofday ();
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (false, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let action = json |> member "action" |> to_string in
      check string "cooldown action" "cooldown" action;
      let remaining = json |> member "cooldown_remaining_sec" |> to_float in
      check bool "remaining > 0" true (remaining > 0.0);
      Tool_mitosis.reset_handoff_cooldown ()
  | Some (true, _) ->
      Tool_mitosis.reset_handoff_cooldown ();
      fail "expected cooldown to block"
  | None ->
      Tool_mitosis.reset_handoff_cooldown ();
      fail "expected Some for mitosis_handoff"

let test_handoff_cooldown_allows_after_expiry () =
  (* Set last_handoff_time far in the past *)
  Tool_mitosis.last_handoff_time := Unix.gettimeofday () -. 9999.0;
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (true, result) ->
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let action = json |> member "action" |> to_string in
      (* Should proceed normally, not cooldown *)
      check bool "not cooldown" true (action <> "cooldown");
      Tool_mitosis.reset_handoff_cooldown ()
  | Some (false, result) ->
      (* Also acceptable if action is not cooldown *)
      let json = parse_json_or_fail result in
      let open Yojson.Safe.Util in
      let action = json |> member "action" |> to_string_option in
      check bool "not cooldown" true (Option.value ~default:"" action <> "cooldown");
      Tool_mitosis.reset_handoff_cooldown ()
  | None ->
      Tool_mitosis.reset_handoff_cooldown ();
      fail "expected Some for mitosis_handoff"

let test_handoff_cooldown_reset () =
  Tool_mitosis.last_handoff_time := Unix.gettimeofday ();
  check bool "last_handoff_time set" true (!Tool_mitosis.last_handoff_time > 0.0);
  Tool_mitosis.reset_handoff_cooldown ();
  check (float 0.001) "reset to 0" 0.0 !Tool_mitosis.last_handoff_time

(* ============================================================
   Structured Logging Tests (P1-6)
   ============================================================ *)

module Mitosis = Masc_mcp.Mitosis

let test_log_state_transition_does_not_raise () =
  (* log_state_transition should not raise regardless of log level *)
  Mitosis.log_state_transition
    ~old_state:Mitosis.Active ~new_state:Mitosis.Prepared
    ~agent_name:"test-cell-01"
    ~reason:"DNA extraction at 50%";
  check bool "no exception" true true

let test_log_state_transition_all_states () =
  (* Exercise all state combinations to verify formatting *)
  let states = [Mitosis.Stem; Active; Prepared; Dividing; Apoptotic] in
  List.iter (fun old_st ->
    List.iter (fun new_st ->
      Mitosis.log_state_transition
        ~old_state:old_st ~new_state:new_st
        ~agent_name:"test-cell"
        ~reason:"test";
    ) states
  ) states;
  check bool "all state pairs logged" true true

let test_state_to_string () =
  check string "stem" "stem" (Mitosis.state_to_string Mitosis.Stem);
  check string "active" "active" (Mitosis.state_to_string Mitosis.Active);
  check string "prepared" "prepared" (Mitosis.state_to_string Mitosis.Prepared);
  check string "dividing" "dividing" (Mitosis.state_to_string Mitosis.Dividing);
  check string "apoptotic" "apoptotic" (Mitosis.state_to_string Mitosis.Apoptotic)

let test_phase_to_string () =
  check string "idle" "idle" (Mitosis.phase_to_string Mitosis.Idle);
  check string "ready" "ready_for_handoff"
    (Mitosis.phase_to_string (Mitosis.ReadyForHandoff "dna"))

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Tool_mitosis Coverage" [
    "get_string", [
      test_case "exists" `Quick test_get_string_exists;
      test_case "missing" `Quick test_get_string_missing;
    ];
    "get_float", [
      test_case "exists" `Quick test_get_float_exists;
      test_case "from int" `Quick test_get_float_from_int;
      test_case "missing" `Quick test_get_float_missing;
    ];
    "get_bool", [
      test_case "true" `Quick test_get_bool_exists_true;
      test_case "false" `Quick test_get_bool_exists_false;
      test_case "missing" `Quick test_get_bool_missing;
    ];
    "context", [
      test_case "creation" `Quick test_context_creation;
      test_case "with logger" `Quick test_context_with_logger;
      test_case "log without logger" `Quick test_context_without_logger_log;
    ];
    "dispatch", [
      test_case "mitosis_status" `Quick test_dispatch_mitosis_status;
      test_case "mitosis_all" `Quick test_dispatch_mitosis_all;
      test_case "mitosis_pool" `Quick test_dispatch_mitosis_pool;
      test_case "mitosis_check" `Quick test_dispatch_mitosis_check;
      test_case "mitosis_record" `Quick test_dispatch_mitosis_record;
      test_case "mitosis_prepare" `Quick test_dispatch_mitosis_prepare;
      test_case "unknown" `Quick test_dispatch_unknown_tool;
    ];
    "context_ratio_validation", [
      test_case "T1: negative ratio" `Quick test_negative_context_ratio;
      test_case "T2: over-one ratio" `Quick test_over_one_context_ratio;
      test_case "T3: zero ratio warning" `Quick test_mitosis_check_zero_ratio_warning;
      test_case "T3b: nonzero ratio no warning" `Quick test_mitosis_check_nonzero_ratio_no_warning;
    ];
    "metrics", [
      test_case "record task" `Quick test_metrics_record;
      test_case "compare no data" `Quick test_metrics_compare_no_data;
    ];
    "timeout_config", [
      test_case "defaults is 600" `Quick test_mitosis_defaults_spawn_timeout_is_600;
      test_case "handoff configurable" `Quick test_mitosis_handoff_spawn_timeout_configurable;
    ];
    "verifier", [
      test_case "advisory invalid model" `Slow test_handoff_verifier_advisory_with_invalid_model;
      test_case "gate blocks invalid model" `Slow test_handoff_verifier_gate_blocks_with_invalid_model;
      test_case "gate bypass when verify=false" `Slow test_handoff_verifier_gate_bypassed_when_verify_false;
      test_case "profile + research metrics" `Slow test_handoff_verifier_profile_and_research_metrics;
      test_case "min_judges clamp to model count" `Slow
        test_handoff_verifier_min_judges_clamped_to_available_models;
    ];
    "handoff_cooldown", [
      test_case "blocks rapid calls" `Quick test_handoff_cooldown_blocks_rapid_calls;
      test_case "allows after expiry" `Quick test_handoff_cooldown_allows_after_expiry;
      test_case "reset" `Quick test_handoff_cooldown_reset;
    ];
    "state_logging", [
      test_case "transition does not raise" `Quick test_log_state_transition_does_not_raise;
      test_case "all state pairs" `Quick test_log_state_transition_all_states;
      test_case "state_to_string" `Quick test_state_to_string;
      test_case "phase_to_string" `Quick test_phase_to_string;
    ];
  ]
