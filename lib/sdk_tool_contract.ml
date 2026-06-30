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
      sdk_name = "masc_add_task";
      canonical_operation = "masc_add_task";
      description = "Create a single new task in the MASC backlog. Use when you identify work that any agent can pick up. Returns a task-XXX ID for tracking.";
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
    };
    {
      sdk_name = "masc_broadcast";
      canonical_operation = "masc_broadcast";
      description = "Broadcast a message to all active agents. Use when sharing status updates, workspace signals, or requesting help from any available agent.";
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
    };
    { sdk_name = "masc_heartbeat";
      canonical_operation = "masc_heartbeat";
      description =
        "Send an immediate heartbeat so this agent stays fresh in MASC visibility.";
      input_schema = object_schema [];
      arg_bindings = [ ("agent_name", Agent_name) ];
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
        "masc_status";
        "masc_messages";
        "masc_plan_init";
        "masc_plan_get";
        "masc_plan_update";
        "masc_note_add";
        "masc_deliver";
        "masc_operator_snapshot";
        "masc_operator_digest";
        "masc_operator_action";
        "masc_operator_confirm";
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
      | other ->
          Error
            (Printf.sprintf "%s must be a JSON object (received %s)" label
               (Json_util.kind_name other)))
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
      | other ->
          Error
            (Printf.sprintf "%s must be a JSON array (received %s)" label
               (Json_util.kind_name other)))
  | "string" -> (
      match value with
      | `String _ -> Ok ()
      | other ->
          Error
            (Printf.sprintf "%s must be a string (received %s)" label
               (Json_util.kind_name other)))
  | "integer" -> (
      match value with
      | `Int _ -> Ok ()
      | other ->
          Error
            (Printf.sprintf "%s must be an integer (received %s)" label
               (Json_util.kind_name other)))
  | "number" -> (
      match value with
      | `Int _ | `Float _ -> Ok ()
      | other ->
          Error
            (Printf.sprintf "%s must be a number (received %s)" label
               (Json_util.kind_name other)))
  | "boolean" -> (
      match value with
      | `Bool _ -> Ok ()
      | other ->
          Error
            (Printf.sprintf "%s must be a boolean (received %s)" label
               (Json_util.kind_name other)))
  | _ -> Ok ()

let validate_input_json schema json =
  validate_json_value ~label:"input" schema json

(* Strict classifier: returns [None] for unknown JSON Schema types so
   callers can distinguish "rule fired" from "fall-through default"
   (see #8832). Delegates to the OAS SSOT
   [Agent_sdk.Types.param_type_of_string] ([Error _ -> None]) so a
   param_type added upstream stays in sync without editing this table.
   NB: not [Tool_bridge.param_type_of_string] / [Mcp.json_schema_type_to_param_type],
   whose permissive [_ -> String] default would erase the strict [None]. *)
let param_type_of_schema_opt schema : Agent_sdk.Types.param_type option =
  Agent_sdk.Types.param_type_of_string (schema_type schema) |> Result.to_option

let tool_params_of_input_schema schema =
  let required = required_names schema in
  property_map schema
  |> List.map (fun (name, property_schema) ->
         let description =
           string_member "description" property_schema
           |> Option.value ~default:(Printf.sprintf "%s parameter" name)
         in
         let param : Agent_sdk.Types.tool_param =
           {
             name;
             description;
             param_type =
               (match param_type_of_schema_opt property_schema with
               | Some t -> t
               | None ->
                   Log.Misc.warn
                     "tool_params_of_input_schema: unknown JSON Schema type %S -> String (drift; see #8832)"
                     (schema_type property_schema);
                   Agent_sdk.Types.String);
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
      | other ->
          Error
            (Printf.sprintf "input must be a JSON object (received %s)"
               (Json_util.kind_name other)))

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

let sdk_tool_schemas : Masc_domain.tool_schema list =
  List.map
    (fun (binding : sdk_tool_binding) ->
      {
        Masc_domain.name = binding.sdk_name;
        description = binding.description;
        input_schema = binding.input_schema;
      })
    sdk_bindings
