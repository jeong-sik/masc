type arg_source =
  | Input_field of string
  | Static of Yojson.Safe.t
  | Agent_name

type agent_core_tool_binding = {
  name : string;
  canonical_operation : string;
  description : string;
  input_schema : Yojson.Safe.t;
  arg_bindings : (string * arg_source) list;
}

let identity_arg_bindings = function
  | `Assoc schema_fields ->
    (match List.assoc_opt "properties" schema_fields with
     | Some (`Assoc properties) ->
       List.map (fun (name, _schema) -> name, Input_field name) properties
     | Some _ | None -> [])
  | _ -> []

let canonical_add_task =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) ->
         String.equal schema.name "masc_add_task")
      Task.Schemas.schemas
  with
  | Some schema -> schema
  | None -> invalid_arg "canonical masc_add_task schema is not registered"

(* The deliberately narrower agent-core wording and input shape live in the
   [agent_core_projection] table of the tool's own config/tools/<name>.toml
   declaration (RFC prompts-and-tool-definitions-outside-ocaml §2.2), decoded
   once here at module initialization. A missing file, a missing table, or a
   declaration that does not decode refuses the boot — the same posture as
   [canonical_add_task] above. *)
let projection_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> invalid_arg (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.agent_core_projection = Some schema; _ } -> schema
     | Ok { Tool_definition_toml.agent_core_projection = None; _ } ->
       invalid_arg (Printf.sprintf "%s declares no agent_core_projection table" rel)
     | Error message -> invalid_arg message)
;;

let batch_add_tasks_projection = projection_of_name "masc_batch_add_tasks"
let broadcast_projection = projection_of_name "masc_broadcast"
let heartbeat_projection = projection_of_name "masc_heartbeat"

let agent_core_bindings : agent_core_tool_binding list =
  [ { name = "masc_add_task"
    ; canonical_operation = "masc_add_task"
    ; description = canonical_add_task.description
    ; input_schema = canonical_add_task.input_schema
    ; arg_bindings = identity_arg_bindings canonical_add_task.input_schema
    }
  ; { name = "masc_batch_add_tasks"
    ; canonical_operation = "masc_batch_add_tasks"
    ; description = batch_add_tasks_projection.description
    ; input_schema = batch_add_tasks_projection.input_schema
    ; arg_bindings = identity_arg_bindings batch_add_tasks_projection.input_schema
    }
  ; { name = "masc_broadcast"
    ; canonical_operation = "masc_broadcast"
    ; description = broadcast_projection.description
    ; input_schema = broadcast_projection.input_schema
    ; (* [agent_name] is injected from the caller identity, so the projection
         deliberately omits it from the model-facing schema. *)
      arg_bindings =
        ("agent_name", Agent_name)
        :: identity_arg_bindings broadcast_projection.input_schema
    }
  ; { name = "masc_heartbeat"
    ; canonical_operation = "masc_heartbeat"
    ; description = heartbeat_projection.description
    ; input_schema = heartbeat_projection.input_schema
    ; arg_bindings = [ "agent_name", Agent_name ]
    }
  ]
;;

let agent_core_binding_by_name name =
  List.find_opt (fun binding -> String.equal binding.name name) agent_core_bindings

let agent_core_aliases_for_operation operation_id =
  List.filter
    (fun binding -> String.equal binding.canonical_operation operation_id)
    agent_core_bindings

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
    (List.map (fun binding -> binding.canonical_operation) agent_core_bindings
    @ [
        "masc_status";
        "masc_messages";
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
  match agent_core_binding_by_name requested_name with
  | None -> Ok (requested_name, arguments)
  | Some binding ->
      build_operation_arguments ~agent_name binding arguments
      |> Result.map (fun translated_arguments ->
             (binding.canonical_operation, translated_arguments))

let agent_core_alias_json binding =
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
      ("name", `String binding.name);
      ("description", `String binding.description);
      ("canonicalOperationId", `String binding.canonical_operation);
      ("inputSchema", binding.input_schema);
      ("argumentMapping", `Assoc argument_mapping);
      ("staticArguments", `Assoc static_arguments);
      ("injectAgentName", `Bool inject_agent_name);
    ]

let agent_core_tool_schemas : Masc_domain.tool_schema list =
  List.map
    (fun (binding : agent_core_tool_binding) ->
      {
        Masc_domain.name = binding.name;
        description = binding.description;
        input_schema = binding.input_schema;
      })
    agent_core_bindings
