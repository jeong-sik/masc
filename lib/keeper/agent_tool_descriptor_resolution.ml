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
