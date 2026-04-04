(** Comprehensive Tests for Tools module - MCP Tool Definitions *)

open Types
open Masc_mcp.Tools

let schema_inventory = all_schemas_extended

(* ============================================================ *)
(* Helper functions                                              *)
(* ============================================================ *)

let get_json_string key obj =
  match obj with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let get_json_list key obj =
  match obj with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List l) -> Some l
       | _ -> None)
  | _ -> None

let get_json_assoc key obj =
  match obj with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Assoc a) -> Some a
       | _ -> None)
  | _ -> None

(* ============================================================ *)
(* 1. Schema Structure Tests                                     *)
(* ============================================================ *)

let test_all_schemas_not_empty () =
  Alcotest.(check bool) "all_schemas is not empty"
    true (List.length schema_inventory > 0)

let test_all_schemas_count () =
  (* Verify we have at least 100 tools defined *)
  let count = List.length schema_inventory in
  Alcotest.(check bool) "at least 100 tools defined"
    true (count >= 100);
  Printf.printf "Total tool schemas: %d\n" count

let test_schema_has_required_fields () =
  List.iter (fun schema ->
    (* Name must not be empty *)
    Alcotest.(check bool) (Printf.sprintf "%s has name" schema.name)
      true (String.length schema.name > 0);
    (* Description must not be empty *)
    Alcotest.(check bool) (Printf.sprintf "%s has description" schema.name)
      true (String.length schema.description > 0);
    (* input_schema must be an object *)
    match schema.input_schema with
    | `Assoc _ -> ()
    | _ -> Alcotest.fail (Printf.sprintf "%s input_schema is not an object" schema.name)
  ) schema_inventory

let test_schema_names_are_unique () =
  let names = List.map (fun s -> s.name) schema_inventory in
  let unique_names = List.sort_uniq String.compare names in
  Alcotest.(check int) "all schema names are unique"
    (List.length names) (List.length unique_names)

let test_all_names_start_with_masc () =
  List.iter (fun schema ->
    Alcotest.(check bool) (Printf.sprintf "%s starts with masc_" schema.name)
      true (String.length schema.name >= 5 && String.sub schema.name 0 5 = "masc_")
  ) schema_inventory

(* ============================================================ *)
(* 2. find_tool Function Tests                                   *)
(* ============================================================ *)

let test_find_tool_existing () =
  let tools = ["masc_init"; "masc_join"; "masc_leave"; "masc_status";
               "masc_broadcast"; "masc_transition"] in
  List.iter (fun name ->
    match find_tool name with
    | Some schema -> Alcotest.(check string) "found correct tool" name schema.name
    | None -> Alcotest.fail (Printf.sprintf "Tool %s not found" name)
  ) tools

let test_find_tool_not_found () =
  let invalid_tools = ["invalid_tool"; "masc"; ""; "MASC_INIT"; "masc-init"] in
  List.iter (fun name ->
    match find_tool name with
    | None -> ()
    | Some _ -> Alcotest.fail (Printf.sprintf "Should not find tool %s" name)
  ) invalid_tools

let test_find_tool_case_sensitive () =
  (* Tool names are case-sensitive *)
  match find_tool "MASC_INIT" with
  | None -> ()  (* Expected: not found because wrong case *)
  | Some _ -> Alcotest.fail "Tool lookup should be case-sensitive"

(* ============================================================ *)
(* 3. Input Schema Validation Tests                              *)
(* ============================================================ *)

let test_input_schema_type_is_object () =
  List.iter (fun schema ->
    match get_json_string "type" schema.input_schema with
    | Some "object" -> ()
    | Some t -> Alcotest.fail (Printf.sprintf "%s input_schema type is %s, expected object" schema.name t)
    | None -> Alcotest.fail (Printf.sprintf "%s input_schema missing type field" schema.name)
  ) schema_inventory

let test_input_schema_has_properties () =
  List.iter (fun schema ->
    match get_json_assoc "properties" schema.input_schema with
    | Some _ -> ()
    | None -> Alcotest.fail (Printf.sprintf "%s input_schema missing properties" schema.name)
  ) schema_inventory

let test_required_field_is_list () =
  List.iter (fun schema ->
    match schema.input_schema with
    | `Assoc fields ->
        (match List.assoc_opt "required" fields with
         | None -> ()  (* Optional: some tools have no required fields *)
         | Some (`List _) -> ()
         | Some _ -> Alcotest.fail (Printf.sprintf "%s required field is not a list" schema.name))
    | _ -> Alcotest.fail (Printf.sprintf "%s input_schema is not an object" schema.name)
  ) schema_inventory

(* ============================================================ *)
(* 4. Specific Tool Tests                                        *)
(* ============================================================ *)

let test_masc_init_schema () =
  match find_tool "masc_init" with
  | None -> Alcotest.fail "masc_init not found"
  | Some schema ->
      Alcotest.(check bool) "has description" true (String.length schema.description > 10);
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name property" true (List.mem_assoc "agent_name" props)
      | None -> Alcotest.fail "masc_init missing properties"

let test_masc_join_schema () =
  match find_tool "masc_join" with
  | None -> Alcotest.fail "masc_join not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has capabilities" true (List.mem_assoc "capabilities" props)
      | None -> Alcotest.fail "masc_join missing properties"

let test_masc_leave_schema () =
  match find_tool "masc_leave" with
  | None -> Alcotest.fail "masc_leave not found"
  | Some schema ->
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "agent_name is required" true
            (List.mem (`String "agent_name") reqs)
      | None -> Alcotest.fail "masc_leave missing required field"

let test_masc_status_schema () =
  match find_tool "masc_status" with
  | None -> Alcotest.fail "masc_status not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          (* masc_status has no required parameters *)
          Alcotest.(check int) "properties can be empty" 0 (List.length props)
      | None -> Alcotest.fail "masc_status missing properties"

let test_masc_broadcast_schema () =
  match find_tool "masc_broadcast" with
  | None -> Alcotest.fail "masc_broadcast not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has message" true (List.mem_assoc "message" props)
      | None -> Alcotest.fail "masc_broadcast missing properties"

let test_masc_transition_schema () =
  match find_tool "masc_transition" with
  | None -> Alcotest.fail "masc_transition not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has completion_contract" true
            (List.mem_assoc "completion_contract" props);
          Alcotest.(check bool) "has evaluator_cascade" true
            (List.mem_assoc "evaluator_cascade" props)
      | None -> Alcotest.fail "masc_transition missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "agent_name required" true (List.mem (`String "agent_name") reqs);
          Alcotest.(check bool) "task_id required" true (List.mem (`String "task_id") reqs);
          Alcotest.(check bool) "action required" true (List.mem (`String "action") reqs)
      | None -> Alcotest.fail "masc_transition missing required field"

let test_masc_add_task_schema () =
  match find_tool "masc_add_task" with
  | None -> Alcotest.fail "masc_add_task not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has title" true (List.mem_assoc "title" props);
          Alcotest.(check bool) "has priority" true (List.mem_assoc "priority" props);
          Alcotest.(check bool) "has description" true (List.mem_assoc "description" props)
      | None -> Alcotest.fail "masc_add_task missing properties"

(* Operator/surface/collaboration test functions removed — modules pruned *)

let test_masc_room_strategy_get_schema () =
  match find_tool "masc_room_strategy_get" with
  | None -> Alcotest.fail "masc_room_strategy_get not found"
  | Some _ -> ()

let test_masc_room_strategy_set_schema () =
  match find_tool "masc_room_strategy_set" with
  | None -> Alcotest.fail "masc_room_strategy_set not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has search_strategy_default" true
            (List.mem_assoc "search_strategy_default" props);
          Alcotest.(check bool) "has speculation_enabled" true
            (List.mem_assoc "speculation_enabled" props);
          Alcotest.(check bool) "has speculation_budget" true
            (List.mem_assoc "speculation_budget" props)
      | None -> Alcotest.fail "masc_room_strategy_set missing properties"




(* Portal tool tests removed — portal module pruned *)

(* ============================================================ *)
(* 6. Worktree Tool Tests                                        *)
(* ============================================================ *)

let test_masc_worktree_create_schema () =
  match find_tool "masc_worktree_create" with
  | None -> Alcotest.fail "masc_worktree_create not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has task_id" true (List.mem_assoc "task_id" props)
      | None -> Alcotest.fail "masc_worktree_create missing properties"

let test_masc_worktree_remove_schema () =
  match find_tool "masc_worktree_remove" with
  | None -> Alcotest.fail "masc_worktree_remove not found"
  | Some _ -> ()

let test_masc_worktree_list_schema () =
  match find_tool "masc_worktree_list" with
  | None -> Alcotest.fail "masc_worktree_list not found"
  | Some _ -> ()

(* ============================================================ *)
(* 7. Agent Capability Tool Tests                                *)
(* ============================================================ *)

let test_masc_agents_schema () =
  match find_tool "masc_agents" with
  | None -> Alcotest.fail "masc_agents not found"
  | Some _ -> ()

let test_masc_register_capabilities_schema () =
  match find_tool "masc_register_capabilities" with
  | None -> Alcotest.fail "masc_register_capabilities not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has capabilities" true (List.mem_assoc "capabilities" props)
      | None -> Alcotest.fail "masc_register_capabilities missing properties"

let test_masc_find_by_capability_schema () =
  match find_tool "masc_find_by_capability" with
  | None -> Alcotest.fail "masc_find_by_capability not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has capability" true (List.mem_assoc "capability" props)
      | None -> Alcotest.fail "masc_find_by_capability missing properties"

(* ============================================================ *)
(* 8. Plan Tool Tests                                            *)
(* ============================================================ *)

let test_masc_plan_init_schema () =
  match find_tool "masc_plan_init" with
  | None -> Alcotest.fail "masc_plan_init not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has task_id" true (List.mem_assoc "task_id" props)
      | None -> Alcotest.fail "masc_plan_init missing properties"

let test_masc_plan_update_schema () =
  match find_tool "masc_plan_update" with
  | None -> Alcotest.fail "masc_plan_update not found"
  | Some _ -> ()

let test_masc_plan_get_schema () =
  match find_tool "masc_plan_get" with
  | None -> Alcotest.fail "masc_plan_get not found"
  | Some _ -> ()

let test_masc_deliver_schema () =
  match find_tool "masc_deliver" with
  | None -> Alcotest.fail "masc_deliver not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has content" true (List.mem_assoc "content" props)
      | None -> Alcotest.fail "masc_deliver missing properties"

(* ============================================================ *)
(* 9. Voting Tool Tests                                          *)
(* ============================================================ *)

(* Auth, A2A, poll_events, heartbeat_result tests removed — modules pruned *)

let test_masc_spawn_schema () =
  match find_tool "masc_spawn" with
  | None -> Alcotest.fail "masc_spawn not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has model" true (List.mem_assoc "model" props);
          Alcotest.(check bool) "has prompt" true (List.mem_assoc "prompt" props)
      | None -> Alcotest.fail "masc_spawn missing properties"

(* runtime_verify, observe_swarm, team_session_step tests removed — modules pruned *)

(* test_masc_persona_list_schema and test_masc_keeper_create_from_persona_schema
   removed: persona concept deleted, schema fields
   policy_voice_enabled/policy_shell_mode/initiative_* removed in #2607. *)

let test_masc_keeper_up_schema () =
  match find_tool "masc_keeper_up" with
  | None -> Alcotest.fail "masc_keeper_up not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has short_goal" true
            (List.mem_assoc "short_goal" props);
          Alcotest.(check bool) "has mid_goal" true
            (List.mem_assoc "mid_goal" props);
          Alcotest.(check bool) "has long_goal" true
            (List.mem_assoc "long_goal" props);
          Alcotest.(check bool) "has scope_kind" true
            (List.mem_assoc "scope_kind" props);
          Alcotest.(check bool) "omits models" false
            (List.mem_assoc "models" props);
          Alcotest.(check bool) "omits allowed_models" false
            (List.mem_assoc "allowed_models" props);
          Alcotest.(check bool) "omits active_model" false
            (List.mem_assoc "active_model" props);
          Alcotest.(check bool) "omits presence_keepalive" false
            (List.mem_assoc "presence_keepalive" props)
      | None -> Alcotest.fail "masc_keeper_up missing properties"

let test_masc_keeper_msg_schema () =
  match find_tool "masc_keeper_msg" with
  | None -> Alcotest.fail "masc_keeper_msg not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "omits new_goal" false
            (List.mem_assoc "new_goal" props);
          Alcotest.(check bool) "omits new_short_goal" false
            (List.mem_assoc "new_short_goal" props);
          Alcotest.(check bool) "omits new_mid_goal" false
            (List.mem_assoc "new_mid_goal" props);
          Alcotest.(check bool) "omits new_long_goal" false
            (List.mem_assoc "new_long_goal" props)
      | None -> Alcotest.fail "masc_keeper_msg missing properties"

let test_masc_keeper_repair_schema () =
  match find_tool "masc_keeper_repair" with
  | None -> Alcotest.fail "masc_keeper_repair not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has task_spec" true
            (List.mem_assoc "task_spec" props);
          Alcotest.(check bool) "has source_text" true
            (List.mem_assoc "source_text" props);
          Alcotest.(check bool) "has target_mode" true
            (List.mem_assoc "target_mode" props);
          Alcotest.(check bool) "has validator_profile" true
            (List.mem_assoc "validator_profile" props)
      | None -> Alcotest.fail "masc_keeper_repair missing properties"

(* keeper policy schema tests removed — policy tool schemas no longer exist *)

let test_masc_tool_admin_snapshot_schema () =
  match find_tool "masc_tool_admin_snapshot" with
  | None -> Alcotest.fail "masc_tool_admin_snapshot not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has include_hidden" true
            (List.mem_assoc "include_hidden" props);
          Alcotest.(check bool) "has include_deprecated" true
            (List.mem_assoc "include_deprecated" props)
      | None -> Alcotest.fail "masc_tool_admin_snapshot missing properties"

let test_masc_tool_admin_update_schema () =
  match find_tool "masc_tool_admin_update" with
  | None -> Alcotest.fail "masc_tool_admin_update not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has section" true (List.mem_assoc "section" props);
          Alcotest.(check bool) "has policy" true (List.mem_assoc "policy" props)
      | None -> Alcotest.fail "masc_tool_admin_update missing properties"

(* ============================================================ *)
(* 14. Handover Tool Tests                                       *)
(* ============================================================ *)

let test_masc_handover_create_schema () =
  match find_tool "masc_handover_create" with
  | None -> Alcotest.fail "masc_handover_create not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has goal" true (List.mem_assoc "goal" props)
      | None -> Alcotest.fail "masc_handover_create missing properties"

let test_masc_handover_list_schema () =
  match find_tool "masc_handover_list" with
  | None -> Alcotest.fail "masc_handover_list not found"
  | Some _ -> ()

let test_masc_handover_claim_schema () =
  match find_tool "masc_handover_claim" with
  | None -> Alcotest.fail "masc_handover_claim not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has handover_id" true (List.mem_assoc "handover_id" props)
      | None -> Alcotest.fail "masc_handover_claim missing properties"

(* ============================================================ *)
(* 15. Legacy Swarm Removal Tests                                *)
(* ============================================================ *)

let test_legacy_swarm_tools_removed () =
  let removed_tools =
    [
      "masc_swarm_init";
      "masc_swarm_join";
      "masc_swarm_leave";
      "masc_swarm_status";
      "masc_swarm_evolve";
      "masc_swarm_propose";
      "masc_swarm_vote";
      "masc_swarm_deposit";
      "masc_swarm_trails";
    ]
  in
  List.iter
    (fun name ->
      match find_tool name with
      | None -> ()
      | Some _ ->
          Alcotest.fail (Printf.sprintf "%s should be removed from public schemas" name))
    removed_tools

let test_legacy_mitosis_tools_removed () =
  let removed_tools =
    [
      "masc_mitosis_status";
      "masc_mitosis_pool";
      "masc_mitosis_divide";
      "masc_mitosis_check";
      "masc_mitosis_record";
      "masc_mitosis_prepare";
      "masc_mitosis_handoff";
      "masc_mitosis_all";
    ]
  in
  List.iter
    (fun name ->
      match find_tool name with
      | None -> ()
      | Some _ ->
          Alcotest.fail
            (Printf.sprintf "%s should be removed from public schemas" name))
    removed_tools

(* ============================================================ *)
(* Command plane, detachment, operation, team_session tests removed — modules pruned *)

(* ============================================================ *)
(* 19. Bounded Run Tool Tests                                    *)
(* ============================================================ *)

let test_masc_bounded_run_schema () =
  match find_tool "masc_bounded_run" with
  | None -> Alcotest.fail "masc_bounded_run not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agents" true (List.mem_assoc "agents" props);
          Alcotest.(check bool) "has prompt" true (List.mem_assoc "prompt" props);
          Alcotest.(check bool) "has constraints" true (List.mem_assoc "constraints" props);
          Alcotest.(check bool) "has goal" true (List.mem_assoc "goal" props)
      | None -> Alcotest.fail "masc_bounded_run missing properties"

(* ============================================================ *)
(* 20. Dashboard Tool Tests                                      *)
(* ============================================================ *)

let test_masc_dashboard_schema () =
  match find_tool "masc_dashboard" with
  | None -> Alcotest.fail "masc_dashboard not found"
  | Some _ -> ()

let test_masc_agent_fitness_schema () =
  match find_tool "masc_agent_fitness" with
  | None -> Alcotest.fail "masc_agent_fitness not found"
  | Some _ -> ()

let test_masc_get_metrics_schema () =
  match find_tool "masc_get_metrics" with
  | None -> Alcotest.fail "masc_get_metrics not found"
  | Some _ -> ()

let test_masc_transport_status_schema () =
  match find_tool "masc_transport_status" with
  | None -> Alcotest.fail "masc_transport_status not found"
  | Some _ -> ()

let test_masc_websocket_discovery_schema () =
  match find_tool "masc_websocket_discovery" with
  | None -> Alcotest.fail "masc_websocket_discovery not found"
  | Some _ -> ()

let test_masc_webrtc_offer_schema () =
  match find_tool "masc_webrtc_offer" with
  | None -> Alcotest.fail "masc_webrtc_offer not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true
            (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has ice_candidates" true
            (List.mem_assoc "ice_candidates" props)
      | None -> Alcotest.fail "masc_webrtc_offer missing properties"

let test_masc_webrtc_answer_schema () =
  match find_tool "masc_webrtc_answer" with
  | None -> Alcotest.fail "masc_webrtc_answer not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has offer_id" true
            (List.mem_assoc "offer_id" props);
          Alcotest.(check bool) "has agent_name" true
            (List.mem_assoc "agent_name" props)
      | None -> Alcotest.fail "masc_webrtc_answer missing properties"

(* ============================================================ *)
(* 21. Edge Case Tests                                           *)
(* ============================================================ *)

let test_description_not_too_short () =
  List.iter (fun schema ->
    Alcotest.(check bool) (Printf.sprintf "%s description >= 20 chars" schema.name)
      true (String.length schema.description >= 20)
  ) schema_inventory

let test_description_not_too_long () =
  List.iter (fun schema ->
    (* Description should be reasonable length for MODEL context *)
    Alcotest.(check bool) (Printf.sprintf "%s description <= 1000 chars" schema.name)
      true (String.length schema.description <= 1000)
  ) schema_inventory

let test_no_duplicate_properties () =
  List.iter (fun schema ->
    match get_json_assoc "properties" schema.input_schema with
    | Some props ->
        let prop_names = List.map fst props in
        let unique_names = List.sort_uniq String.compare prop_names in
        Alcotest.(check int) (Printf.sprintf "%s no duplicate properties" schema.name)
          (List.length prop_names) (List.length unique_names)
    | None -> ()
  ) schema_inventory

let test_property_types_valid () =
  let valid_types = ["string"; "integer"; "number"; "boolean"; "array"; "object"] in
  List.iter (fun schema ->
    match get_json_assoc "properties" schema.input_schema with
    | Some props ->
        List.iter (fun (name, prop_def) ->
          match get_json_string "type" prop_def with
          | Some t ->
              Alcotest.(check bool)
                (Printf.sprintf "%s.%s has valid type %s" schema.name name t)
                true (List.mem t valid_types)
          | None -> ()  (* Type might be inferred or use enum *)
        ) props
    | None -> ()
  ) schema_inventory

(* ============================================================ *)
(* Test Runner                                                   *)
(* ============================================================ *)

let () =
  Alcotest.run "Tools Coverage" [
    "schema_structure", [
      Alcotest.test_case "not_empty" `Quick test_all_schemas_not_empty;
      Alcotest.test_case "count" `Quick test_all_schemas_count;
      Alcotest.test_case "required_fields" `Quick test_schema_has_required_fields;
      Alcotest.test_case "unique_names" `Quick test_schema_names_are_unique;
      Alcotest.test_case "masc_prefix" `Quick test_all_names_start_with_masc;
    ];
    "find_tool", [
      Alcotest.test_case "existing" `Quick test_find_tool_existing;
      Alcotest.test_case "not_found" `Quick test_find_tool_not_found;
      Alcotest.test_case "case_sensitive" `Quick test_find_tool_case_sensitive;
    ];
    "input_schema", [
      Alcotest.test_case "type_is_object" `Quick test_input_schema_type_is_object;
      Alcotest.test_case "has_properties" `Quick test_input_schema_has_properties;
      Alcotest.test_case "required_is_list" `Quick test_required_field_is_list;
    ];
    "core_tools", [
      Alcotest.test_case "masc_init" `Quick test_masc_init_schema;
      Alcotest.test_case "masc_join" `Quick test_masc_join_schema;
      Alcotest.test_case "masc_leave" `Quick test_masc_leave_schema;
      Alcotest.test_case "masc_status" `Quick test_masc_status_schema;
      Alcotest.test_case "masc_broadcast" `Quick test_masc_broadcast_schema;
      Alcotest.test_case "masc_transition" `Quick test_masc_transition_schema;
      Alcotest.test_case "masc_add_task" `Quick test_masc_add_task_schema;
      Alcotest.test_case "masc_room_strategy_get" `Quick test_masc_room_strategy_get_schema;
      Alcotest.test_case "masc_room_strategy_set" `Quick test_masc_room_strategy_set_schema;
    ];
    (* portal_tools removed — portal module pruned *)
    "worktree_tools", [
      Alcotest.test_case "worktree_create" `Quick test_masc_worktree_create_schema;
      Alcotest.test_case "worktree_remove" `Quick test_masc_worktree_remove_schema;
      Alcotest.test_case "worktree_list" `Quick test_masc_worktree_list_schema;
    ];
    "agent_tools", [
      Alcotest.test_case "agents" `Quick test_masc_agents_schema;
      Alcotest.test_case "register_capabilities" `Quick test_masc_register_capabilities_schema;
      Alcotest.test_case "find_by_capability" `Quick test_masc_find_by_capability_schema;
    ];
    "plan_tools", [
      Alcotest.test_case "plan_init" `Quick test_masc_plan_init_schema;
      Alcotest.test_case "plan_update" `Quick test_masc_plan_update_schema;
      Alcotest.test_case "plan_get" `Quick test_masc_plan_get_schema;
      Alcotest.test_case "deliver" `Quick test_masc_deliver_schema;
    ];
    "vote_tools", [
    ];
    (* auth_tools removed — auth module pruned *)
    (* a2a_tools removed — a2a module pruned *)
    "spawn_runtime_tools", [
      Alcotest.test_case "spawn" `Quick test_masc_spawn_schema;
    ];
    "keeper_runtime_tools", [
      Alcotest.test_case "keeper-up" `Quick
        test_masc_keeper_up_schema;
      Alcotest.test_case "keeper-msg" `Quick
        test_masc_keeper_msg_schema;
      Alcotest.test_case "keeper-repair" `Quick
        test_masc_keeper_repair_schema;
    ];
    "runtime_admin_tools", [
      Alcotest.test_case "tool-admin-snapshot" `Quick
        test_masc_tool_admin_snapshot_schema;
      Alcotest.test_case "tool-admin-update" `Quick
        test_masc_tool_admin_update_schema;
    ];
    (* runtime_verify_tools removed — local_runtime module pruned *)
    (* team_session_runtime_tools removed — team_session module pruned *)
    "handover_tools", [
      Alcotest.test_case "handover_create" `Quick test_masc_handover_create_schema;
      Alcotest.test_case "handover_list" `Quick test_masc_handover_list_schema;
      Alcotest.test_case "handover_claim" `Quick test_masc_handover_claim_schema;
    ];
    "legacy_swarm_removed", [
      Alcotest.test_case "removed_from_public_schemas" `Quick
        test_legacy_swarm_tools_removed;
    ];
    "legacy_lifecycle_removed", [
      Alcotest.test_case "mitosis_removed_from_public_schemas" `Quick
        test_legacy_mitosis_tools_removed;
    ];
    (* command_plane_tools removed — command_plane module pruned *)
    "bounded_run", [
      Alcotest.test_case "bounded_run" `Quick test_masc_bounded_run_schema;
    ];
    "dashboard_tools", [
      Alcotest.test_case "dashboard" `Quick test_masc_dashboard_schema;
      Alcotest.test_case "agent_fitness" `Quick test_masc_agent_fitness_schema;
      Alcotest.test_case "get_metrics" `Quick test_masc_get_metrics_schema;
    ];
    "transport_tools", [
      Alcotest.test_case "transport_status" `Quick test_masc_transport_status_schema;
      Alcotest.test_case "websocket_discovery" `Quick test_masc_websocket_discovery_schema;
      Alcotest.test_case "webrtc_offer" `Quick test_masc_webrtc_offer_schema;
      Alcotest.test_case "webrtc_answer" `Quick test_masc_webrtc_answer_schema;
    ];
    "edge_cases", [
      Alcotest.test_case "description_not_short" `Quick test_description_not_too_short;
      Alcotest.test_case "description_not_long" `Quick test_description_not_too_long;
      Alcotest.test_case "no_duplicate_props" `Quick test_no_duplicate_properties;
      Alcotest.test_case "valid_prop_types" `Quick test_property_types_valid;
    ];
  ]
