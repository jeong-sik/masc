type arg_source =
  | Input_field of string
  | Static of Yojson.Safe.t
  | Agent_name

type sdk_tool_binding = {
  sdk_name : string;
  canonical_operation : string;
  description : string;
  input_schema : Yojson.Safe.t;
  arg_bindings : (string * arg_source) list;
  discovery_hidden : bool;
}

let assoc_field name value = (name, value)

let json_string value = `String value

let string_prop = Tool_schema_dsl.string_prop
let object_schema = Tool_schema_dsl.object_schema

let task_item_schema =
  object_schema ~required:[ "title"; "description" ]
    [
      assoc_field "title" (string_prop "Task title");
      assoc_field "description" (string_prop "Task description");
    ]

let sdk_bindings : sdk_tool_binding list =
  [
    {
      sdk_name = "masc_list_tasks";
      canonical_operation = "masc_tasks";
      description = "List all tasks in the MASC room with status, assignee, and priority. Use after joining a room to find available work or check what others are doing.";
      input_schema = object_schema [];
      arg_bindings = [];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_room_status";
      canonical_operation = "masc_status";
      description = "Get the current MASC room status including agents and tasks.";
      input_schema = object_schema [];
      arg_bindings = [];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_add_task";
      canonical_operation = "masc_add_task";
      description = "Create a single new task in the MASC room backlog. Use when you identify work that any agent can pick up. Returns a task-XXX ID for tracking.";
      input_schema =
        object_schema ~required:[ "title"; "description" ]
          [
            assoc_field "title" (string_prop "Task title");
            assoc_field "description" (string_prop "Task description");
          ];
      arg_bindings =
        [
          ("title", Input_field "title");
          ("description", Input_field "description");
        ];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_batch_add_tasks";
      canonical_operation = "masc_batch_add_tasks";
      description = "Create multiple tasks at once for planner-driven decomposition.";
      input_schema =
        object_schema ~required:[ "tasks" ]
          [
            ( "tasks",
              `Assoc
                [
                  assoc_field "type" (`String "array");
                  assoc_field "description"
                    (`String "Array of {title, description} task objects");
                  assoc_field "minItems" (`Int 1);
                  assoc_field "items" task_item_schema;
                ] );
          ];
      arg_bindings = [ ("tasks", Input_field "tasks") ];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_claim_task";
      canonical_operation = "masc_transition";
      description = "Claim a specific task by task_id, locking it to your agent. Use when you want a particular task rather than the next available one.";
      input_schema =
        object_schema ~required:[ "task_id" ]
          [ assoc_field "task_id" (string_prop "The task ID to claim") ];
      arg_bindings =
        [
          ("action", Static (json_string "claim"));
          ("agent_name", Agent_name);
          ("task_id", Input_field "task_id");
        ];
      discovery_hidden = true;
    };
    {
      sdk_name = "masc_claim_next";
      canonical_operation = "masc_claim_next";
      description = "Claim the next available task automatically by priority order. Use when you are ready to work and any pending task is acceptable.";
      input_schema = object_schema [];
      arg_bindings = [ ("agent_name", Agent_name) ];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_set_current_task";
      canonical_operation = "masc_plan_set_task";
      description =
        "Bind the claimed task as current_task when your claim path did not do it automatically.";
      input_schema =
        object_schema ~required:[ "task_id" ]
          [
            assoc_field "task_id"
              (string_prop
                 "The claimed task ID to bind as the current planning task");
          ];
      arg_bindings = [ ("task_id", Input_field "task_id") ];
      discovery_hidden = true;
    };
    {
      sdk_name = "masc_complete_task";
      canonical_operation = "masc_transition";
      description = "Mark a task as done after finishing the work and verification. Use when implementation is complete to release the task from your assignment.";
      input_schema =
        object_schema ~required:[ "task_id" ]
          [
            assoc_field "task_id"
              (string_prop "The task ID to mark as completed");
          ];
      arg_bindings =
        [
          ("action", Static (json_string "done"));
          ("agent_name", Agent_name);
          ("task_id", Input_field "task_id");
        ];
      discovery_hidden = true;
    };
    {
      sdk_name = "masc_release_task";
      canonical_operation = "masc_transition";
      description =
        "Release a claimed task back to pending for another worker.";
      input_schema =
        object_schema ~required:[ "task_id" ]
          [ assoc_field "task_id" (string_prop "The task ID to release") ];
      arg_bindings =
        [
          ("action", Static (json_string "release"));
          ("agent_name", Agent_name);
          ("task_id", Input_field "task_id");
        ];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_cancel_task";
      canonical_operation = "masc_transition";
      description =
        "Cancel a task permanently when it should not be retried.";
      input_schema =
        object_schema ~required:[ "task_id" ]
          [
            assoc_field "task_id" (string_prop "The task ID to cancel");
            assoc_field "reason" (string_prop "Optional cancellation reason");
          ];
      arg_bindings =
        [
          ("action", Static (json_string "cancel"));
          ("agent_name", Agent_name);
          ("task_id", Input_field "task_id");
          ("reason", Input_field "reason");
        ];
      discovery_hidden = false;
    };
    {
      sdk_name = "masc_broadcast";
      canonical_operation = "masc_broadcast";
      description = "Broadcast a message to all agents currently in the room. Use when sharing status updates, coordination signals, or requesting help from any available agent.";
      input_schema =
        object_schema ~required:[ "message" ]
          [
            assoc_field "message" (string_prop "The message to broadcast");
          ];
      arg_bindings =
        [
          ("agent_name", Agent_name);
          ("message", Input_field "message");
        ];
      discovery_hidden = false;
    };
    { sdk_name = "masc_heartbeat";
      canonical_operation = "masc_heartbeat";
      description =
        "Send an immediate heartbeat so this agent stays fresh in MASC visibility.";
      input_schema = object_schema [];
      arg_bindings = [ ("agent_name", Agent_name) ];
      discovery_hidden = false;
    };
  ]

let sdk_binding_by_name name =
  List.find_opt (fun binding -> String.equal binding.sdk_name name) sdk_bindings

let sdk_aliases_for_operation operation_id =
  List.filter
    (fun binding -> String.equal binding.canonical_operation operation_id)
    sdk_bindings

let dedupe_strings values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if Hashtbl.mem seen value then
        false
      else (
        Hashtbl.add seen value true;
        true))
    values

let core_remote_operation_names =
  dedupe_strings
    (List.map (fun binding -> binding.canonical_operation) sdk_bindings
    @ [
        "masc_join";
        "masc_leave";
        "masc_who";
        "masc_agents";
        "masc_agent_update";
        "masc_messages";
        "masc_a2a_subscribe";
        "masc_plan_init";
        "masc_plan_get";
        "masc_plan_update";
        "masc_note_add";
        "masc_deliver";
        "masc_operator_snapshot";
        "masc_operator_digest";
        "masc_operator_action";
        "masc_operator_confirm";
        "masc_operation_start";
        "masc_operation_status";
        "masc_dispatch_plan";
        "masc_dispatch_tick";
        "masc_policy_approve";
        "masc_policy_freeze_unit";
        "masc_policy_kill_switch";
        "masc_observe_operations";
        "masc_observe_capacity";
        "masc_observe_traces";
        "decision_create";
        "decision_finalize";
        "decision_status";
        "masc_petition_submit";
        "masc_case_brief_submit";
        "masc_cases";
        "masc_case_status";
        "masc_ruling_status";
        "masc_execution_orders";
      ])

let find_property properties key =
  List.assoc_opt key properties

let assoc_members = function
  | `Assoc pairs -> Some pairs
  | _ -> None

let string_member name json =
  match Option.bind (assoc_members json) (fun pairs -> find_property pairs name) with
  | Some (`String value) -> Some value
  | _ -> None

let int_member name json =
  match Option.bind (assoc_members json) (fun pairs -> find_property pairs name) with
  | Some (`Int value) -> Some value
  | _ -> None

let required_names schema =
  match Option.bind (assoc_members schema) (fun pairs -> find_property pairs "required") with
  | Some (`List items) ->
      List.filter_map (function `String value -> Some value | _ -> None) items
  | _ -> []

let property_map schema =
  match Option.bind (assoc_members schema) (fun pairs -> find_property pairs "properties") with
  | Some (`Assoc props) -> props
  | _ -> []

let schema_type schema =
  match string_member "type" schema with
  | Some value -> value
  | None -> if property_map schema <> [] then "object" else "string"

let label_or_default label fallback =
  match label with
  | Some value when String.trim value <> "" -> value
  | _ -> fallback

let rec validate_json_value ?label schema value =
  let label = label_or_default label "input" in
  match schema_type schema with
  | "object" -> (
      match value with
      | `Assoc pairs ->
          let required = required_names schema in
          let properties = property_map schema in
          let missing =
            List.find_opt (fun name -> not (List.mem_assoc name pairs)) required
          in
          (match missing with
          | Some name -> Error (Printf.sprintf "missing required field: %s" name)
          | None ->
              let rec validate_props = function
                | [] -> Ok ()
                | (name, property_schema) :: rest -> (
                    match List.assoc_opt name pairs with
                    | None -> validate_props rest
                    | Some property_value -> (
                        match
                          validate_json_value ~label:name property_schema
                            property_value
                        with
                        | Ok () -> validate_props rest
                        | Error _ as error -> error))
              in
              validate_props properties)
      | _ -> Error (Printf.sprintf "%s must be a JSON object" label))
  | "array" -> (
      match value with
      | `List items ->
          let min_items = int_member "minItems" schema |> Option.value ~default:0 in
          if min_items > 0 && List.length items < min_items then
            Error (Printf.sprintf "%s must be a non-empty JSON array" label)
          else (
            match Option.bind (assoc_members schema) (fun pairs -> find_property pairs "items") with
            | None -> Ok ()
            | Some item_schema ->
                let rec validate_items = function
                  | [] -> Ok ()
                  | item :: rest -> (
                      match validate_json_value ~label item_schema item with
                      | Ok () -> validate_items rest
                      | Error _ as error -> error)
                in
                validate_items items)
      | _ -> Error (Printf.sprintf "%s must be a JSON array" label))
  | "string" -> (
      match value with
      | `String _ -> Ok ()
      | _ -> Error (Printf.sprintf "%s must be a string" label))
  | "integer" -> (
      match value with
      | `Int _ -> Ok ()
      | _ -> Error (Printf.sprintf "%s must be an integer" label))
  | "number" -> (
      match value with
      | `Int _ | `Float _ -> Ok ()
      | _ -> Error (Printf.sprintf "%s must be a number" label))
  | "boolean" -> (
      match value with
      | `Bool _ -> Ok ()
      | _ -> Error (Printf.sprintf "%s must be a boolean" label))
  | _ -> Ok ()

let validate_input_json schema json =
  validate_json_value ~label:"input" schema json

(* Strict classifier: returns [None] for unknown JSON Schema types so
   callers can distinguish "rule fired" from "fall-through default".
   See #8832. *)
let param_type_of_schema_opt schema : Oas.Types.param_type option =
  match schema_type schema with
  | "string" -> Some Oas.Types.String
  | "integer" -> Some Oas.Types.Integer
  | "number" -> Some Oas.Types.Number
  | "boolean" -> Some Oas.Types.Boolean
  | "array" -> Some Oas.Types.Array
  | "object" -> Some Oas.Types.Object
  | _ -> None

(* Back-compat wrapper: warns once per unknown JSON Schema type and falls
   back to [String] (the legacy permissive default mirrored by the
   upstream Oas.Mcp.json_schema_type_to_param_type). The warn
   converts the silent #8605-family fallback into an observable signal
   without changing the tool-registration result. *)
let param_type_of_schema schema =
  match param_type_of_schema_opt schema with
  | Some t -> t
  | None ->
      Log.Misc.warn
        "param_type_of_schema: unknown JSON Schema type %S -> String (drift; see #8832)"
        (schema_type schema);
      Oas.Types.String

let tool_params_of_input_schema schema =
  let required = required_names schema in
  property_map schema
  |> List.map (fun (name, property_schema) ->
         let description =
           string_member "description" property_schema
           |> Option.value ~default:(Printf.sprintf "%s parameter" name)
         in
         let param : Oas.Types.tool_param =
           {
             name;
             description;
             param_type = param_type_of_schema property_schema;
             required = List.mem name required;
           }
         in
         param)

let build_operation_arguments ~agent_name binding json =
  match validate_input_json binding.input_schema json with
  | Error _ as error -> error
  | Ok () -> (
      match json with
      | `Assoc input_fields ->
          let lookup_input name = List.assoc_opt name input_fields in
          let rec build acc = function
            | [] -> Ok (`Assoc (List.rev acc))
            | (target_name, source) :: rest -> (
                match source with
                | Static value -> build ((target_name, value) :: acc) rest
                | Agent_name ->
                    build ((target_name, `String agent_name) :: acc) rest
                | Input_field field_name -> (
                    match lookup_input field_name with
                    | Some value -> build ((target_name, value) :: acc) rest
                    | None -> build acc rest))
          in
          build [] binding.arg_bindings
      | _ -> Error "input must be a JSON object")

let resolve_requested_tool_call ~agent_name ~requested_name ~arguments =
  match sdk_binding_by_name requested_name with
  | None -> Ok (requested_name, arguments)
  | Some binding ->
      build_operation_arguments ~agent_name binding arguments
      |> Result.map (fun translated_arguments ->
             (binding.canonical_operation, translated_arguments))

let sdk_alias_json binding =
  let static_arguments =
    binding.arg_bindings
    |> List.filter_map (fun (target, source) ->
           match source with
           | Static value -> Some (target, value)
           | Input_field _ | Agent_name -> None)
  in
  let argument_mapping =
    binding.arg_bindings
    |> List.filter_map (fun (target, source) ->
           match source with
           | Input_field field -> Some (target, `String field)
           | Static _ | Agent_name -> None)
  in
  let inject_agent_name =
    List.exists
      (fun (_target, source) ->
        match source with Agent_name -> true | Input_field _ | Static _ -> false)
      binding.arg_bindings
  in
  `Assoc
    [
      ("name", `String binding.sdk_name);
      ("description", `String binding.description);
      ("canonicalOperationId", `String binding.canonical_operation);
      ("inputSchema", binding.input_schema);
      ("argumentMapping", `Assoc argument_mapping);
      ("staticArguments", `Assoc static_arguments);
      ("injectAgentName", `Bool inject_agent_name);
    ]

let sdk_tool_schemas : Types.tool_schema list =
  List.map
    (fun (binding : sdk_tool_binding) ->
      {
        Types.name = binding.sdk_name;
        description = binding.description;
        input_schema = binding.input_schema;
      })
    (List.filter (fun binding -> not binding.discovery_hidden) sdk_bindings)
