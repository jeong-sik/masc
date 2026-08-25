let descriptor_for_tool_name tool_name =
  let stripped = Tool_transport_prefix.strip tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor -> Some descriptor
  | None ->
    (match Keeper_tool_descriptor.descriptors_for_internal stripped with
     | descriptor :: _ -> Some descriptor
     | [] -> None)
;;

let canonical_internal_name_for_tool_name tool_name =
  match descriptor_for_tool_name tool_name with
  | Some descriptor -> Some descriptor.Keeper_tool_descriptor.internal_name
  | None ->
    let stripped = Tool_transport_prefix.strip tool_name in
    Option.map
      Tool_schemas_misc.mcp_runtime_tool_name
      (Tool_schemas_misc.mcp_runtime_operation_of_tool_name stripped)
;;

let public_names_for_internal internal_name =
  Keeper_tool_descriptor.public_descriptors_for_internal internal_name
  |> List.concat_map Keeper_tool_descriptor.public_names_of_descriptor
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
;;

let public_name_for_internal internal_name =
  match public_names_for_internal internal_name with
  | first :: _ -> Some first
  | [] -> None
;;

let public_names_for_allowed_internal_names internal_names =
  let allowed = Hashtbl.create (List.length internal_names) in
  List.iter (fun internal_name -> Hashtbl.replace allowed internal_name ()) internal_names;
  Keeper_tool_descriptor.public_descriptors
  |> List.filter (fun (descriptor : Keeper_tool_descriptor.t) ->
    Hashtbl.mem allowed descriptor.internal_name)
  |> List.concat_map Keeper_tool_descriptor.public_names_of_descriptor
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
;;

let capability_has kind tool_name =
  let descriptor = descriptor_for_tool_name tool_name in
  let descriptor_readonly_hint =
    match descriptor with
    | Some descriptor -> Keeper_tool_descriptor.readonly_static_hint descriptor
    | None -> None
  in
  match kind, descriptor_readonly_hint with
  | Tool_capability.Read_only, Some readonly -> readonly
  | _ ->
    Tool_capability.has kind tool_name
    ||
    match descriptor with
    | Some descriptor -> Tool_capability.has kind descriptor.internal_name
    | None ->
      (match canonical_internal_name_for_tool_name tool_name with
       | Some internal_name when not (String.equal internal_name tool_name) ->
         Tool_capability.has kind internal_name
       | _ -> false)
;;

let descriptor_and_input_for_tool_call ~tool_name ~input =
  let stripped = Tool_transport_prefix.strip tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor ->
    Some
      ( descriptor
      , Keeper_tool_descriptor.translate_input_for_descriptor descriptor input )
  | None ->
    (match Keeper_tool_descriptor.descriptors_for_internal stripped with
     | descriptor :: _ -> Some (descriptor, input)
     | [] -> None)
;;

let public_descriptor_and_name_for_tool_call tool_name =
  let stripped = Tool_transport_prefix.strip tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor -> Some (stripped, descriptor)
  | None -> None
;;

let validate_descriptor_input ~tool_name
      (descriptor : Keeper_tool_descriptor.t) input
  =
  Tool_input_validation.validate_args
    ~schema:descriptor.input_schema
    ~name:tool_name
    ~args:input
    ()
;;

let prepare_model_input_for_descriptor ~tool_name
      (descriptor : Keeper_tool_descriptor.t) ~input
  =
  let validate = validate_descriptor_input ~tool_name descriptor in
  let translate =
    Keeper_tool_descriptor.translate_input_for_descriptor descriptor
  in
  match descriptor.input_translation with
  | Keeper_tool_descriptor.Identity
      Keeper_tool_descriptor.Validate_once_before_translation ->
    validate input
  | Keeper_tool_descriptor.Identity
      Keeper_tool_descriptor.Validate_once_after_translation ->
    validate (translate input)
  | Keeper_tool_descriptor.Shape_changing
      { validation =
          Keeper_tool_descriptor.Validate_before_and_after_translation
      ; _
      } ->
    Result.bind (validate input) (fun validated_input ->
      validate (translate validated_input))
  | Keeper_tool_descriptor.Shape_changing
      { validation =
          Keeper_tool_descriptor.Validate_before_then_runtime_handler
      ; _
      } ->
    Result.map translate (validate input)
;;

let validated_descriptor_and_input_for_tool_call ~tool_name ~input =
  match public_descriptor_and_name_for_tool_call tool_name with
  | Some (public_name, descriptor) ->
    Some
      (Result.map
         (fun prepared_input -> descriptor, prepared_input)
         (prepare_model_input_for_descriptor
            ~tool_name:public_name
            descriptor
            ~input))
  | None ->
    Option.map
      (fun descriptor_and_input -> Ok descriptor_and_input)
      (descriptor_and_input_for_tool_call ~tool_name ~input)
;;

let readonly_for_tool_call ~tool_name ~input =
  match descriptor_and_input_for_tool_call ~tool_name ~input with
  | Some (descriptor, input) ->
    (match Keeper_tool_descriptor.readonly_for_input descriptor ~input with
     | Some _ as decision -> decision
     | None -> Keeper_tool_descriptor.readonly_static_hint descriptor)
  | None -> None
;;

type runtime_decision_outcome =
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

let runtime_decision name =
  let stripped = Tool_transport_prefix.strip name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor -> Route_hit { internal = descriptor.internal_name }
  | None ->
    (match descriptor_for_tool_name stripped with
     | Some descriptor ->
       Already_internal { canonical = descriptor.internal_name }
     | None ->
       (match
          Tool_schemas_misc.mcp_runtime_operation_of_tool_name stripped
        with
        | Some operation ->
          Already_internal
            { canonical = Tool_schemas_misc.mcp_runtime_tool_name operation }
        | None -> Miss))
;;

let canonical_tool_name name =
  match runtime_decision name with
  | Route_hit { internal } -> internal
  | Already_internal { canonical } -> canonical
  | Miss -> name
;;

