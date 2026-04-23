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
  (* Verify we have at least 50 tools defined (post-pruning floor) *)
  let count = List.length schema_inventory in
  Alcotest.(check bool) "at least 50 tools defined"
    true (count >= 50);
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
  let tools = ["masc_join"; "masc_leave"; "masc_status";
               "masc_broadcast"; "masc_transition"] in
  List.iter (fun name ->
    match find_tool name with
    | Some schema -> Alcotest.(check string) "found correct tool" name schema.name
    | None -> Alcotest.fail (Printf.sprintf "Tool %s not found" name)
  ) tools

let test_find_tool_not_found () =
  let invalid_tools = ["invalid_tool"; "masc"; ""; "MASC_STATUS"; "masc-status"] in
  List.iter (fun name ->
    match find_tool name with
    | None -> ()
    | Some _ -> Alcotest.fail (Printf.sprintf "Should not find tool %s" name)
  ) invalid_tools

let test_find_tool_case_sensitive () =
  (* Tool names are case-sensitive *)
  match find_tool "MASC_STATUS" with
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

(* test_masc_init_schema removed: masc_init tool pruned *)

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
            (List.mem_assoc "evaluator_cascade" props);
          Alcotest.(check bool) "has handoff_context" true
            (List.mem_assoc "handoff_context" props)
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
          Alcotest.(check bool) "has description" true (List.mem_assoc "description" props);
          Alcotest.(check bool) "has contract" true (List.mem_assoc "contract" props)
      | None -> Alcotest.fail "masc_add_task missing properties"

let test_masc_goal_list_schema () =
  match find_tool "masc_goal_list" with
  | None -> Alcotest.fail "masc_goal_list not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has horizon" true (List.mem_assoc "horizon" props);
          Alcotest.(check bool) "has status" true (List.mem_assoc "status" props)
      | None -> Alcotest.fail "masc_goal_list missing properties"

let test_masc_goal_upsert_schema () =
  match find_tool "masc_goal_upsert" with
  | None -> Alcotest.fail "masc_goal_upsert not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has id" true (List.mem_assoc "id" props);
          Alcotest.(check bool) "has title" true (List.mem_assoc "title" props);
          Alcotest.(check bool) "has horizon" true (List.mem_assoc "horizon" props);
          Alcotest.(check bool) "has phase" true (List.mem_assoc "phase" props);
          Alcotest.(check bool) "has verifier_policy" true
            (List.mem_assoc "verifier_policy" props);
          Alcotest.(check bool) "has require_completion_approval" true
            (List.mem_assoc "require_completion_approval" props);
          Alcotest.(check bool) "has parent_goal_id" true
            (List.mem_assoc "parent_goal_id" props)
      | None -> Alcotest.fail "masc_goal_upsert missing properties"

let test_masc_goal_review_schema () =
  match find_tool "masc_goal_review" with
  | None -> Alcotest.fail "masc_goal_review not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has goal_id" true
            (List.mem_assoc "goal_id" props);
          Alcotest.(check bool) "has outcome" true
            (List.mem_assoc "outcome" props);
          Alcotest.(check bool) "has new_horizon" true
            (List.mem_assoc "new_horizon" props)
      | None -> Alcotest.fail "masc_goal_review missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "goal_id required" true
            (List.mem (`String "goal_id") reqs);
          Alcotest.(check bool) "outcome required" true
            (List.mem (`String "outcome") reqs)
      | None -> Alcotest.fail "masc_goal_review missing required field"

let test_masc_goal_transition_schema () =
  match find_tool "masc_goal_transition" with
  | None -> Alcotest.fail "masc_goal_transition not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has goal_id" true
            (List.mem_assoc "goal_id" props);
          Alcotest.(check bool) "has action" true
            (List.mem_assoc "action" props);
          Alcotest.(check bool) "has actor" true
            (List.mem_assoc "actor" props);
          Alcotest.(check bool) "has note" true
            (List.mem_assoc "note" props)
      | None -> Alcotest.fail "masc_goal_transition missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "goal_id required" true
            (List.mem (`String "goal_id") reqs);
          Alcotest.(check bool) "action required" true
            (List.mem (`String "action") reqs);
          Alcotest.(check bool) "actor required" true
            (List.mem (`String "actor") reqs)
      | None -> Alcotest.fail "masc_goal_transition missing required field"

let test_masc_goal_verify_schema () =
  match find_tool "masc_goal_verify" with
  | None -> Alcotest.fail "masc_goal_verify not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has goal_id" true
            (List.mem_assoc "goal_id" props);
          Alcotest.(check bool) "has request_id" true
            (List.mem_assoc "request_id" props);
          Alcotest.(check bool) "has principal" true
            (List.mem_assoc "principal" props);
          Alcotest.(check bool) "has decision" true
            (List.mem_assoc "decision" props);
          Alcotest.(check bool) "has evidence_refs" true
            (List.mem_assoc "evidence_refs" props)
      | None -> Alcotest.fail "masc_goal_verify missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "goal_id required" true
            (List.mem (`String "goal_id") reqs);
          Alcotest.(check bool) "principal required" true
            (List.mem (`String "principal") reqs);
          Alcotest.(check bool) "decision required" true
            (List.mem (`String "decision") reqs)
      | None -> Alcotest.fail "masc_goal_verify missing required field"

let test_remote_operator_action_schema_is_strict () =
  let schema =
    match List.find_opt (fun schema -> schema.name = "masc_operator_action")
            Masc_mcp.Tool_operator.remote_schemas with
    | Some schema -> schema
    | None -> Alcotest.fail "remote masc_operator_action schema not found"
  in
  match get_json_assoc "properties" schema.input_schema with
  | Some props ->
      (match List.assoc_opt "action_type" props with
       | Some (`Assoc fields) ->
           (match List.assoc_opt "enum" fields with
            | Some (`List enums) ->
                Alcotest.(check bool) "remote excludes team_turn" false
                  (List.mem (`String "team_turn") enums);
                (* Issue #8417: [task_inject] has a real handler +
                   approval contract; promoted into the strict enum so
                   remote operator callers and the LLM judge can
                   discover the capability. *)
                Alcotest.(check bool) "remote includes task_inject" true
                  (List.mem (`String "task_inject") enums);
                Alcotest.(check bool) "remote excludes keeper_msg" false
                  (List.mem (`String "keeper_msg") enums);
                Alcotest.(check bool) "remote excludes team_note" false
                  (List.mem (`String "team_note") enums);
                Alcotest.(check bool) "remote excludes team_worker_spawn_batch" false
                  (List.mem (`String "team_worker_spawn_batch") enums);
                Alcotest.(check bool) "remote includes social_sweep" true
                  (List.mem (`String "social_sweep") enums);
                Alcotest.(check bool) "remote excludes autonomy_tick alias" false
                  (List.mem (`String "autonomy_tick") enums);
                Alcotest.(check bool) "remote includes keeper_probe" true
                  (List.mem (`String "keeper_probe") enums);
                Alcotest.(check bool) "remote includes keeper_recover" true
                  (List.mem (`String "keeper_recover") enums);
                Alcotest.(check bool) "remote includes keeper_message" true
                  (List.mem (`String "keeper_message") enums);
                Alcotest.(check bool)
                  "remote includes keeper_github_identity_login_prepare" true
                  (List.mem (`String "keeper_github_identity_login_prepare") enums);
                Alcotest.(check bool)
                  "remote includes keeper_github_identity_status" true
                  (List.mem (`String "keeper_github_identity_status") enums)
            | _ -> Alcotest.fail "remote action_type missing enum")
       | _ -> Alcotest.fail "remote action_type missing")
  | None -> Alcotest.fail "remote masc_operator_action missing properties"

let test_retired_front_door_tools_absent_from_schema_inventory () =
  let retired_tools =
    [
      "masc_operator_snapshot";
      "masc_operator_digest";
      "masc_operator_action";
      "masc_operator_confirm";
      "masc_operator_judgment_write";
      "masc_surface_audit";
      "masc_operation_start";
      "masc_dispatch_tick";
    ]
  in
  List.iter
    (fun name ->
      match find_tool name with
      | None -> ()
      | Some _ ->
          Alcotest.fail
            (Printf.sprintf "%s should be absent from schema inventory" name))
    retired_tools

let test_masc_board_post_schema_supports_judgment () =
  let schema = Masc_mcp.Tool_board.tool_post_create in
  match get_json_assoc "properties" schema.input_schema with
  | Some props ->
      Alcotest.(check bool) "has classification_reason" true
        (List.mem_assoc "classification_reason" props);
      Alcotest.(check bool) "has judgment" true
        (List.mem_assoc "judgment" props)
  | None -> Alcotest.fail "masc_board_post missing properties"




(* ============================================================ *)
(* 5. Portal Tool Tests                                          *)
(* ============================================================ *)

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

(* test_masc_find_by_capability_schema removed: tool pruned *)

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

(* ============================================================ *)
(* 10. Auth Tool Tests                                           *)
(* ============================================================ *)

(* Auth tool schema tests removed: auth tools pruned from registry *)

(* ============================================================ *)
(* 11. A2A Tool Tests                                            *)
(* ============================================================ *)

(* masc_poll_events and masc_heartbeat_result schema tests removed: tools pruned *)

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

(* test_masc_runtime_verify_schema removed: tool pruned *)

(* test_masc_persona_list_schema removed: persona list coverage is trivial. *)

let test_masc_keeper_create_from_persona_schema () =
  match find_tool "masc_keeper_create_from_persona" with
  | None -> Alcotest.fail "masc_keeper_create_from_persona not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has persona_name" true
            (List.mem_assoc "persona_name" props);
          Alcotest.(check bool) "omits social_model" false
            (List.mem_assoc "social_model" props)
      | None -> Alcotest.fail "masc_keeper_create_from_persona missing properties"

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
          Alcotest.(check bool) "has sandbox_profile" true
            (List.mem_assoc "sandbox_profile" props);
          Alcotest.(check bool) "has network_mode" true
            (List.mem_assoc "network_mode" props);
          Alcotest.(check bool) "has shared_memory_scope" true
            (List.mem_assoc "shared_memory_scope" props);
          Alcotest.(check bool) "omits social_model" false
            (List.mem_assoc "social_model" props);
          Alcotest.(check bool) "has autoboot_enabled" true
            (List.mem_assoc "autoboot_enabled" props);
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

let test_masc_team_memory_read_schema () =
  match find_tool "masc_team_memory_read" with
  | None -> Alcotest.fail "masc_team_memory_read not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has room" true
            (List.mem_assoc "room" props);
          Alcotest.(check bool) "has key" true
            (List.mem_assoc "key" props)
      | None -> Alcotest.fail "masc_team_memory_read missing properties"

let test_masc_team_memory_write_schema () =
  match find_tool "masc_team_memory_write" with
  | None -> Alcotest.fail "masc_team_memory_write not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has room" true
            (List.mem_assoc "room" props);
          Alcotest.(check bool) "has key" true
            (List.mem_assoc "key" props);
          Alcotest.(check bool) "has content" true
            (List.mem_assoc "content" props)
      | None -> Alcotest.fail "masc_team_memory_write missing properties"

let test_masc_team_memory_search_schema () =
  match find_tool "masc_team_memory_search" with
  | None -> Alcotest.fail "masc_team_memory_search not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has room" true
            (List.mem_assoc "room" props);
          Alcotest.(check bool) "has query" true
            (List.mem_assoc "query" props)
      | None -> Alcotest.fail "masc_team_memory_search missing properties"

(* ============================================================ *)
(* 14. Handover Tool Tests                                       *)
(* ============================================================ *)

(* Handover tool schema tests removed: handover tools pruned from registry *)

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
(* 19. Bounded Run Tool Tests                                    *)
(* ============================================================ *)

(* test_masc_bounded_run_schema removed: tool pruned *)

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
      Alcotest.test_case "masc_join" `Quick test_masc_join_schema;
      Alcotest.test_case "masc_leave" `Quick test_masc_leave_schema;
      Alcotest.test_case "masc_status" `Quick test_masc_status_schema;
      Alcotest.test_case "masc_broadcast" `Quick test_masc_broadcast_schema;
      Alcotest.test_case "masc_transition" `Quick test_masc_transition_schema;
      Alcotest.test_case "masc_add_task" `Quick test_masc_add_task_schema;
      Alcotest.test_case "masc_board_post supports judgment" `Quick
        test_masc_board_post_schema_supports_judgment;
      Alcotest.test_case "remote_operator_action_strict" `Quick
        test_remote_operator_action_schema_is_strict;
      Alcotest.test_case "retired front-door tools absent" `Quick
        test_retired_front_door_tools_absent_from_schema_inventory;
    ];
    "worktree_tools", [
      Alcotest.test_case "worktree_create" `Quick test_masc_worktree_create_schema;
      Alcotest.test_case "worktree_remove" `Quick test_masc_worktree_remove_schema;
      Alcotest.test_case "worktree_list" `Quick test_masc_worktree_list_schema;
    ];
    "agent_tools", [
      Alcotest.test_case "agents" `Quick test_masc_agents_schema;
      Alcotest.test_case "register_capabilities" `Quick test_masc_register_capabilities_schema;
      (* find_by_capability removed: tool pruned *)
    ];
    "plan_tools", [
      Alcotest.test_case "plan_init" `Quick test_masc_plan_init_schema;
      Alcotest.test_case "plan_update" `Quick test_masc_plan_update_schema;
      Alcotest.test_case "plan_get" `Quick test_masc_plan_get_schema;
      Alcotest.test_case "deliver" `Quick test_masc_deliver_schema;
    ];
    "goal_tools", [
      Alcotest.test_case "goal_list" `Quick test_masc_goal_list_schema;
      Alcotest.test_case "goal_upsert" `Quick test_masc_goal_upsert_schema;
      Alcotest.test_case "goal_review" `Quick test_masc_goal_review_schema;
      Alcotest.test_case "goal_transition" `Quick test_masc_goal_transition_schema;
      Alcotest.test_case "goal_verify" `Quick test_masc_goal_verify_schema;
    ];
    "vote_tools", [
    ];
    (* auth_tools, a2a_tools (poll_events/heartbeat_result), handover_tools,
       bounded_run removed: pruned from registry *)
    "spawn_runtime_tools", [
      Alcotest.test_case "spawn" `Quick test_masc_spawn_schema;
    ];
    "keeper_runtime_tools", [
      Alcotest.test_case "keeper-create-from-persona" `Quick
        test_masc_keeper_create_from_persona_schema;
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
    "team_memory_tools", [
      Alcotest.test_case "team-memory-read" `Quick
        test_masc_team_memory_read_schema;
      Alcotest.test_case "team-memory-write" `Quick
        test_masc_team_memory_write_schema;
      Alcotest.test_case "team-memory-search" `Quick
        test_masc_team_memory_search_schema;
    ];
    (* runtime_verify_tools removed: masc_runtime_verify pruned *)
    "legacy_swarm_removed", [
      Alcotest.test_case "removed_from_public_schemas" `Quick
        test_legacy_swarm_tools_removed;
    ];
    "legacy_lifecycle_removed", [
      Alcotest.test_case "mitosis_removed_from_public_schemas" `Quick
        test_legacy_mitosis_tools_removed;
    ];
    "dashboard_tools", [
      Alcotest.test_case "dashboard" `Quick test_masc_dashboard_schema;
      Alcotest.test_case "agent_fitness" `Quick test_masc_agent_fitness_schema;
      Alcotest.test_case "get_metrics" `Quick test_masc_get_metrics_schema;
    ];
    "transport_tools", [
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
