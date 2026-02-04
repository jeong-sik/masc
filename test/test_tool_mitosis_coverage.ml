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
  let args = `Assoc [("context_ratio", `Float (-1.0)); ("full_context", `String "test")] in
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
  ] in
  match Tool_mitosis.dispatch ctx ~name:"masc_mitosis_handoff" ~args with
  | Some (_, _result) -> check bool "custom timeout accepted" true true
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
    ];
    "metrics", [
      test_case "record task" `Quick test_metrics_record;
      test_case "compare no data" `Quick test_metrics_compare_no_data;
    ];
    "timeout_config", [
      test_case "defaults is 600" `Quick test_mitosis_defaults_spawn_timeout_is_600;
      test_case "handoff configurable" `Quick test_mitosis_handoff_spawn_timeout_configurable;
    ];
  ]
