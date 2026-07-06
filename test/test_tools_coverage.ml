(** Comprehensive Tests for Tools module - MCP Tool Definitions *)

open Masc_domain

let schema_inventory = Tools.all_schemas_extended
let registered_schema_inventory = Masc.Config.raw_all_tool_schemas

let find_schema_in schemas name =
  List.find_opt
    (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
    schemas
;;

let find_schema_inventory_tool name = find_schema_in schema_inventory name
let find_registered_tool name = find_schema_in registered_schema_inventory name

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

let get_json_bool key obj =
  match obj with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool value) -> Some value
       | _ -> None)
  | _ -> None

let schema_property schema property =
  match get_json_assoc "properties" schema.input_schema with
  | Some properties -> List.assoc_opt property properties
  | None -> None

let property_description schema property =
  match schema_property schema property with
  | Some (`Assoc fields) ->
      (match List.assoc_opt "description" fields with
       | Some (`String value) -> Some value
       | _ -> None)
  | Some _ | None -> None

let contains_substring ~needle value =
  let needle_len = String.length needle in
  let value_len = String.length value in
  let rec loop index =
    if index + needle_len > value_len then false
    else if String.sub value index needle_len = needle then true
    else loop (index + 1)
  in
  needle_len = 0 || loop 0

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
(* 2. Schema Inventory Lookup Tests                              *)
(* ============================================================ *)

let test_schema_inventory_lookup_existing () =
  let tools =
    [ "masc_start"; "masc_status"; "masc_broadcast"; "masc_transition" ]
  in
  List.iter (fun name ->
    match find_schema_inventory_tool name with
    | Some schema -> Alcotest.(check string) "found correct tool" name schema.name
    | None -> Alcotest.fail (Printf.sprintf "Tool %s not found" name)
  ) tools

let test_schema_inventory_lookup_not_found () =
  let invalid_tools = ["invalid_tool"; "masc"; ""; "MASC_STATUS"; "masc-status"] in
  List.iter (fun name ->
    match find_schema_inventory_tool name with
    | None -> ()
    | Some _ -> Alcotest.fail (Printf.sprintf "Should not find tool %s" name)
  ) invalid_tools

let test_schema_inventory_lookup_case_sensitive () =
  (* Tool names are case-sensitive *)
  match find_schema_inventory_tool "MASC_STATUS" with
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
(* test_masc_bind_schema and test_masc_unbind_schema removed with lifecycle collapse. *)

let test_masc_start_schema () =
  match find_registered_tool "masc_start" with
  | None -> Alcotest.fail "masc_start not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has path" true (List.mem_assoc "path" props);
          Alcotest.(check bool) "has task_title" true
            (List.mem_assoc "task_title" props)
      | None -> Alcotest.fail "masc_start missing properties"

let test_masc_status_schema () =
  match find_registered_tool "masc_status" with
  | None -> Alcotest.fail "masc_status not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          (* masc_status has no required parameters *)
          Alcotest.(check int) "properties can be empty" 0 (List.length props)
      | None -> Alcotest.fail "masc_status missing properties"

let test_masc_broadcast_schema () =
  match find_registered_tool "masc_broadcast" with
  | None -> Alcotest.fail "masc_broadcast not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has message" true (List.mem_assoc "message" props)
      | None -> Alcotest.fail "masc_broadcast missing properties"

let test_masc_transition_schema () =
  match find_registered_tool "masc_transition" with
  | None -> Alcotest.fail "masc_transition not found"
  | Some schema ->
      Alcotest.(check bool) "description omits task required_tools"
        false
        (contains_substring ~needle:"required_tools" schema.description);
      Alcotest.(check bool) "description omits mandatory tools routing"
        false
        (contains_substring ~needle:"mandatory tools" schema.description);
      Alcotest.(check bool) "description omits requires tools routing"
        false
        (contains_substring ~needle:"requires tools" schema.description);
      Alcotest.(check bool) "description pins start before done"
        true
        (contains_substring ~needle:"action='start' before action='done'" schema.description);
      (match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has completion_contract" true
            (List.mem_assoc "completion_contract" props);
          Alcotest.(check bool) "has evaluator_runtime" true
            (List.mem_assoc "evaluator_runtime" props);
          Alcotest.(check bool) "has handoff_context" true
            (List.mem_assoc "handoff_context" props)
      | None -> Alcotest.fail "masc_transition missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "agent_name required" true (List.mem (`String "agent_name") reqs);
          Alcotest.(check bool) "task_id required" true (List.mem (`String "task_id") reqs);
          Alcotest.(check bool) "action required" true (List.mem (`String "action") reqs)
      | None -> Alcotest.fail "masc_transition missing required field"

let run_tool_names =
  [ "masc_run_init"; "masc_run_plan"; "masc_run_get"; "masc_run_list" ]

let test_masc_run_schemas_share_ssot () =
  Alcotest.(check int)
    "run schema count"
    (List.length Tool_schemas_run.schemas)
    (List.length Masc.Tool_run.schemas);
  List.iter2
    (fun (expected : Masc_domain.tool_schema) (actual : Masc_domain.tool_schema) ->
       Alcotest.(check string) "schema name" expected.name actual.name;
       Alcotest.(check string)
         (expected.name ^ " description")
         expected.description
         actual.description;
       Alcotest.(check string)
         (expected.name ^ " input_schema")
         (Yojson.Safe.to_string expected.input_schema)
         (Yojson.Safe.to_string actual.input_schema))
    Tool_schemas_run.schemas
    Masc.Tool_run.schemas

let test_masc_run_schemas_are_strict_and_documented () =
  List.iter
    (fun name ->
       match find_registered_tool name with
       | None -> Alcotest.failf "%s not registered" name
       | Some schema ->
           Alcotest.(check (option bool))
             (name ^ " additionalProperties=false")
             (Some false)
             (get_json_bool "additionalProperties" schema.input_schema))
    run_tool_names;
  List.iter
    (fun (name, properties) ->
       let schema =
         match find_registered_tool name with
         | Some schema -> schema
         | None -> Alcotest.failf "%s not registered" name
       in
       List.iter
         (fun property ->
            Alcotest.(check bool)
              (Printf.sprintf "%s.%s has description" name property)
              true
              (Option.is_some (property_description schema property)))
         properties)
    [ "masc_run_init", [ "task_id"; "agent_name" ]
    ; "masc_run_plan", [ "task_id"; "plan" ]
    ; "masc_run_get", [ "task_id" ]
    ]

let test_masc_add_task_schema () =
  match find_registered_tool "masc_add_task" with
  | None -> Alcotest.fail "masc_add_task not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
       | Some props ->
           Alcotest.(check bool) "has title" true (List.mem_assoc "title" props);
           Alcotest.(check bool) "has priority" true (List.mem_assoc "priority" props);
           Alcotest.(check bool) "has description" true (List.mem_assoc "description" props);
           Alcotest.(check bool) "has goal_id" true (List.mem_assoc "goal_id" props);
           Alcotest.(check bool) "has contract" true (List.mem_assoc "contract" props);
           (match List.assoc_opt "goal_id" props with
            | Some goal_id_schema ->
                let description =
                  Option.value ~default:"" (get_json_string "description" goal_id_schema)
                in
                Alcotest.(check bool) "goal_id is optional in prose" true
                  (contains_substring ~needle:"Optional structured goal link" description);
                Alcotest.(check bool) "goal_id does not reference prompt markers" false
                  (contains_substring ~needle:"<available_goals>" description);
                Alcotest.(check bool) "goal_id does not label omitted links orphaned" false
                  (contains_substring ~needle:"orphaned" description)
            | None -> Alcotest.fail "masc_add_task missing goal_id property")
       | None -> Alcotest.fail "masc_add_task missing properties");
      (match get_json_list "required" schema.input_schema with
       | Some reqs ->
           Alcotest.(check bool) "title required" true
             (List.mem (`String "title") reqs);
           Alcotest.(check bool) "goal_id not required" false
             (List.mem (`String "goal_id") reqs)
       | None -> Alcotest.fail "masc_add_task missing required field")

let test_masc_batch_add_tasks_schema () =
  match find_registered_tool "masc_batch_add_tasks" with
  | None -> Alcotest.fail "masc_batch_add_tasks not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
       | Some props ->
           (match List.assoc_opt "tasks" props with
            | Some tasks_schema ->
                (match get_json_assoc "items" tasks_schema with
                 | Some item_fields ->
                     (match List.assoc_opt "properties" item_fields with
                      | Some (`Assoc item_props) ->
                          Alcotest.(check bool) "item has title" true
                            (List.mem_assoc "title" item_props);
                          Alcotest.(check bool) "item has goal_id" true
                            (List.mem_assoc "goal_id" item_props)
                      | _ -> Alcotest.fail "masc_batch_add_tasks item missing properties");
                     (match List.assoc_opt "required" item_fields with
                      | Some (`List item_reqs) ->
                          Alcotest.(check bool) "item title required" true
                            (List.mem (`String "title") item_reqs);
                          Alcotest.(check bool) "item goal_id not required" false
                            (List.mem (`String "goal_id") item_reqs)
                      | _ -> Alcotest.fail "masc_batch_add_tasks item missing required")
                 | None -> Alcotest.fail "masc_batch_add_tasks tasks missing items")
            | None -> Alcotest.fail "masc_batch_add_tasks missing tasks property")
       | None -> Alcotest.fail "masc_batch_add_tasks missing properties");
      (match get_json_list "required" schema.input_schema with
       | Some reqs ->
           Alcotest.(check bool) "tasks required" true
             (List.mem (`String "tasks") reqs);
           Alcotest.(check bool) "top-level goal_id not required" false
             (List.mem (`String "goal_id") reqs)
       | None -> Alcotest.fail "masc_batch_add_tasks missing required field")

let test_masc_goal_list_schema () =
  match find_registered_tool "masc_goal_list" with
  | None -> Alcotest.fail "masc_goal_list not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "horizon filter removed (RFC-0294)" false (List.mem_assoc "horizon" props);
          Alcotest.(check bool) "has phase" true (List.mem_assoc "phase" props);
          Alcotest.(check bool) "no legacy status filter" false (List.mem_assoc "status" props)
      | None -> Alcotest.fail "masc_goal_list missing properties"

let test_masc_goal_upsert_schema () =
  match find_registered_tool "masc_goal_upsert" with
  | None -> Alcotest.fail "masc_goal_upsert not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has id" true (List.mem_assoc "id" props);
          Alcotest.(check bool) "has title" true (List.mem_assoc "title" props);
          Alcotest.(check bool) "horizon removed (RFC-0294)" false (List.mem_assoc "horizon" props);
          Alcotest.(check bool) "omits status lifecycle field" false
            (List.mem_assoc "status" props);
          Alcotest.(check bool) "omits phase lifecycle field" false
            (List.mem_assoc "phase" props);
          Alcotest.(check bool) "has verifier_policy" true
            (List.mem_assoc "verifier_policy" props);
          Alcotest.(check bool) "has require_completion_approval" true
            (List.mem_assoc "require_completion_approval" props);
          Alcotest.(check bool) "has parent_goal_id" true
            (List.mem_assoc "parent_goal_id" props)
      | None -> Alcotest.fail "masc_goal_upsert missing properties"

let test_masc_goal_transition_schema () =
  match find_registered_tool "masc_goal_transition" with
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
            (List.mem_assoc "note" props);
          Alcotest.(check bool) "has override_note" true
            (List.mem_assoc "override_note" props)
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
  match find_registered_tool "masc_goal_verify" with
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

let test_retired_front_door_tools_absent_from_schema_inventory () =
  let retired_tools =
    [
      "masc_operator_snapshot";
      "masc_operator_digest";
      "masc_operator_action";
      "masc_operator_confirm";
      "masc_operator_judgment_write";
      "masc_keeper_repair";
      "masc_surface_audit";
      "masc_operation_start";
      "masc_dispatch_tick";
      "masc_goal_review";
    ]
  in
  List.iter
    (fun name ->
      match find_registered_tool name with
      | None -> ()
      | Some _ ->
          Alcotest.fail
            (Printf.sprintf
               "%s should be absent from registered schema inventory"
               name))
    retired_tools

let test_masc_board_post_schema_supports_judgment () =
  let schema = Board_tool.tool_post_create in
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
(* 7. Agent Capability Tool Tests                                *)
(* ============================================================ *)

let test_masc_agents_removed () =
  match find_registered_tool "masc_agents" with
  | None -> ()
  | Some _ -> Alcotest.fail "masc_agents should be absent from registered schema inventory"

let test_masc_register_capabilities_removed () =
  match find_registered_tool "masc_register_capabilities" with
  | None -> ()
  | Some _ -> Alcotest.fail "masc_register_capabilities should be removed"

(* test_masc_find_by_capability_schema removed: tool pruned *)

(* ============================================================ *)
(* 8. Plan Tool Tests                                            *)
(* ============================================================ *)

let test_masc_plan_init_schema () =
  match find_registered_tool "masc_plan_init" with
  | None -> Alcotest.fail "masc_plan_init not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has task_id" true (List.mem_assoc "task_id" props)
      | None -> Alcotest.fail "masc_plan_init missing properties"

let test_masc_plan_update_schema () =
  match find_registered_tool "masc_plan_update" with
  | None -> Alcotest.fail "masc_plan_update not found"
  | Some _ -> ()

let test_masc_plan_get_schema () =
  match find_registered_tool "masc_plan_get" with
  | None -> Alcotest.fail "masc_plan_get not found"
  | Some _ -> ()

let test_masc_deliver_schema () =
  match find_registered_tool "masc_deliver" with
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

(* test_masc_spawn_schema removed: masc_spawn deleted in RFC-0182. *)

(* Dedicated runtime-verify schema coverage moved to runtime admin coverage. *)

(* test_masc_persona_list_schema removed: persona list coverage is trivial.
   Persona authoring schema/save tools were removed with their stale backing
   surface. *)

let test_masc_keeper_create_from_persona_schema () =
  match find_registered_tool "masc_keeper_create_from_persona" with
  | None -> Alcotest.fail "masc_keeper_create_from_persona not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has persona_name" true
            (List.mem_assoc "persona_name" props);
          Alcotest.(check bool) "has canonical tool_access" true
            (List.mem_assoc "tool_access" props);
          Alcotest.(check bool) "omits social_model" false
            (List.mem_assoc "social_model" props)
      | None -> Alcotest.fail "masc_keeper_create_from_persona missing properties"

let test_masc_keeper_up_schema () =
  match find_registered_tool "masc_keeper_up" with
  | None -> Alcotest.fail "masc_keeper_up not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "omits sandbox_profile" false
            (List.mem_assoc "sandbox_profile" props);
          Alcotest.(check bool) "omits network_mode" false
            (List.mem_assoc "network_mode" props);
          Alcotest.(check bool) "omits social_model" false
            (List.mem_assoc "social_model" props);
          Alcotest.(check bool) "has autoboot_enabled" true
            (List.mem_assoc "autoboot_enabled" props);
          Alcotest.(check bool) "has canonical tool_access" true
            (List.mem_assoc "tool_access" props);
          Alcotest.(check bool) "omits models" false
            (List.mem_assoc "models" props);
          Alcotest.(check bool) "omits allowed_models" false
            (List.mem_assoc "allowed_models" props);
          Alcotest.(check bool) "omits active_model" false
            (List.mem_assoc "active_model" props)
      | None -> Alcotest.fail "masc_keeper_up missing properties"

let test_keeper_sandbox_args_rejected () =
  let args =
    `Assoc [ "sandbox_profile", `String "docker"; "network_mode", `String "none" ]
  in
  match
    Masc.Keeper_config.reject_removed_keeper_input_keys
      ~tool_name:"masc_keeper_up"
      args
  with
  | Ok () -> Alcotest.fail "sandbox posture args should be rejected"
  | Error msg ->
      Alcotest.(check bool)
        "sandbox_profile mentioned"
        true
        (contains_substring ~needle:"sandbox_profile" msg);
      Alcotest.(check bool)
        "network_mode mentioned"
        true
        (contains_substring ~needle:"network_mode" msg)

let test_keeper_sandbox_args_allowed_for_dashboard_patch () =
  let args =
    `Assoc [ "sandbox_profile", `String "docker"; "network_mode", `String "none" ]
  in
  match
    Masc.Keeper_config.reject_removed_keeper_input_keys
      ~allow_sandbox_fields:true
      ~tool_name:"dashboard_keeper_config_patch"
      args
  with
  | Error msg -> Alcotest.failf "dashboard config patch should accept sandbox posture args: %s" msg
  | Ok () -> ()

let test_masc_keeper_msg_schema () =
  match find_registered_tool "masc_keeper_msg" with
  | None -> Alcotest.fail "masc_keeper_msg not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "omits new_goal" false
            (List.mem_assoc "new_goal" props);
          Alcotest.(check bool) "omits required_tools" false
            (List.mem_assoc "required_tools" props);
          Alcotest.(check bool) "omits required_tool_names" false
            (List.mem_assoc "required_tool_names" props)
      | None -> Alcotest.fail "masc_keeper_msg missing properties"

(* keeper policy schema tests removed — policy tool schemas no longer exist *)

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
      match find_registered_tool name with
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
      match find_registered_tool name with
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
  match find_registered_tool "masc_dashboard" with
  | None -> Alcotest.fail "masc_dashboard not found"
  | Some _ -> ()

let test_masc_keeper_waiting_inventory_schema () =
  match find_registered_tool "masc_keeper_waiting_inventory" with
  | None -> Alcotest.fail "masc_keeper_waiting_inventory not found"
  | Some schema ->
      (match get_json_assoc "properties" schema.input_schema with
       | Some props ->
           Alcotest.(check int)
             "masc_keeper_waiting_inventory has no parameters"
             0
             (List.length props)
       | None -> Alcotest.fail "masc_keeper_waiting_inventory missing properties")

let test_masc_agent_fitness_schema () =
  match find_registered_tool "masc_agent_fitness" with
  | None -> Alcotest.fail "masc_agent_fitness not found"
  | Some _ -> ()

let test_masc_get_metrics_schema () =
  match find_registered_tool "masc_get_metrics" with
  | None -> Alcotest.fail "masc_get_metrics not found"
  | Some _ -> ()

let test_masc_agent_card_schema () =
  match find_registered_tool "masc_agent_card" with
  | None -> Alcotest.fail "masc_agent_card not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has action" true
            (List.mem_assoc "action" props);
          Alcotest.(check bool) "has agent_name" true
            (List.mem_assoc "agent_name" props)
      | None -> Alcotest.fail "masc_agent_card missing properties"

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
    "schema_inventory_lookup", [
      Alcotest.test_case "existing" `Quick test_schema_inventory_lookup_existing;
      Alcotest.test_case "not_found" `Quick test_schema_inventory_lookup_not_found;
      Alcotest.test_case "case_sensitive" `Quick
        test_schema_inventory_lookup_case_sensitive;
    ];
    "input_schema", [
      Alcotest.test_case "type_is_object" `Quick test_input_schema_type_is_object;
      Alcotest.test_case "has_properties" `Quick test_input_schema_has_properties;
      Alcotest.test_case "required_is_list" `Quick test_required_field_is_list;
    ];
    "core_tools", [
      Alcotest.test_case "masc_start" `Quick test_masc_start_schema;
      Alcotest.test_case "masc_status" `Quick test_masc_status_schema;
      Alcotest.test_case "masc_broadcast" `Quick test_masc_broadcast_schema;
      Alcotest.test_case "masc_transition" `Quick test_masc_transition_schema;
      Alcotest.test_case "masc_run schemas share SSOT" `Quick
        test_masc_run_schemas_share_ssot;
      Alcotest.test_case "masc_run schemas strict documented" `Quick
        test_masc_run_schemas_are_strict_and_documented;
      Alcotest.test_case "masc_add_task" `Quick test_masc_add_task_schema;
      Alcotest.test_case "masc_batch_add_tasks" `Quick
        test_masc_batch_add_tasks_schema;
      Alcotest.test_case "masc_board_post supports judgment" `Quick
        test_masc_board_post_schema_supports_judgment;
      Alcotest.test_case "retired front-door tools absent" `Quick
        test_retired_front_door_tools_absent_from_schema_inventory;
    ];
    "agent_tools", [
      Alcotest.test_case "agents removed" `Quick test_masc_agents_removed;
      Alcotest.test_case "register_capabilities removed" `Quick
        test_masc_register_capabilities_removed;
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
      Alcotest.test_case "goal_transition" `Quick test_masc_goal_transition_schema;
      Alcotest.test_case "goal_verify" `Quick test_masc_goal_verify_schema;
    ];
    "vote_tools", [
    ];
    (* auth_tools, a2a_tools (poll_events/heartbeat_result), handover_tools,
       bounded_run removed: pruned from registry *)
    (* spawn_runtime_tools group removed: masc_spawn deleted in RFC-0182. *)
    "keeper_runtime_tools", [
      Alcotest.test_case "keeper-create-from-persona" `Quick
        test_masc_keeper_create_from_persona_schema;
      Alcotest.test_case "keeper-up" `Quick
        test_masc_keeper_up_schema;
      Alcotest.test_case "keeper-sandbox-args-rejected" `Quick
        test_keeper_sandbox_args_rejected;
      Alcotest.test_case "keeper-sandbox-args-dashboard-allowed" `Quick
        test_keeper_sandbox_args_allowed_for_dashboard_patch;
      Alcotest.test_case "keeper-msg" `Quick
        test_masc_keeper_msg_schema;
    ];
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
      Alcotest.test_case "keeper_waiting_inventory" `Quick
        test_masc_keeper_waiting_inventory_schema;
      Alcotest.test_case "agent_fitness" `Quick test_masc_agent_fitness_schema;
      Alcotest.test_case "get_metrics" `Quick test_masc_get_metrics_schema;
      Alcotest.test_case "agent_card" `Quick test_masc_agent_card_schema;
    ];
    "transport_tools", [
    ];
    "edge_cases", [
      Alcotest.test_case "description_not_short" `Quick test_description_not_too_short;
      Alcotest.test_case "description_not_long" `Quick test_description_not_too_long;
      Alcotest.test_case "no_duplicate_props" `Quick test_no_duplicate_properties;
      Alcotest.test_case "valid_prop_types" `Quick test_property_types_valid;
    ];
  ]
