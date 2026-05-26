let descriptor_for_tool_name tool_name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Agent_tool_descriptor.find_public stripped with
  | Some descriptor -> Some descriptor
  | None ->
    (match Agent_tool_descriptor.descriptors_for_internal stripped with
     | descriptor :: _ -> Some descriptor
     | [] ->
       let internal_name =
         match Keeper_tool_alias.canonical_internal_name tool_name with
         | Some internal_name -> internal_name
         | None -> stripped
       in
       (match Agent_tool_descriptor.descriptors_for_internal internal_name with
        | descriptor :: _ -> Some descriptor
        | [] -> None))
;;

let descriptor_and_input_for_tool_call ~tool_name ~input =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Agent_tool_descriptor.find_public stripped with
  | Some descriptor -> Some (descriptor, descriptor.Agent_tool_descriptor.translate input)
  | None ->
    (match Agent_tool_descriptor.descriptors_for_internal stripped with
     | descriptor :: _ -> Some (descriptor, input)
     | [] ->
       let internal_name =
         match Keeper_tool_alias.canonical_internal_name tool_name with
         | Some internal_name -> internal_name
         | None -> stripped
       in
       (match Agent_tool_descriptor.descriptors_for_internal internal_name with
        | descriptor :: _ -> Some (descriptor, input)
        | [] -> None))
;;

let readonly_for_tool_name tool_name =
  match descriptor_for_tool_name tool_name with
  | Some descriptor -> Agent_tool_descriptor.readonly_static_hint descriptor
  | None -> None
;;

let readonly_for_tool_call ~tool_name ~input =
  match descriptor_and_input_for_tool_call ~tool_name ~input with
  | Some (descriptor, input) ->
    (match Agent_tool_descriptor.readonly_for_input descriptor ~input with
     | Some _ as decision -> decision
     | None -> Agent_tool_descriptor.readonly_static_hint descriptor)
  | None -> None
;;

let descriptors_for_tool_names tool_names =
  let add_descriptor (seen, acc) descriptor =
    if List.mem descriptor.Agent_tool_descriptor.id seen
    then seen, acc
    else descriptor.id :: seen, descriptor :: acc
  in
  tool_names
  |> List.filter_map descriptor_for_tool_name
  |> List.fold_left add_descriptor ([], [])
  |> snd
  |> List.rev
;;
