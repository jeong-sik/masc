(** Tool_mitosis Module Coverage Tests *)

open Alcotest

let () = Random.self_init ()

module Tool_mitosis = Masc_mcp.Tool_mitosis
module Tool_args = Masc_mcp.Tool_args

(* ============================================================
   Argument Helper Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("summary", `String "test summary")] in
  check string "extracts string" "test summary" (Tool_args.get_string args "summary" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default" (Tool_args.get_string args "summary" "default")

let test_get_float_exists () =
  let args = `Assoc [("context_ratio", `Float 0.75)] in
  check (float 0.001) "extracts float" 0.75 (Tool_args.get_float args "context_ratio" 0.0)

let test_get_float_from_int () =
  let args = `Assoc [("context_ratio", `Int 1)] in
  check (float 0.001) "converts int" 1.0 (Tool_args.get_float args "context_ratio" 0.0)

let test_get_float_missing () =
  let args = `Assoc [] in
  check (float 0.001) "uses default" 0.5 (Tool_args.get_float args "context_ratio" 0.5)

let test_get_bool_exists_true () =
  let args = `Assoc [("task_done", `Bool true)] in
  check bool "extracts true" true (Tool_args.get_bool args "task_done" false)

let test_get_bool_exists_false () =
  let args = `Assoc [("task_done", `Bool false)] in
  check bool "extracts false" false (Tool_args.get_bool args "task_done" true)

let test_get_bool_missing () =
  let args = `Assoc [] in
  check bool "uses default" true (Tool_args.get_bool args "task_done" true)

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
  ()

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

let test_dispatch_mitosis_handoff_rejects_bare_ollama_target () =
  let ctx = make_ctx () in
  let args =
    `Assoc
      [
        ("context_ratio", `Float 0.9);
        ("full_context", `String "test context");
        ("target_agent", `String "ollama");
        ("async", `Bool false);
        ("verify", `Bool false);
      ]
  in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (false, result) ->
      check bool "migration message" true
        (try
           let _ =
             Str.search_forward
               (Str.regexp_string "llama:<model>")
               result 0
           in
           true
         with Not_found -> false)
  | Some (true, _) -> fail "expected bare ollama target to be rejected"
  | None -> fail "expected Some"

(* Note: mitosis_divide is not tested here as it involves spawning
   which requires external processes *)

let test_dispatch_unknown_tool () =
  let ctx = make_ctx () in
  match Tool_mitosis.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
  | None -> ()
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
  | Some (false, _) -> ()
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
  | Some (_, _result) -> ()
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
  | Some (true, _) -> ()
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
  ()

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
  ()

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
   DNA Validation Tests (P1-7)
   ============================================================ *)

let test_validate_dna_too_short () =
  match Tool_mitosis.validate_dna "short" with
  | Error msg -> check bool "mentions too short" true
      (try Str.search_forward (Str.regexp_string "too short") msg 0 >= 0 with Not_found -> false)
  | Ok _ -> fail "expected Error for short DNA"

let test_validate_dna_no_markers () =
  (* 60 chars, no goal/task/objective/context markers *)
  let dna = "This is a long enough string with plenty of characters here- but no markers" in
  match Tool_mitosis.validate_dna dna with
  | Error msg -> check bool "mentions markers" true
      (try Str.search_forward (Str.regexp_string "markers") msg 0 >= 0 with Not_found -> false)
  | Ok _ -> fail "expected Error for DNA without markers"

let test_validate_dna_mostly_whitespace () =
  (* Build a string that's >50% whitespace but has markers and structure *)
  let dna = "goal: test\n" ^ String.make 100 ' ' ^ "something" in
  match Tool_mitosis.validate_dna dna with
  | Error msg -> check bool "mentions whitespace" true
      (try Str.search_forward (Str.regexp_string "whitespace") msg 0 >= 0 with Not_found -> false)
  | Ok _ -> fail "expected Error for mostly-whitespace DNA"

let test_validate_dna_no_structure () =
  (* Has markers, not too short, not mostly whitespace, but no structural markers *)
  let dna = "This goal has enough content and no excessive whitespace padding text here ok" in
  match Tool_mitosis.validate_dna dna with
  | Error msg -> check bool "mentions structure" true
      (try Str.search_forward (Str.regexp_string "structure") msg 0 >= 0 with Not_found -> false)
  | Ok _ -> fail "expected Error for unstructured DNA"

let test_validate_dna_valid () =
  let dna = "## Goal\n- Complete the task objective\n- Context: migration project\n- Handle edge cases" in
  match Tool_mitosis.validate_dna dna with
  | Ok validated -> check string "returns dna" dna validated
  | Error msg -> fail ("expected Ok for valid DNA: " ^ msg)

let test_validate_dna_case_insensitive_markers () =
  let dna = "## OBJECTIVE\n- First item\n- Second item with enough content to pass length check" in
  match Tool_mitosis.validate_dna dna with
  | Ok _ -> ()
  | Error msg -> fail ("case-insensitive marker should pass: " ^ msg)

(* ============================================================
   T4: DNA Extraction with Empty Context
   ============================================================ *)

module Gen_metrics = Masc_mcp.Generational_metrics

let make_active_cell ?(generation = 0) ?(task_count = 3) ?(tool_call_count = 10) () =
  let base = Mitosis.create_stem_cell ~generation in
  { base with
    Mitosis.state = Mitosis.Active;
    phase = Mitosis.Idle;
    task_count;
    tool_call_count;
  }

let test_extract_dna_empty_context () =
  let config = Mitosis.default_config in
  let parent = make_active_cell () in
  let dna = Mitosis.extract_dna ~config ~parent_cell:parent ~full_context:"" in
  (* Should produce a header with generation info even for empty context *)
  check bool "non-empty DNA from empty context" true (String.length dna > 0);
  (* Header should contain generation info *)
  check bool "contains generation" true
    (try Str.search_forward (Str.regexp_string "Generation 0") dna 0 >= 0
     with Not_found -> false)

let test_extract_dna_empty_context_compress () =
  (* compress_to_dna with empty string should return empty *)
  let result = Mitosis.compress_to_dna ~ratio:0.1 ~context:"" in
  check string "empty context compresses to empty" "" result

let test_extract_dna_empty_context_validate () =
  (* validate_dna on empty-context DNA (header only, no markers from context) *)
  let config = Mitosis.default_config in
  let parent = make_active_cell () in
  let dna = Mitosis.extract_dna ~config ~parent_cell:parent ~full_context:"" in
  (* The header itself may or may not pass validation depending on markers *)
  match Tool_mitosis.validate_dna dna with
  | Ok _ -> ()
  | Error _ -> ()

let test_prepare_for_division_empty_context () =
  let config = Mitosis.default_config in
  let cell = make_active_cell () in
  let prepared = Mitosis.prepare_for_division ~config ~cell ~full_context:"" in
  check string "state is Prepared" "prepared" (Mitosis.state_to_string prepared.state);
  check string "phase is ready_for_handoff" "ready_for_handoff" (Mitosis.phase_to_string prepared.phase);
  check bool "prepared_dna is Some" true (Option.is_some prepared.prepared_dna)

let test_extract_dna_single_char_context () =
  let config = Mitosis.default_config in
  let parent = make_active_cell () in
  let dna = Mitosis.extract_dna ~config ~parent_cell:parent ~full_context:"x" in
  check bool "single char context produces DNA" true (String.length dna > 0)

(* ============================================================
   T5: Concurrent Handoff / Cooldown Edge Cases
   ============================================================ *)

let test_cooldown_at_exact_boundary () =
  (* Set last_handoff_time to exactly cooldown seconds ago *)
  let cooldown = Masc_mcp.Env_config.Mitosis.handoff_cooldown_seconds in
  Tool_mitosis.last_handoff_time := Unix.gettimeofday () -. cooldown;
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  (match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
   | Some (_, result) ->
       let json = parse_json_or_fail result in
       let open Yojson.Safe.Util in
       let action = json |> member "action" |> to_string in
       (* At exact boundary, should proceed (elapsed >= cooldown) *)
       check bool "at boundary allows handoff" true (action <> "cooldown");
       Tool_mitosis.reset_handoff_cooldown ()
   | None ->
       Tool_mitosis.reset_handoff_cooldown ();
       fail "expected Some for mitosis_handoff")

let test_cooldown_just_inside_boundary () =
  (* Set last_handoff_time to 1 second less than cooldown ago *)
  let cooldown = Masc_mcp.Env_config.Mitosis.handoff_cooldown_seconds in
  Tool_mitosis.last_handoff_time := Unix.gettimeofday () -. (cooldown -. 1.0);
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  (match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
   | Some (false, result) ->
       let json = parse_json_or_fail result in
       let open Yojson.Safe.Util in
       let action = json |> member "action" |> to_string in
       check string "just inside boundary blocks" "cooldown" action;
       let remaining = json |> member "cooldown_remaining_sec" |> to_float in
       (* Remaining should be approximately 1 second *)
       check bool "remaining near 1s" true (remaining > 0.0 && remaining <= 2.0);
       Tool_mitosis.reset_handoff_cooldown ()
   | Some (true, _) ->
       Tool_mitosis.reset_handoff_cooldown ();
       fail "expected cooldown block just inside boundary"
   | None ->
       Tool_mitosis.reset_handoff_cooldown ();
       fail "expected Some for mitosis_handoff")

let test_cooldown_first_handoff_no_block () =
  (* First handoff ever (last_handoff_time = 0.0) should not be blocked *)
  Tool_mitosis.reset_handoff_cooldown ();
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  (match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
   | Some (_, result) ->
       let json = parse_json_or_fail result in
       let open Yojson.Safe.Util in
       let action = json |> member "action" |> to_string in
       check bool "first handoff not blocked" true (action <> "cooldown");
       Tool_mitosis.reset_handoff_cooldown ()
   | None ->
       Tool_mitosis.reset_handoff_cooldown ();
       fail "expected Some for mitosis_handoff")

let test_cooldown_json_contains_total_sec () =
  (* Verify the cooldown JSON has the cooldown_total_sec field *)
  Tool_mitosis.last_handoff_time := Unix.gettimeofday ();
  let ctx = make_ctx () in
  let args = `Assoc [
    ("context_ratio", `Float 0.3);
    ("async", `Bool false);
    ("verify", `Bool false);
  ] in
  (match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
   | Some (false, result) ->
       let json = parse_json_or_fail result in
       let open Yojson.Safe.Util in
       let total = json |> member "cooldown_total_sec" |> to_float in
       let expected_cooldown = Masc_mcp.Env_config.Mitosis.handoff_cooldown_seconds in
       check (float 0.001) "total_sec matches config" expected_cooldown total;
       Tool_mitosis.reset_handoff_cooldown ()
   | Some (true, _) ->
       Tool_mitosis.reset_handoff_cooldown ();
       fail "expected cooldown block"
   | None ->
       Tool_mitosis.reset_handoff_cooldown ();
       fail "expected Some for mitosis_handoff")

(* ============================================================
   T6: Generation Overflow (>10)
   ============================================================ *)

let test_max_generation_default () =
  check int "max generation is 10" 10 Mitosis.Defaults.max_generation

let test_high_generation_cell_creation () =
  (* Creating a cell with generation > max should not crash *)
  let cell = Mitosis.create_stem_cell ~generation:100 in
  check int "generation 100" 100 cell.generation;
  check string "state is stem" "stem" (Mitosis.state_to_string cell.state)

let test_very_high_generation_cell () =
  let cell = Mitosis.create_stem_cell ~generation:1000 in
  check int "generation 1000" 1000 cell.generation;
  let json = Mitosis.cell_to_json cell in
  match json with
  | `Assoc fields ->
      let gen = List.assoc "generation" fields in
      check bool "json has gen 1000" true (gen = `Int 1000)
  | _ -> fail "expected Assoc"

let test_emergency_generation_value () =
  check int "emergency gen is 999" 999 Mitosis.Defaults.emergency_generation

let test_perform_mitosis_increments_generation () =
  let config = Mitosis.default_config in
  let parent = make_active_cell ~generation:5 () in
  let pool = Mitosis.init_pool ~config in
  let full_context = "Goal: test\n- Context for generation test\n- More lines here" in
  let (child, _parent, _pool, _dna) =
    Mitosis.perform_mitosis ~config ~pool ~parent ~full_context
  in
  check int "child generation is parent + 1" 6 child.generation

let test_pool_to_json_high_generation () =
  let config = { Mitosis.default_config with stem_pool_size = 1 } in
  let pool = Mitosis.init_pool ~config in
  let json = Mitosis.pool_to_json pool in
  match json with
  | `Assoc fields ->
      let stem_count =
        match List.assoc "stem_count" fields with
        | `Int n -> n
        | _ -> -1
      in
      check bool "pool has stems" true (stem_count >= 0)
  | _ -> fail "expected Assoc from pool_to_json"

(* ============================================================
   T7: Full Lifecycle — prepare -> handoff state transitions
   ============================================================ *)

let test_lifecycle_stem_to_active () =
  let cell = Mitosis.create_stem_cell ~generation:0 in
  check string "starts as stem" "stem" (Mitosis.state_to_string cell.state);
  (* Simulate activation by setting state *)
  let active = { cell with Mitosis.state = Active; phase = Idle } in
  check string "activated" "active" (Mitosis.state_to_string active.state)

let test_lifecycle_active_to_prepared () =
  let config = Mitosis.default_config in
  let cell = make_active_cell () in
  let context = "Goal: complete lifecycle test\n- Task: verify state transitions\n- Context: test harness" in
  let prepared = Mitosis.prepare_for_division ~config ~cell ~full_context:context in
  check string "prepared state" "prepared" (Mitosis.state_to_string prepared.state);
  check string "prepared phase" "ready_for_handoff" (Mitosis.phase_to_string prepared.phase);
  check bool "has prepared DNA" true (Option.is_some prepared.prepared_dna);
  check bool "prepare_context_len set" true (prepared.prepare_context_len > 0)

let test_lifecycle_prepared_to_dividing_to_apoptotic () =
  let config = Mitosis.default_config in
  let cell = make_active_cell ~generation:1 () in
  let context = "Goal: full lifecycle\n- Task: division test\n- Context: state machine verification" in
  (* Phase 1: Prepare *)
  let prepared = Mitosis.prepare_for_division ~config ~cell ~full_context:context in
  check string "after prepare" "prepared" (Mitosis.state_to_string prepared.state);
  (* Phase 2: perform_mitosis (which moves parent to Apoptotic) *)
  let pool = Mitosis.init_pool ~config in
  let (child, dying_parent, _new_pool, dna) =
    Mitosis.perform_mitosis ~config ~pool ~parent:prepared ~full_context:context
  in
  check string "parent is apoptotic" "apoptotic" (Mitosis.state_to_string dying_parent.state);
  check string "child is active" "active" (Mitosis.state_to_string child.state);
  check int "child gen is parent+1" 2 child.generation;
  check bool "DNA produced" true (String.length dna > 0);
  (* Phase 3: Complete apoptosis *)
  let death_result = Mitosis.complete_apoptosis dying_parent in
  check bool "apoptosis completes" true (death_result = `Dead)

let test_lifecycle_should_prepare_triggers () =
  let config = Mitosis.default_config in
  let cell = make_active_cell () in
  (* Below prepare threshold: should not prepare *)
  let no_prepare = Mitosis.should_prepare ~config ~cell ~context_ratio:0.3 in
  check bool "0.3 ratio: no prepare" false no_prepare;
  (* At prepare threshold: should prepare *)
  let do_prepare = Mitosis.should_prepare ~config ~cell ~context_ratio:0.5 in
  check bool "0.5 ratio: prepare" true do_prepare;
  (* Above prepare threshold: should prepare *)
  let do_prepare2 = Mitosis.should_prepare ~config ~cell ~context_ratio:0.7 in
  check bool "0.7 ratio: prepare" true do_prepare2

let test_lifecycle_should_handoff_triggers () =
  let config = Mitosis.default_config in
  let cell = make_active_cell () in
  (* Below handoff threshold: should not handoff *)
  let no_handoff = Mitosis.should_handoff ~config ~cell ~context_ratio:0.7 in
  check bool "0.7 ratio: no handoff" false no_handoff;
  (* At handoff threshold: should handoff *)
  let do_handoff = Mitosis.should_handoff ~config ~cell ~context_ratio:0.8 in
  check bool "0.8 ratio: handoff" true do_handoff

let test_lifecycle_prepared_cell_skips_re_prepare () =
  let config = Mitosis.default_config in
  let cell = make_active_cell () in
  let context = "Goal: test no re-prepare\n- Task: check phase guard\n- Context: important" in
  let prepared = Mitosis.prepare_for_division ~config ~cell ~full_context:context in
  (* A prepared cell should not trigger should_prepare again *)
  let no_re_prepare = Mitosis.should_prepare ~config ~cell:prepared ~context_ratio:0.6 in
  check bool "prepared cell skips re-prepare" false no_re_prepare

(* ============================================================
   T8: Metrics Recording Accuracy
   ============================================================ *)

let test_metrics_record_stores_correctly () =
  Gen_metrics.reset ();
  let record = Gen_metrics.record_task
    ~generation:0 ~task_id:"t8-001" ~completed:true
    ~duration_ms:5000 ~error_count:0
    ~input_tokens:100 ~output_tokens:200
  in
  check int "generation 0" 0 record.generation;
  check string "task_id" "t8-001" record.task_id;
  check bool "completed" true record.completed;
  check int "duration" 5000 record.duration_ms;
  check int "errors" 0 record.error_count

let test_metrics_summarize_single_generation () =
  Gen_metrics.reset ();
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"s-001" ~completed:true
    ~duration_ms:1000 ~error_count:0
    ~input_tokens:50 ~output_tokens:100);
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"s-002" ~completed:true
    ~duration_ms:3000 ~error_count:1
    ~input_tokens:80 ~output_tokens:150);
  match Gen_metrics.summarize_generation 0 with
  | None -> fail "expected Some for summarize"
  | Some summary ->
      check int "total tasks" 2 summary.total_tasks;
      check int "completed tasks" 2 summary.completed_tasks;
      check int "total errors" 1 summary.total_errors;
      check (float 0.1) "avg duration" 2000.0 summary.avg_duration_ms;
      check int "input tokens" 130 summary.total_input_tokens;
      check int "output tokens" 250 summary.total_output_tokens

let test_metrics_compare_two_generations () =
  Gen_metrics.reset ();
  (* Gen 0: 2 tasks, 1 completed, 2 errors, slow *)
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"c0-001" ~completed:true
    ~duration_ms:5000 ~error_count:1
    ~input_tokens:200 ~output_tokens:300);
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"c0-002" ~completed:false
    ~duration_ms:3000 ~error_count:1
    ~input_tokens:100 ~output_tokens:200);
  (* Gen 1: 2 tasks, 2 completed, 0 errors, faster *)
  ignore (Gen_metrics.record_task
    ~generation:1 ~task_id:"c1-001" ~completed:true
    ~duration_ms:2000 ~error_count:0
    ~input_tokens:80 ~output_tokens:120);
  ignore (Gen_metrics.record_task
    ~generation:1 ~task_id:"c1-002" ~completed:true
    ~duration_ms:1000 ~error_count:0
    ~input_tokens:60 ~output_tokens:80);
  match Gen_metrics.compare_generations 0 1 with
  | None -> fail "expected comparison result"
  | Some comp ->
      check int "gen_a" 0 comp.gen_a;
      check int "gen_b" 1 comp.gen_b;
      (* Gen 1 has better completion rate *)
      check bool "positive completion delta" true (comp.completion_delta > 0.0);
      (* Gen 1 has fewer errors *)
      check bool "negative error delta" true (comp.error_delta < 0.0);
      (* Gen 1 is faster *)
      check bool "negative duration delta" true (comp.duration_delta < 0.0);
      (* Verdict should be improved (3+ improvements) *)
      check string "verdict" "improved" comp.verdict

let test_metrics_compare_missing_generation () =
  Gen_metrics.reset ();
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"m-001" ~completed:true
    ~duration_ms:1000 ~error_count:0
    ~input_tokens:50 ~output_tokens:100);
  (* Gen 5 has no data *)
  let result = Gen_metrics.compare_generations 0 5 in
  check bool "missing gen returns None" true (result = None)

let test_metrics_handoff_record () =
  Gen_metrics.reset ();
  let record = Gen_metrics.record_handoff
    ~from_generation:0 ~to_generation:1
    ~dna_size:5000 ~context_ratio:0.85
  in
  check int "from gen" 0 record.from_generation;
  check int "to gen" 1 record.to_generation;
  check int "dna size" 5000 record.dna_size;
  check (float 0.001) "context ratio" 0.85 record.context_ratio

let test_metrics_format_comparison () =
  Gen_metrics.reset ();
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"f-001" ~completed:true
    ~duration_ms:1000 ~error_count:0
    ~input_tokens:50 ~output_tokens:100);
  ignore (Gen_metrics.record_task
    ~generation:1 ~task_id:"f-002" ~completed:true
    ~duration_ms:500 ~error_count:0
    ~input_tokens:30 ~output_tokens:60);
  match Gen_metrics.compare_generations 0 1 with
  | None -> fail "expected comparison"
  | Some comp ->
      let formatted = Gen_metrics.format_comparison comp in
      check bool "contains Gen 0" true
        (try Str.search_forward (Str.regexp_string "Gen 0") formatted 0 >= 0
         with Not_found -> false);
      check bool "contains Gen 1" true
        (try Str.search_forward (Str.regexp_string "Gen 1") formatted 0 >= 0
         with Not_found -> false);
      check bool "contains Verdict" true
        (try Str.search_forward (Str.regexp_string "Verdict") formatted 0 >= 0
         with Not_found -> false)

let test_metrics_to_json () =
  Gen_metrics.reset ();
  ignore (Gen_metrics.record_task
    ~generation:0 ~task_id:"j-001" ~completed:true
    ~duration_ms:1000 ~error_count:0
    ~input_tokens:50 ~output_tokens:100);
  ignore (Gen_metrics.record_handoff
    ~from_generation:0 ~to_generation:1
    ~dna_size:3000 ~context_ratio:0.8);
  let json = Gen_metrics.to_json () in
  match json with
  | `Assoc fields ->
      let tasks = List.assoc "tasks" fields in
      let handoffs = List.assoc "handoffs" fields in
      (match tasks with
       | `List ts -> check bool "has tasks" true (List.length ts > 0)
       | _ -> fail "expected task list");
      (match handoffs with
       | `List hs -> check bool "has handoffs" true (List.length hs > 0)
       | _ -> fail "expected handoff list")
  | _ -> fail "expected Assoc from to_json"

let test_metrics_retention_test () =
  Gen_metrics.reset ();
  let record = Gen_metrics.record_retention_test
    ~generation:1
    ~question:"What is the goal?"
    ~expected:"migration"
    ~actual:"migration"
    ~confidence:0.95
  in
  check bool "correct" true record.correct;
  check (float 0.01) "confidence" 0.95 record.confidence;
  (* Now check it affects summary *)
  ignore (Gen_metrics.record_task
    ~generation:1 ~task_id:"r-001" ~completed:true
    ~duration_ms:1000 ~error_count:0
    ~input_tokens:50 ~output_tokens:100);
  match Gen_metrics.summarize_generation 1 with
  | None -> fail "expected summary"
  | Some summary ->
      check bool "has retention" true (Option.is_some summary.knowledge_retention);
      check (float 0.01) "retention is 1.0" 1.0 (Option.get summary.knowledge_retention)

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
      test_case "mitosis_handoff rejects bare ollama target" `Quick
        test_dispatch_mitosis_handoff_rejects_bare_ollama_target;
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
    "dna_validation", [
      test_case "too short" `Quick test_validate_dna_too_short;
      test_case "no markers" `Quick test_validate_dna_no_markers;
      test_case "mostly whitespace" `Quick test_validate_dna_mostly_whitespace;
      test_case "no structure" `Quick test_validate_dna_no_structure;
      test_case "valid DNA" `Quick test_validate_dna_valid;
      test_case "case-insensitive markers" `Quick test_validate_dna_case_insensitive_markers;
    ];
    "T4_dna_empty_context", [
      test_case "extract DNA from empty context" `Quick test_extract_dna_empty_context;
      test_case "compress empty context" `Quick test_extract_dna_empty_context_compress;
      test_case "validate empty-context DNA" `Quick test_extract_dna_empty_context_validate;
      test_case "prepare with empty context" `Quick test_prepare_for_division_empty_context;
      test_case "single char context" `Quick test_extract_dna_single_char_context;
    ];
    "T5_cooldown_edge_cases", [
      test_case "exact boundary allows" `Quick test_cooldown_at_exact_boundary;
      test_case "just inside blocks" `Quick test_cooldown_just_inside_boundary;
      test_case "first handoff no block" `Quick test_cooldown_first_handoff_no_block;
      test_case "cooldown JSON total_sec" `Quick test_cooldown_json_contains_total_sec;
    ];
    "T6_generation_overflow", [
      test_case "max generation default" `Quick test_max_generation_default;
      test_case "high generation cell" `Quick test_high_generation_cell_creation;
      test_case "very high generation" `Quick test_very_high_generation_cell;
      test_case "emergency generation" `Quick test_emergency_generation_value;
      test_case "mitosis increments gen" `Quick test_perform_mitosis_increments_generation;
      test_case "pool JSON high gen" `Quick test_pool_to_json_high_generation;
    ];
    "T7_lifecycle", [
      test_case "stem to active" `Quick test_lifecycle_stem_to_active;
      test_case "active to prepared" `Quick test_lifecycle_active_to_prepared;
      test_case "prepared to dividing to apoptotic" `Quick test_lifecycle_prepared_to_dividing_to_apoptotic;
      test_case "should_prepare triggers" `Quick test_lifecycle_should_prepare_triggers;
      test_case "should_handoff triggers" `Quick test_lifecycle_should_handoff_triggers;
      test_case "prepared skips re-prepare" `Quick test_lifecycle_prepared_cell_skips_re_prepare;
    ];
    "T8_metrics_accuracy", [
      test_case "record stores correctly" `Quick test_metrics_record_stores_correctly;
      test_case "summarize generation" `Quick test_metrics_summarize_single_generation;
      test_case "compare two generations" `Quick test_metrics_compare_two_generations;
      test_case "missing generation" `Quick test_metrics_compare_missing_generation;
      test_case "handoff record" `Quick test_metrics_handoff_record;
      test_case "format comparison" `Quick test_metrics_format_comparison;
      test_case "to_json" `Quick test_metrics_to_json;
      test_case "retention test" `Quick test_metrics_retention_test;
    ];
  ]
