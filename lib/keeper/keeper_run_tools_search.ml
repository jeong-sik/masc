type tool_search_hit_partition =
  { visible_core_hits : (string * float) list
  ; discoverable_hits : (string * float) list
  ; filtered_by_policy : int
  }

let partition_tool_search_hits ~core ~core_always ~allowed ~retrieved ~max_results =
  (* Only expose a descriptor's model projection (e.g. "Execute") when
     its routed internal handler is actually in the
     incoming active surface. Adding compatibility aliases
     unconditionally let [keeper_tool_search] return names even when
     their backing tool was not permitted for the turn, which would invite
     the model to attempt unregistered tool calls. *)
  let projected_names_with_allowed_route =
    Keeper_tool_descriptor.public_descriptors
    |> List.filter (fun (descriptor : Keeper_tool_descriptor.t) ->
      List.mem descriptor.internal_name allowed)
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
  in
  let allowed = allowed @ projected_names_with_allowed_route in
  let allowed_set =
    let tbl = Hashtbl.create (List.length allowed) in
    List.iter (fun n -> Hashtbl.replace tbl n ()) allowed;
    List.iter (fun n -> Hashtbl.replace tbl n ()) core_always;
    tbl
  in
  let allowed_retrieved =
    retrieved |> List.filter (fun (name, _) -> Hashtbl.mem allowed_set name)
  in
  let is_core name = List.mem name core || List.mem name core_always in
  let visible_core_hits =
    allowed_retrieved |> List.filter (fun (name, _) -> is_core name)
  in
  let discoverable_hits =
    allowed_retrieved
    |> List.filter (fun (name, _) -> not (is_core name))
    |> List.filteri (fun i _ -> i < max_results)
  in
  { visible_core_hits
  ; discoverable_hits
  ; filtered_by_policy = List.length retrieved - List.length allowed_retrieved
  }
;;
