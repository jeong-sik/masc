(** Comprehensive Tests for Tools module - MCP Tool Definitions *)

open Masc_domain

(* One inventory: the registry the server actually serves. [Tools] used to
   expose a separate [all_schemas_extended] list that no production code read,
   and these tests validated that list instead of this one. *)
let schema_inventory = Masc.Config.raw_all_tool_schemas
let registered_schema_inventory = schema_inventory

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

(* ============================================================ *)
(* 1. Schema Structure Tests                                     *)
(* ============================================================ *)

let test_all_schemas_not_empty () =
  Alcotest.(check bool) "all_schemas is not empty"
    true (List.length schema_inventory > 0)

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

(* The registry uses three namespaces, not one: [masc_] for coordination,
   [keeper_] for keeper-scoped surfaces, [tool_] for exec/file primitives.
   Pinning the set is what catches an unprefixed or typo'd tool name; the
   earlier single-[masc_] rule held only because these tests ran against a
   47-schema list the server never served. *)
let tool_name_namespaces = [ "masc_"; "keeper_"; "tool_" ]

let test_all_names_start_with_masc () =
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s uses a known namespace" schema.name)
        true
        (List.exists
           (fun prefix ->
             String.length schema.name >= String.length prefix
             && String.equal (String.sub schema.name 0 (String.length prefix)) prefix)
           tool_name_namespaces))
    schema_inventory

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
          (* masc_status has no required parameters, but accepts the optional
             producer-owned conditional snapshot revision. *)
          Alcotest.(check bool) "has optional if_revision" true
            (List.mem_assoc "if_revision" props)
      | None -> Alcotest.fail "masc_status missing properties"

let test_masc_broadcast_schema () =
  match find_registered_tool "masc_broadcast" with
  | None -> Alcotest.fail "masc_broadcast not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has agent_name" true (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has content" true (List.mem_assoc "content" props);
          Alcotest.(check bool)
            "has typed cache subject"
            true
            (List.mem_assoc "task_cache_subject_agent" props);
          Alcotest.(check bool)
            "has typed cache task"
            true
            (List.mem_assoc "task_cache_task_id" props);
          (match get_json_list "required" schema.input_schema with
           | Some required ->
             Alcotest.(check bool)
               "typed cache subject is optional"
               false
               (List.mem (`String "task_cache_subject_agent") required);
             Alcotest.(check bool)
               "typed cache task is optional"
               false
               (List.mem (`String "task_cache_task_id") required)
           | None -> Alcotest.fail "masc_broadcast missing required field");
          (* The body is named "content" on every surface that carries it —
             board post, surface post, file write, and this tool's own result
             payload. A stray "message" here is the fork that cost a keeper
             turn on 2026-08-16, so its absence is asserted too. *)
          Alcotest.(check bool) "no stray message field" false
            (List.mem_assoc "message" props)
      | None -> Alcotest.fail "masc_broadcast missing properties"

let test_broadcast_cache_signal_reaches_keeper_and_agent_core_surfaces () =
  let assert_optional_pair label schema =
    match get_json_assoc "properties" schema with
    | None -> Alcotest.fail (label ^ " missing properties")
    | Some props ->
      Alcotest.(check bool)
        (label ^ " has typed cache subject")
        true
        (List.mem_assoc "task_cache_subject_agent" props);
      Alcotest.(check bool)
        (label ^ " has typed cache task")
        true
        (List.mem_assoc "task_cache_task_id" props)
  in
  let keeper_schema =
    Tool_shard_types.taskboard_tools
    |> List.find_opt (fun (schema : Masc_domain.tool_schema) ->
      String.equal schema.name "keeper_broadcast")
  in
  (match keeper_schema with
   | None -> Alcotest.fail "keeper_broadcast schema missing"
   | Some schema -> assert_optional_pair "keeper_broadcast" schema.input_schema);
  let binding =
    Masc.Agent_core_tool_contract.agent_core_binding_by_name "masc_broadcast"
  in
  (match binding with
   | None -> Alcotest.fail "agent-core masc_broadcast binding missing"
   | Some binding -> assert_optional_pair "agent-core masc_broadcast" binding.input_schema);
  let arguments =
    `Assoc
      [ "content", `String "typed cache observation"
      ; "task_cache_subject_agent", `String "subject"
      ; "task_cache_task_id", `String "task-123"
      ]
  in
  match
    Masc.Agent_core_tool_contract.resolve_requested_tool_call
      ~agent_name:"observer"
      ~requested_name:"masc_broadcast"
      ~arguments
  with
  | Error detail -> Alcotest.fail ("agent-core broadcast projection failed: " ^ detail)
  | Ok (operation, `Assoc projected) ->
    Alcotest.(check string) "canonical broadcast operation" "masc_broadcast" operation;
    Alcotest.(check (option string))
      "agent-core preserves typed cache subject"
      (Some "subject")
      (Option.bind
         (List.assoc_opt "task_cache_subject_agent" projected)
         (function `String value -> Some value | _ -> None));
    Alcotest.(check (option string))
      "agent-core preserves typed cache task"
      (Some "task-123")
      (Option.bind
         (List.assoc_opt "task_cache_task_id" projected)
         (function `String value -> Some value | _ -> None))
  | Ok (_, _) -> Alcotest.fail "agent-core broadcast projection is not an object"

let test_masc_transition_schema () =
  match find_registered_tool "masc_transition" with
  | None -> Alcotest.fail "masc_transition not found"
  | Some schema ->
      Alcotest.(check bool) "description omits task required_tools"
        false
        (String_util.string_contains_substring ~needle:"required_tools" schema.description);
      Alcotest.(check bool) "description omits mandatory tools routing"
        false
        (String_util.string_contains_substring ~needle:"mandatory tools" schema.description);
      Alcotest.(check bool) "description omits requires tools routing"
        false
        (String_util.string_contains_substring ~needle:"requires tools" schema.description);
      Alcotest.(check bool) "description omits configured completion reviewer"
        false
        (String_util.string_contains_substring
           ~needle:"configured LLM completion reviewer"
           schema.description);
      (* RFC-0323 G-4: the weak-lane teaching sentence must stay gone. *)
      Alcotest.(check bool) "description omits the verifier-bypass teaching"
        false
        (String_util.string_contains_substring
           ~needle:"do not route normal completion"
           schema.description);
      (match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "no transition completion_contract input" false
            (List.mem_assoc "completion_contract" props);
          Alcotest.(check bool) "no transition evaluator_runtime input" false
            (List.mem_assoc "evaluator_runtime" props);
          Alcotest.(check bool) "no configured_llm_verdict input" false
            (List.mem_assoc "configured_llm_verdict" props);
          Alcotest.(check bool) "no caller-controlled agent_name input" false
            (List.mem_assoc "agent_name" props);
          Alcotest.(check bool) "has handoff_context" true
            (List.mem_assoc "handoff_context" props)
      | None -> Alcotest.fail "masc_transition missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "agent_name is not caller input" false
            (List.mem (`String "agent_name") reqs);
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
      let managed_binding =
        match
          Masc.Agent_core_tool_contract.agent_core_binding_by_name
            "masc_add_task"
        with
        | Some binding -> binding
        | None -> Alcotest.fail "managed masc_add_task binding missing"
      in
      Alcotest.(check string)
        "managed profile uses canonical description"
        schema.description
        managed_binding.description;
      Alcotest.(check string)
        "managed profile uses canonical input schema"
        (Yojson.Safe.to_string schema.input_schema)
        (Yojson.Safe.to_string managed_binding.input_schema);
      let managed_schema =
        match
          List.find_opt
            (fun (candidate : Masc_domain.tool_schema) ->
               String.equal candidate.name "masc_add_task")
            Masc.Agent_core_tool_contract.agent_core_tool_schemas
        with
        | Some managed_schema -> managed_schema
        | None -> Alcotest.fail "managed profile schema missing masc_add_task"
      in
      Alcotest.(check string)
        "managed discovery and full discovery are schema-identical"
        (Yojson.Safe.to_string schema.input_schema)
        (Yojson.Safe.to_string managed_schema.input_schema);
      (match get_json_assoc "properties" schema.input_schema with
       | Some props ->
           Alcotest.(check bool) "has title" true (List.mem_assoc "title" props);
           Alcotest.(check bool) "has priority" true (List.mem_assoc "priority" props);
           Alcotest.(check bool) "has description" true (List.mem_assoc "description" props);
           Alcotest.(check bool) "has goal_id" true (List.mem_assoc "goal_id" props);
           Alcotest.(check bool) "has contract" true (List.mem_assoc "contract" props);
           Alcotest.(check bool) "has skills" true (List.mem_assoc "skills" props);
           (match List.assoc_opt "goal_id" props with
            | Some goal_id_schema ->
                let description =
                  Option.value ~default:"" (get_json_string "description" goal_id_schema)
                in
                Alcotest.(check bool) "goal_id is optional in prose" true
                  (String_util.string_contains_substring ~needle:"Optional structured goal link" description);
                Alcotest.(check bool) "goal_id does not reference prompt markers" false
                  (String_util.string_contains_substring ~needle:"<available_goals>" description);
                Alcotest.(check bool) "goal_id does not label omitted links orphaned" false
                  (String_util.string_contains_substring ~needle:"orphaned" description)
            | None -> Alcotest.fail "masc_add_task missing goal_id property")
          ; (match List.assoc_opt "contract" props with
             | Some contract_schema ->
               Alcotest.(check (option bool))
                 "contract rejects additional properties"
                 (Some false)
                 (get_json_bool "additionalProperties" contract_schema)
             | None -> Alcotest.fail "masc_add_task missing contract property")
          ; (match List.assoc_opt "skills" props with
             | None -> Alcotest.fail "masc_add_task missing skills property"
             | Some skills_schema ->
               let item_fields =
                 match get_json_assoc "items" skills_schema with
                 | Some fields -> fields
                 | None -> Alcotest.fail "masc_add_task skills missing item schema"
               in
               let item_schema = `Assoc item_fields in
               Alcotest.(check (option bool))
                 "Skill references reject additional properties"
                 (Some false)
                 (get_json_bool "additionalProperties" item_schema);
               let reference_properties =
                 match get_json_assoc "properties" item_schema with
                 | Some properties -> properties
                 | None -> Alcotest.fail "Skill reference missing properties"
               in
               Alcotest.(check bool)
                 "Skill reference has identity"
                 true
                 (List.mem_assoc "identity" reference_properties);
               Alcotest.(check bool)
                 "Skill reference has content revision"
                 true
                 (List.mem_assoc "content_revision" reference_properties);
               let identity_schema =
                 match List.assoc_opt "identity" reference_properties with
                 | Some schema -> schema
                 | None -> Alcotest.fail "Skill reference identity missing"
               in
               Alcotest.(check (option bool))
                 "Skill identity rejects additional properties"
                 (Some false)
                 (get_json_bool "additionalProperties" identity_schema))
       | None -> Alcotest.fail "masc_add_task missing properties");
      (match get_json_list "required" schema.input_schema with
       | Some reqs ->
           Alcotest.(check bool) "title required" true
             (List.mem (`String "title") reqs);
           Alcotest.(check bool) "goal_id not required" false
             (List.mem (`String "goal_id") reqs)
       | None -> Alcotest.fail "masc_add_task missing required field");
      let skills =
        `List
          [ `Assoc
              [ ( "identity"
                , `Assoc
                    [ "source_id", `String "project-masc"
                    ; "package_id", `String "ocaml-coding"
                    ; "name", `String "ocaml-coding"
                    ] )
              ; "content_revision", `String (String.make 64 'a')
              ]
          ]
      in
      let arguments =
        `Assoc
          [ "title", `String "Exact Skill Task"
          ; "description", `String "Managed profile"
          ; "skills", skills
          ]
      in
      (match
         Masc.Agent_core_tool_contract.resolve_requested_tool_call
           ~agent_name:"managed"
           ~requested_name:"masc_add_task"
           ~arguments
       with
       | Ok ("masc_add_task", projected) ->
         Alcotest.(check string)
           "managed projection preserves exact Skill references"
           (Yojson.Safe.to_string arguments)
           (Yojson.Safe.to_string projected)
       | Ok (name, _) -> Alcotest.failf "unexpected operation %s" name
       | Error detail -> Alcotest.fail detail)

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
                            (List.mem_assoc "goal_id" item_props);
                          (match List.assoc_opt "contract" item_props with
                           | Some contract_schema ->
                             Alcotest.(check (option bool))
                               "item contract rejects additional properties"
                               (Some false)
                               (get_json_bool
                                  "additionalProperties"
                                  contract_schema)
                           | None ->
                             Alcotest.fail
                               "masc_batch_add_tasks item missing contract")
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
          Alcotest.(check bool) "has phase" true (List.mem_assoc "phase" props);
          Alcotest.(check bool) "status is not accepted" false (List.mem_assoc "status" props)
      | None -> Alcotest.fail "masc_goal_list missing properties"

let test_masc_goal_upsert_schema () =
  match find_registered_tool "masc_goal_upsert" with
  | None -> Alcotest.fail "masc_goal_upsert not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has id" true (List.mem_assoc "id" props);
          Alcotest.(check bool) "has title" true (List.mem_assoc "title" props);
          Alcotest.(check bool) "omits status lifecycle field" false
            (List.mem_assoc "status" props);
          Alcotest.(check bool) "omits phase lifecycle field" false
            (List.mem_assoc "phase" props)
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
          Alcotest.(check bool) "actor is authenticated context, not input" false
            (List.mem_assoc "actor" props);
          Alcotest.(check bool) "has note" true
            (List.mem_assoc "note" props);
          Alcotest.(check bool) "verifier evidence is not public input" false
            (List.mem_assoc "evidence" props);
          (match List.assoc_opt "action" props with
           | Some action_schema ->
             Alcotest.(check (list string))
               "only lifecycle actions are public"
               [ "request_complete"; "drop"; "reopen" ]
               (match get_json_list "enum" action_schema with
                | Some values ->
                  List.map
                    (function
                      | `String value -> value
                      | json -> Alcotest.fail ("non-string action enum: " ^ Yojson.Safe.to_string json))
                    values
                | None -> Alcotest.fail "masc_goal_transition action enum missing")
           | None -> Alcotest.fail "masc_goal_transition action missing")
      | None -> Alcotest.fail "masc_goal_transition missing properties");
      match get_json_list "required" schema.input_schema with
      | Some reqs ->
          Alcotest.(check bool) "goal_id required" true
            (List.mem (`String "goal_id") reqs);
          Alcotest.(check bool) "action required" true
            (List.mem (`String "action") reqs);
          Alcotest.(check bool) "actor is not required input" false
            (List.mem (`String "actor") reqs)
      | None -> Alcotest.fail "masc_goal_transition missing required field"

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


(* ============================================================ *)
(* 11. A2A Tool Tests                                            *)
(* ============================================================ *)


(* Dedicated runtime-verify schema coverage moved to runtime admin coverage. *)

let test_masc_keeper_up_schema () =
  match find_registered_tool "masc_keeper_up" with
  | None -> Alcotest.fail "masc_keeper_up not found"
  | Some schema ->
      match get_json_assoc "properties" schema.input_schema with
      | Some props ->
          Alcotest.(check bool) "has sandbox_profile" true
            (List.mem_assoc "sandbox_profile" props);
          Alcotest.(check bool) "omits network_mode" false
            (List.mem_assoc "network_mode" props);
          Alcotest.(check bool) "has autoboot_enabled" true
            (List.mem_assoc "autoboot_enabled" props)
      | None -> Alcotest.fail "masc_keeper_up missing properties"

(* ============================================================ *)
(* 19. Bounded Run Tool Tests                                    *)
(* ============================================================ *)


(* ============================================================ *)
(* 20. Dashboard Tool Tests                                      *)
(* ============================================================ *)

let test_masc_dashboard_schema () =
  match find_registered_tool "masc_dashboard" with
  | None -> Alcotest.fail "masc_dashboard not found"
  | Some _ -> ()

(* The enum the model reads and the vocabulary Dashboard accepts sit on
   opposite sides of the cut that keeps the descriptor generator out of its own
   consumer, and they used to be spelled separately (#27069). A scope in one
   and not the other either hides it from the model or advertises one the
   runtime refuses. *)
let test_masc_dashboard_scope_enum_matches_the_runtime () =
  match find_registered_tool "masc_dashboard" with
  | None -> Alcotest.fail "masc_dashboard not found"
  | Some schema ->
    let enum =
      match get_json_assoc "properties" schema.input_schema with
      | None -> Alcotest.fail "masc_dashboard missing properties"
      | Some props ->
        (match List.assoc_opt "scope" props with
         | None -> Alcotest.fail "masc_dashboard has no scope parameter"
         | Some scope_schema ->
           (match Yojson.Safe.Util.member "enum" scope_schema with
            | `List values ->
              List.map
                (function
                  | `String value -> value
                  | other ->
                    Alcotest.failf
                      "scope enum holds a non-string: %s"
                      (Yojson.Safe.to_string other))
                values
            | _ -> Alcotest.fail "masc_dashboard scope has no enum"))
    in
    Alcotest.(check (list string))
      "the schema enum is what Dashboard accepts"
      Dashboard.valid_scope_strings
      enum;
    List.iter
      (fun value ->
        Alcotest.(check bool)
          (Printf.sprintf "the runtime parses the advertised scope %S" value)
          true
          (Option.is_some (Dashboard.scope_of_string_opt value)))
      enum

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
(* Keeper runtime front door                                     *)
(* ============================================================ *)

(* A keeper whose context outgrows its provider window cannot shrink it on its
   own, so an explicit compaction request is the operator's escape hatch. It
   must therefore be reachable from the MCP front door, not only from the
   keeper-internal tool surface. *)
let test_keeper_compact_is_public_mcp () =
  Alcotest.(check bool)
    "masc_keeper_compact is on the public MCP surface"
    true
    (Tool_catalog.is_public_mcp "masc_keeper_compact")
;;

(* Pin the deliberate scope boundary: [masc_keeper_clear] wipes transcript
   messages, which is a different operator decision from asking a keeper to
   compact. Opening the escape hatch must not also expose the destructive one. *)
let test_keeper_clear_stays_internal () =
  Alcotest.(check bool)
    "masc_keeper_clear stays off the public MCP surface"
    false
    (Tool_catalog.is_public_mcp "masc_keeper_clear")
;;

(* ============================================================ *)
(* Test Runner                                                   *)
(* ============================================================ *)

let () =
  Alcotest.run "Tools Coverage" [
    "schema_structure", [
      Alcotest.test_case "not_empty" `Quick test_all_schemas_not_empty;
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
      Alcotest.test_case "broadcast cache signal surfaces" `Quick
        test_broadcast_cache_signal_reaches_keeper_and_agent_core_surfaces;
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
    ];
    "vote_tools", [
    ];
    "keeper_runtime_tools", [
      Alcotest.test_case "keeper-up" `Quick
        test_masc_keeper_up_schema;
    ];
    "dashboard_tools", [
      Alcotest.test_case "dashboard" `Quick test_masc_dashboard_schema;
      Alcotest.test_case "dashboard scope enum matches the runtime" `Quick
        test_masc_dashboard_scope_enum_matches_the_runtime;
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
    "keeper_front_door", [
      Alcotest.test_case "compact_is_public_mcp" `Quick
        test_keeper_compact_is_public_mcp;
      Alcotest.test_case "clear_stays_internal" `Quick
        test_keeper_clear_stays_internal;
    ];
  ]
