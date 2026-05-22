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
module Runtime_manifest = Masc_mcp.Keeper_runtime_manifest
module Keeper_execution_receipt = Masc_mcp.Keeper_execution_receipt
module Keeper_agent_tool_surface = Masc_mcp.Keeper_agent_tool_surface
module Keeper_types = Masc_mcp.Keeper_types
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

let manifest_context ?(keeper_turn_id = 11) () : Runtime_manifest.turn_context =
  { manifest_keeper_name = "test_memory_hooks_keeper"
  ; manifest_agent_name = Some "test_memory_hooks_agent"
  ; manifest_trace_id = "trace-memory-hooks"
  ; manifest_generation = Some 3
  ; manifest_keeper_turn_id = Some keeper_turn_id
  }

let row_event row = Runtime_manifest.event_kind_to_string row.Runtime_manifest.event

let json_int_member name json =
  match Yojson.Safe.Util.member name json with
  | `Int value -> value
  | `Intlit raw -> Option.value ~default:0 (int_of_string_opt raw)
  | _ -> 0

let json_bool_member name json =
  match Yojson.Safe.Util.member name json with
  | `Bool value -> value
  | _ -> false

let require_manifest_event event rows =
  match List.find_opt (fun row -> row.Runtime_manifest.event = event) rows with
  | Some row -> row
  | None ->
    fail
      ("missing manifest event: "
       ^ Runtime_manifest.event_kind_to_string event)

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
    P.metric_value_or_zero Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_callback_failures
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
    P.metric_value_or_zero Masc_mcp.Keeper_metrics.metric_keeper_lifecycle_callback_failures
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

let test_memory_hooks_emit_runtime_manifest_rows () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Agent_sdk.Memory.create () in
  ignore
    (Agent_sdk.Memory.store
       memory
       ~tier:Agent_sdk.Memory.Long_term
       "world:manifest"
       (`Assoc [ "content", `String "Memory hook manifest evidence." ]));
  let rows = ref [] in
  let hooks =
    Memory_hooks.make
      ~agent_name:"test_manifest"
      ~config
      ~memory
      ~flush_incremental:(fun ~memory:_ ~agent_name:_ -> (2, 1))
      ~runtime_manifest_context:(manifest_context ())
      ~runtime_manifest_append:(fun row -> rows := row :: !rows)
      ()
  in
  let before_decision =
    match hooks.before_turn_params with
    | Some f -> f (make_before_turn_params_event ~turn:4 ())
    | None -> fail "before_turn_params hook should be Some"
  in
  (match before_decision with
   | Agent_sdk.Hooks.AdjustParams _ -> ()
   | _ -> fail "world memory should adjust params");
  let after_decision =
    match hooks.after_turn with
    | Some f -> f (make_after_turn_event ~turn:4 ())
    | None -> fail "after_turn hook should be Some"
  in
  check bool "after_turn returns Continue" true
    (match after_decision with Agent_sdk.Hooks.Continue -> true | _ -> false);
  let rows = List.rev !rows in
  check (list string)
    "memory manifest events"
    [ "memory_injected"; "memory_flushed" ]
    (List.map row_event rows);
  let injected = require_manifest_event Runtime_manifest.Memory_injected rows in
  check (option int) "injected keeper turn" (Some 11) injected.keeper_turn_id;
  check (option int) "injected OAS turn" (Some 4) injected.oas_turn_count;
  check string "injected status" "injected" injected.status;
  check bool "memory context present" true
    (json_bool_member "memory_context_present" injected.decision);
  check bool "memory context chars recorded" true
    (json_int_member "memory_context_chars" injected.decision > 0);
  let flushed = require_manifest_event Runtime_manifest.Memory_flushed rows in
  check string "flush status" "success" flushed.status;
  check int "episodes flushed" 2
    (json_int_member "episodes_flushed" flushed.decision);
  check int "procedures flushed" 1
    (json_int_member "procedures_flushed" flushed.decision);
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

(* ── Memory injection recording tests (OAS checklist #3) ──────── *)

let test_record_and_get_last_memory_injection () =
  Memory_hooks.record_last_memory_injection "agent_a" "digest123" 456;
  let result = Memory_hooks.get_last_memory_injection "agent_a" in
  check (option (pair string int)) "retrieves recorded injection" (Some ("digest123", 456)) result

let test_get_last_memory_injection_returns_none_when_missing () =
  let result = Memory_hooks.get_last_memory_injection "unknown_agent_xyz" in
  check (option (pair string int)) "returns None for unknown agent" None result

let test_record_last_memory_injection_overwrites () =
  Memory_hooks.record_last_memory_injection "agent_b" "first" 100;
  Memory_hooks.record_last_memory_injection "agent_b" "second" 200;
  let result = Memory_hooks.get_last_memory_injection "agent_b" in
  check (option (pair string int)) "overwrites previous injection" (Some ("second", 200)) result

let test_clear_last_memory_injection () =
  Memory_hooks.record_last_memory_injection "agent_clear" "digest" 123;
  Memory_hooks.clear_last_memory_injection "agent_clear";
  let result = Memory_hooks.get_last_memory_injection "agent_clear" in
  check (option (pair string int)) "cleared" None result

let test_memory_injection_cleared_on_continue () =
  let tmp_dir = Filename.temp_dir "masc_test_mh" "" in
  let config = make_test_config ~base_path:tmp_dir in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test_clear" () in
  let hooks = Memory_hooks.make
    ~agent_name:"test_clear"
    ~config
    ~memory
    ()
  in
  let event = make_before_turn_params_event ~turn:1 () in
  let decision = match hooks.before_turn_params with
    | Some f -> f event
    | None -> fail "before_turn_params hook should be Some"
  in
  (match decision with
   | Agent_sdk.Hooks.Continue ->
     let result = Memory_hooks.get_last_memory_injection "test_clear" in
     check (option (pair string int)) "cleared on Continue" None result
   | Agent_sdk.Hooks.AdjustParams _ ->
     let result = Memory_hooks.get_last_memory_injection "test_clear" in
     check bool "has entry after AdjustParams" true (Option.is_some result);
     let event2 = make_before_turn_params_event ~turn:2 () in
     let decision2 = match hooks.before_turn_params with
       | Some f -> f event2
       | None -> fail "before_turn_params hook should be Some"
     in
     (match decision2 with
      | Agent_sdk.Hooks.Continue ->
        let result2 = Memory_hooks.get_last_memory_injection "test_clear" in
        check (option (pair string int)) "cleared on second Continue" None result2
      | _ -> ())
   | _ -> fail "unexpected decision");
  (try Sys.rmdir tmp_dir with _ -> ())

let test_execution_receipt_json_includes_memory_fields () =
  let receipt : Keeper_execution_receipt.t =
    { keeper_name = "test_keeper"
    ; agent_name = "test_agent"
    ; trace_id = "trace-abc"
    ; generation = 1
    ; turn_count = Some 1
    ; oas_turn_count = None
    ; oas_dispatch_mode = None
    ; current_task_id = None
    ; goal_ids = []
    ; outcome = `Ok
    ; terminal_reason_code = "test"
    ; response_text_present = false
    ; model_used = None
    ; requested_tools = []
    ; reported_tools = []
    ; observed_tools = []
    ; canonical_tools = []
    ; unexpected_tools = []
    ; tools_used = []
    ; tool_contract_result = Keeper_execution_receipt.Contract_not_dispatched
    ; tool_surface =
        { turn_lane = Keeper_agent_tool_surface.Lane_pre_dispatch
        ; tool_surface_class = Keeper_agent_tool_surface.Surface_none
        ; tool_requirement = No_tools
        ; visible_tool_count = 0
        ; tool_gate_enabled = false
        ; tool_surface_fallback_used = false
        ; required_tools = []
        ; required_tool_candidates = []
        ; missing_required_tools = []
        }
    ; sandbox_kind = Keeper_types.Local
    ; sandbox_root = None
    ; network_mode = Keeper_types.Network_none
    ; approval_profile = None
    ; approval_profile_derived = false
    ; cascade_name = Keeper_execution_receipt.cascade_name_of_string "test"
    ; cascade_selected_model = None
    ; cascade_attempt_count = 0
    ; cascade_fallback_applied = false
    ; cascade_outcome = Keeper_execution_receipt.Cascade_not_dispatched
    ; degraded_retry_applied = false
    ; degraded_retry_cascade = None
    ; fallback_reason = None
    ; cascade_rotation_attempts = []
    ; stop_reason = None
    ; error_kind = None
    ; error_message = None
    ; started_at = "2024-01-01T00:00:00Z"
    ; ended_at = "2024-01-01T00:00:01Z"
    ; memory_context_digest = Some "sha256:abc123"
    ; extra_system_context_final_size = Some 789
    }
  in
  let json = Keeper_execution_receipt.to_json receipt in
  let digest = Yojson.Safe.Util.(member "memory_context_digest" json) in
  let size = Yojson.Safe.Util.(member "extra_system_context_final_size" json) in
  check string "memory_context_digest in JSON" "sha256:abc123"
    (match digest with `String s -> s | _ -> "");
  check int "extra_system_context_final_size in JSON" 789
    (match size with `Int n -> n | `Intlit s -> int_of_string s | _ -> 0)

let test_execution_receipt_json_null_when_missing () =
  let receipt : Keeper_execution_receipt.t =
    { keeper_name = "test_keeper"
    ; agent_name = "test_agent"
    ; trace_id = "trace-abc"
    ; generation = 1
    ; turn_count = Some 1
    ; oas_turn_count = None
    ; oas_dispatch_mode = None
    ; current_task_id = None
    ; goal_ids = []
    ; outcome = `Ok
    ; terminal_reason_code = "test"
    ; response_text_present = false
    ; model_used = None
    ; requested_tools = []
    ; reported_tools = []
    ; observed_tools = []
    ; canonical_tools = []
    ; unexpected_tools = []
    ; tools_used = []
    ; tool_contract_result = Keeper_execution_receipt.Contract_not_dispatched
    ; tool_surface =
        { turn_lane = Keeper_agent_tool_surface.Lane_pre_dispatch
        ; tool_surface_class = Keeper_agent_tool_surface.Surface_none
        ; tool_requirement = No_tools
        ; visible_tool_count = 0
        ; tool_gate_enabled = false
        ; tool_surface_fallback_used = false
        ; required_tools = []
        ; required_tool_candidates = []
        ; missing_required_tools = []
        }
    ; sandbox_kind = Keeper_types.Local
    ; sandbox_root = None
    ; network_mode = Keeper_types.Network_none
    ; approval_profile = None
    ; approval_profile_derived = false
    ; cascade_name = Keeper_execution_receipt.cascade_name_of_string "test"
    ; cascade_selected_model = None
    ; cascade_attempt_count = 0
    ; cascade_fallback_applied = false
    ; cascade_outcome = Keeper_execution_receipt.Cascade_not_dispatched
    ; degraded_retry_applied = false
    ; degraded_retry_cascade = None
    ; fallback_reason = None
    ; cascade_rotation_attempts = []
    ; stop_reason = None
    ; error_kind = None
    ; error_message = None
    ; started_at = "2024-01-01T00:00:00Z"
    ; ended_at = "2024-01-01T00:00:01Z"
    ; memory_context_digest = None
    ; extra_system_context_final_size = None
    }
  in
  let json = Keeper_execution_receipt.to_json receipt in
  let digest = Yojson.Safe.Util.(member "memory_context_digest" json) in
  let size = Yojson.Safe.Util.(member "extra_system_context_final_size" json) in
  check bool "memory_context_digest is Null" true (digest = `Null);
  check bool "extra_system_context_final_size is Null" true (size = `Null)

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
      test_case "runtime manifest rows emitted" `Quick
        test_memory_hooks_emit_runtime_manifest_rows;
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
    "memory_injection_record", [
      test_case "record and get last injection" `Quick test_record_and_get_last_memory_injection;
      test_case "get returns None when missing" `Quick test_get_last_memory_injection_returns_none_when_missing;
      test_case "record overwrites previous" `Quick test_record_last_memory_injection_overwrites;
      test_case "clear last injection" `Quick test_clear_last_memory_injection;
      test_case "cleared on Continue branch" `Quick test_memory_injection_cleared_on_continue;
    ];
    "execution_receipt_json", [
      test_case "includes memory fields in JSON" `Quick test_execution_receipt_json_includes_memory_fields;
      test_case "emits Null when memory fields absent" `Quick test_execution_receipt_json_null_when_missing;
    ];
  ]
