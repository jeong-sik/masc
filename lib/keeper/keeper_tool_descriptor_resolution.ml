let descriptor_for_tool_name tool_name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor -> Some descriptor
  | None ->
    (match Keeper_tool_descriptor.descriptors_for_internal stripped with
     | descriptor :: _ -> Some descriptor
     | [] ->
       let internal_name =
         match Keeper_tool_alias.canonical_internal_name tool_name with
         | Some internal_name -> internal_name
         | None -> stripped
       in
       (match Keeper_tool_descriptor.descriptors_for_internal internal_name with
        | descriptor :: _ -> Some descriptor
        | [] -> None))
;;

let canonical_internal_name_for_tool_name tool_name =
  match descriptor_for_tool_name tool_name with
  | Some descriptor -> Some descriptor.Keeper_tool_descriptor.internal_name
  | None -> Keeper_tool_alias.canonical_internal_name tool_name
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

let is_public_mcp_surface_name tool_name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match descriptor_for_tool_name stripped with
  | Some descriptor ->
    String.equal descriptor.Keeper_tool_descriptor.public_name stripped
    && Tool_catalog.is_public_mcp stripped
  | None -> false
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
  | Tool_capability.Idempotent, Some true -> true
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
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor -> Some (descriptor, descriptor.Keeper_tool_descriptor.translate input)
  | None ->
    (match Keeper_tool_descriptor.descriptors_for_internal stripped with
     | descriptor :: _ -> Some (descriptor, input)
     | [] ->
       let internal_name =
         match Keeper_tool_alias.canonical_internal_name tool_name with
         | Some internal_name -> internal_name
         | None -> stripped
       in
       (match Keeper_tool_descriptor.descriptors_for_internal internal_name with
        | descriptor :: _ -> Some (descriptor, input)
        | [] -> None))
;;

let public_descriptor_and_name_for_tool_call tool_name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some descriptor -> Some (stripped, descriptor)
  | None -> None
;;

let validate_public_input_for_tool_call ~tool_name ~input =
  match public_descriptor_and_name_for_tool_call tool_name with
  | Some (public_name, descriptor) ->
    Some
      (Tool_input_validation.validate_args
         ~schema:descriptor.Keeper_tool_descriptor.input_schema
         ~name:public_name
         ~args:input
         ())
  | None -> None
;;

let validated_descriptor_and_input_for_tool_call ~tool_name ~input =
  match public_descriptor_and_name_for_tool_call tool_name with
  | Some (public_name, descriptor) ->
    (match
       Tool_input_validation.validate_args
         ~schema:descriptor.Keeper_tool_descriptor.input_schema
         ~name:public_name
         ~args:input
         ()
     with
     | Ok validated_input ->
       Some
         (Ok
            ( descriptor
            , descriptor.Keeper_tool_descriptor.translate validated_input ))
     | Error validation_result -> Some (Error validation_result))
  | None ->
    Option.map
      (fun descriptor_and_input -> Ok descriptor_and_input)
      (descriptor_and_input_for_tool_call ~tool_name ~input)
;;

let readonly_for_tool_name tool_name =
  match descriptor_for_tool_name tool_name with
  | Some descriptor -> Keeper_tool_descriptor.readonly_static_hint descriptor
  | None -> None
;;

let readonly_for_tool_call ~tool_name ~input =
  match descriptor_and_input_for_tool_call ~tool_name ~input with
  | Some (descriptor, input) ->
    (match Keeper_tool_descriptor.readonly_for_input descriptor ~input with
     | Some _ as decision -> decision
     | None -> Keeper_tool_descriptor.readonly_static_hint descriptor)
  | None -> None
;;

let descriptors_for_tool_names tool_names =
  let add_descriptor (seen, acc) descriptor =
    if List.mem descriptor.Keeper_tool_descriptor.id seen
    then seen, acc
    else descriptor.id :: seen, descriptor :: acc
  in
  tool_names
  |> List.filter_map descriptor_for_tool_name
  |> List.fold_left add_descriptor ([], [])
  |> snd
  |> List.rev
;;
