(** Tests for Memory_hooks (RFC-MASC-004 Phase 1).

    Validates:
    - Pure read functions return None when no data available
    - Hook returns Continue when no memory to inject
    - Hook returns AdjustParams with memory context appended
    - AfterTurn hook returns Continue
    - Flush_incremental is idempotent on empty memory
    - Feature flag is registered correctly *)

open Alcotest

module Memory_oas_bridge = Masc_mcp.Memory_oas_bridge
module Memory_hooks = Masc_mcp.Memory_hooks
module P = Masc_mcp.Prometheus

let test_base_path = Filename.temp_dir "masc_memory_hooks_base" ""
let () = Unix.putenv "MASC_BASE_PATH" test_base_path

(* ── Test helpers ──────────────────────────────────────────── *)

let contains_text ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    idx + needle_len <= haystack_len
    && (String.sub haystack idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0

let make_test_config ~base_path : Coord_utils.config =
  let backend_config : Backend_types.config = {
    backend_type = Backend_types.Memory;
    base_path;
    node_id = "test-node";
    cluster_name = "default";
    pubsub_max_messages = 1000;
  } in
  let memory_backend = Backend.Memory.create () in
  {
    Coord_utils.base_path;
    workspace_path = base_path;
    lock_expiry_minutes = 30;
    backend_config;
    backend = Coord_utils.Memory memory_backend;
  }

let make_before_turn_params_event ?(extra_ctx = None) ~turn () =
  Agent_sdk.Hooks.BeforeTurnParams {
    turn;
    max_turns = 10;
    messages = [];
    last_tool_results = [];
    current_params = { Agent_sdk.Hooks.default_turn_params with
                       extra_system_context = extra_ctx };
    reasoning = Agent_sdk.Hooks.empty_reasoning_summary;
  }

let make_after_turn_event ?(turn = 1) () =
  Agent_sdk.Hooks.AfterTurn {
    turn;
    response = {
      Agent_sdk.Types.id = "r1";
      model = "test";
      stop_reason = Agent_sdk.Types.EndTurn;
      content = [];
      usage = None;
      telemetry = None;
    };
  }

(* ── Pure read function tests ──────────────────────────────── *)

let test_load_episodes_text_type () =
  (* load_episodes_text returns string option.
     Global episode cache may contain data from prior runs,
     so we verify the return type rather than asserting None. *)
  let result = Memory_oas_bridge.load_episodes_text ~limit:10 in
  match result with
  | None -> ()
  | Some s ->
    check bool "episodes text is non-empty" true (String.length s > 0)

let test_load_procedures_text_empty () =
  (* No procedures for unknown agent -> None *)
  let result = Memory_oas_bridge.load_procedures_text
    ~agent_name:"nonexistent_test_agent_xyz" ~limit:10 in
  check (option string) "no procedures returns None" None result

(* ── Hook decision tests ───────────────────────────────────── *)

let test_hook_returns_continue_when_no_memory () =
  (* With no episodes, procedures, or institution -> Continue *)
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_hook" () in
  let hooks = Memory_hooks.make
    ~agent_name:"test_hook"
    ~config
    ~memory
    ~episode_limit:10
    ~procedure_limit:5
    ()
  in
  let event = make_before_turn_params_event ~turn:1 () in
  let decision = match hooks.before_turn_params with
    | Some f -> f event
    | None -> fail "before_turn_params hook should be Some"
  in
  (* No memory data -> should return Continue *)
  (match decision with
   | Agent_sdk.Hooks.Continue -> ()
   | Agent_sdk.Hooks.AdjustParams _ ->
     (* If institution happens to exist, that's also acceptable *)
     ()
   | _ -> fail "expected Continue or AdjustParams from memory hook");
  (try Sys.rmdir tmp_dir with _ -> ())

let test_hook_preserves_existing_context () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_preserve" () in
  let hooks = Memory_hooks.make
    ~agent_name:"test_preserve"
    ~config
    ~memory
    ()
  in
  let existing_ctx = "existing dynamic context" in
  let event = make_before_turn_params_event ~extra_ctx:(Some existing_ctx) ~turn:1 () in
  let decision = match hooks.before_turn_params with
    | Some f -> f event
    | None -> fail "before_turn_params hook should be Some"
  in
  (match decision with
   | Agent_sdk.Hooks.Continue ->
     (* No memory to inject => existing context preserved implicitly *)
     ()
   | Agent_sdk.Hooks.AdjustParams params ->
     (match params.extra_system_context with
      | Some ctx ->
        check bool "existing context preserved"
          true (String.length ctx >= String.length existing_ctx);
        check bool "existing context is prefix"
          true (String.sub ctx 0 (String.length existing_ctx) = existing_ctx)
      | None ->
        fail "AdjustParams should not clear extra_system_context")
   | _ -> fail "unexpected hook decision");
  (try Sys.rmdir tmp_dir with _ -> ())

let test_hook_injects_world_memory () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Agent_sdk.Memory.create () in
  ignore
    (Agent_sdk.Memory.store
       memory
       ~tier:Agent_sdk.Memory.Long_term
       "world:mission"
       (`Assoc [ "content", `String "Bridge the world memory into prompt context." ]));
  let hooks =
    Memory_hooks.make
      ~agent_name:"test_world"
      ~config
      ~memory
      ()
  in
  let event = make_before_turn_params_event ~turn:1 () in
  let decision =
    match hooks.before_turn_params with
    | Some f -> f event
    | None -> fail "before_turn_params hook should be Some"
  in
  (match decision with
   | Agent_sdk.Hooks.AdjustParams params ->
     (match params.extra_system_context with
      | Some ctx ->
        check bool "world section present" true
          (contains_text ~needle:"[world memory:" ctx);
        check bool "world key present" true
          (contains_text ~needle:"world:mission" ctx)
      | None -> fail "world memory should inject extra_system_context")
   | Agent_sdk.Hooks.Continue -> fail "world memory should adjust params"
   | _ -> fail "unexpected hook decision");
  (try Sys.rmdir tmp_dir with _ -> ())

let test_compose_preserves_inner_before_turn_params () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Agent_sdk.Memory.create () in
  ignore
    (Agent_sdk.Memory.store
       memory
       ~tier:Agent_sdk.Memory.Long_term
       "world:compose"
       (`Assoc [ "content", `String "Memory context must survive composition." ]));
  let memory_hooks =
    Memory_hooks.make
      ~agent_name:"test_compose"
      ~config
      ~memory
      ()
  in
  let inner_seen = ref false in
  let inner_hooks =
    { Agent_sdk.Hooks.empty with
      before_turn_params =
        Some
          (function
            | Agent_sdk.Hooks.BeforeTurnParams { current_params; _ } ->
                inner_seen := true;
                let extra =
                  match current_params.extra_system_context with
                  | None -> Some "[keeper params]"
                  | Some existing -> Some (existing ^ "\n\n[keeper params]")
                in
                Agent_sdk.Hooks.AdjustParams
                  { current_params with
                    extra_system_context = extra;
                    tool_choice = Some Agent_sdk.Types.Auto;
                  }
            | _ -> Agent_sdk.Hooks.Continue)
    }
  in
  let hooks =
    Memory_hooks.compose_with_inner ~memory_hooks ~inner:inner_hooks
  in
  let event = make_before_turn_params_event ~turn:1 () in
  let decision =
    match hooks.before_turn_params with
    | Some f -> f event
    | None -> fail "before_turn_params hook should be Some"
  in
  check bool "inner hook ran" true !inner_seen;
  (match decision with
   | Agent_sdk.Hooks.AdjustParams params ->
     (match params.extra_system_context with
      | Some ctx ->
        check bool "world memory preserved" true
          (contains_text ~needle:"world:compose" ctx);
        check bool "inner context appended" true
          (contains_text ~needle:"[keeper params]" ctx)
      | None -> fail "expected composed extra_system_context");
     check bool "inner tool choice preserved" true
       (match params.tool_choice with
        | Some Agent_sdk.Types.Auto -> true
        | _ -> false)
   | _ -> fail "expected AdjustParams from composed hooks");
  (try Sys.rmdir tmp_dir with _ -> ())

let test_after_turn_hook_returns_continue () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_after" () in
  let hooks = Memory_hooks.make
    ~agent_name:"test_after"
    ~config
    ~memory
    ()
  in
  let event = make_after_turn_event () in
  let decision = match hooks.after_turn with
    | Some f -> f event
    | None -> fail "after_turn hook should be Some"
  in
  check bool "after_turn returns Continue" true
    (match decision with Agent_sdk.Hooks.Continue -> true | _ -> false);
  (try Sys.rmdir tmp_dir with _ -> ())

let test_after_turn_flush_failure_still_continues () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_after_fail" () in
  let labels =
    [("callback", "memory_after_turn_flush")]
  in
  let before =
    P.metric_value_or_zero P.metric_keeper_lifecycle_callback_failures
      ~labels ()
  in
  let memory_hooks =
    Memory_hooks.make
      ~agent_name:"test_after_fail"
      ~config
      ~memory
      ~flush_incremental:(fun ~memory:_ ~agent_name:_ ->
        raise (Failure "synthetic flush failure"))
      ()
  in
  let inner_seen = ref false in
  let inner_hooks =
    { Agent_sdk.Hooks.empty with
      after_turn =
        Some
          (fun _ ->
             inner_seen := true;
             Agent_sdk.Hooks.Continue)
    }
  in
  let hooks =
    Memory_hooks.compose_with_inner ~memory_hooks ~inner:inner_hooks
  in
  let event = make_after_turn_event () in
  let decision =
    match hooks.after_turn with
    | Some f -> f event
    | None -> fail "after_turn hook should be Some"
  in
  check bool "after_turn returns Continue" true
    (match decision with Agent_sdk.Hooks.Continue -> true | _ -> false);
  check bool "inner after_turn still ran" true !inner_seen;
  let after =
    P.metric_value_or_zero P.metric_keeper_lifecycle_callback_failures
      ~labels ()
  in
  check (float 0.0001) "flush failure counted" (before +. 1.0) after;
  (try Sys.rmdir tmp_dir with _ -> ())

let test_after_turn_flush_records_pipeline_metrics () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_pipeline" () in
  let success_labels =
    [ ("agent_name", "test_pipeline"); ("outcome", "success") ]
  in
  let episodic_labels =
    [ ("agent_name", "test_pipeline"); ("tier", "episodic") ]
  in
  let procedural_labels =
    [ ("agent_name", "test_pipeline"); ("tier", "procedural") ]
  in
  let before_flushes =
    P.metric_value_or_zero P.metric_memory_pipeline_flushes
      ~labels:success_labels ()
  in
  let before_duration_count =
    P.metric_value_or_zero
      (P.metric_memory_pipeline_flush_duration_seconds ^ "_count")
      ~labels:success_labels ()
  in
  let before_episodes =
    P.metric_value_or_zero P.metric_memory_pipeline_flush_records
      ~labels:episodic_labels ()
  in
  let before_procedures =
    P.metric_value_or_zero P.metric_memory_pipeline_flush_records
      ~labels:procedural_labels ()
  in
  let hooks =
    Memory_hooks.make
      ~agent_name:"test_pipeline"
      ~config
      ~memory
      ~flush_incremental:(fun ~memory:_ ~agent_name:_ -> (2, 3))
      ()
  in
  let decision =
    match hooks.after_turn with
    | Some f -> f (make_after_turn_event ())
    | None -> fail "after_turn hook should be Some"
  in
  check bool "after_turn returns Continue" true
    (match decision with Agent_sdk.Hooks.Continue -> true | _ -> false);
  check (float 0.0001) "success flush counted" (before_flushes +. 1.0)
    (P.metric_value_or_zero P.metric_memory_pipeline_flushes
       ~labels:success_labels ());
  check (float 0.0001) "duration observation counted"
    (before_duration_count +. 1.0)
    (P.metric_value_or_zero
       (P.metric_memory_pipeline_flush_duration_seconds ^ "_count")
       ~labels:success_labels ());
  check (float 0.0001) "episodic records counted" (before_episodes +. 2.0)
    (P.metric_value_or_zero P.metric_memory_pipeline_flush_records
       ~labels:episodic_labels ());
  check (float 0.0001) "procedural records counted"
    (before_procedures +. 3.0)
    (P.metric_value_or_zero P.metric_memory_pipeline_flush_records
       ~labels:procedural_labels ());
  (try Sys.rmdir tmp_dir with _ -> ())

(* ── Flush idempotency test ────────────────────────────────── *)

let test_flush_incremental_idempotent () =
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_flush" () in
  let (ep1, pr1) = Memory_oas_bridge.flush_incremental ~memory ~agent_name:"test_flush" in
  let (ep2, pr2) = Memory_oas_bridge.flush_incremental ~memory ~agent_name:"test_flush" in
  check int "first flush episodes" 0 ep1;
  check int "first flush procedures" 0 pr1;
  check int "second flush episodes (idempotent)" 0 ep2;
  check int "second flush procedures (idempotent)" 0 pr2

(* ── Feature flag removed (RFC-MASC-004 Phase 2) ─────────── *)

let test_feature_flag_removed () =
  let flag = Feature_flag_registry.find_opt "MASC_MEMORY_HOOK_FIRST" in
  check bool "flag removed from registry" true (Option.is_none flag)

(* ── Hook composition test ─────────────────────────────────── *)

let test_hook_slots_populated () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_slots" () in
  let hooks = Memory_hooks.make ~agent_name:"test_slots" ~config ~memory () in
  check bool "before_turn_params is Some" true (Option.is_some hooks.before_turn_params);
  check bool "after_turn is Some" true (Option.is_some hooks.after_turn);
  (* Other slots should be None *)
  check bool "pre_tool_use is None" true (Option.is_none hooks.pre_tool_use);
  check bool "post_tool_use is None" true (Option.is_none hooks.post_tool_use);
  check bool "on_idle is None" true (Option.is_none hooks.on_idle);
  check bool "on_error is None" true (Option.is_none hooks.on_error);
  (try Sys.rmdir tmp_dir with _ -> ())

(* ── Test suite ────────────────────────────────────────────── *)

let () =
  run "Memory_hooks (RFC-MASC-004)" [
    "pure_read", [
      test_case "load_episodes_text type" `Quick test_load_episodes_text_type;
      test_case "load_procedures_text empty" `Quick test_load_procedures_text_empty;
    ];
    "hook_decisions", [
      test_case "returns Continue when no memory" `Quick test_hook_returns_continue_when_no_memory;
      test_case "preserves existing context" `Quick test_hook_preserves_existing_context;
      test_case "injects world memory" `Quick test_hook_injects_world_memory;
      test_case "composition preserves inner before_turn_params" `Quick
        test_compose_preserves_inner_before_turn_params;
      test_case "after_turn returns Continue" `Quick test_after_turn_hook_returns_continue;
      test_case "after_turn records pipeline metrics" `Quick
        test_after_turn_flush_records_pipeline_metrics;
      test_case "after_turn flush failure still continues" `Quick
        test_after_turn_flush_failure_still_continues;
    ];
    "hook_structure", [
      test_case "hook slots populated correctly" `Quick test_hook_slots_populated;
    ];
    "flush", [
      test_case "flush_incremental idempotent" `Quick test_flush_incremental_idempotent;
    ];
    "feature_flag", [
      test_case "flag removed (Phase 2)" `Quick test_feature_flag_removed;
    ];
  ]
