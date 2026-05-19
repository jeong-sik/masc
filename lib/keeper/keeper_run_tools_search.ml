type tool_search_hit_partition =
  { visible_core_hits : (string * float) list
  ; discoverable_hits : (string * float) list
  ; filtered_by_policy : int
  }

let partition_tool_search_hits ~core ~core_always ~allowed ~retrieved ~max_results =
  (* PR #14574 review #1/#7: only expose a public alias (e.g. "Bash") when
     its routed internal handler (e.g. [keeper_bash]) is actually in the
     incoming [allowed] set for this preset. Adding all [public_names ()]
     unconditionally let [keeper_tool_search] return aliases even when
     their backing tool was not permitted for the turn, which would invite
     the model to attempt unregistered tool calls. *)
  let allowed_internal_set =
    let tbl = Hashtbl.create (List.length allowed) in
    List.iter (fun n -> Hashtbl.replace tbl n ()) allowed;
    tbl
  in
  let aliases_with_allowed_route =
    Keeper_tool_alias.public_names ()
    |> List.filter (fun pub ->
      match Keeper_tool_alias.route pub with
      | Some r -> Hashtbl.mem allowed_internal_set r.internal_name
      | None -> false)
  in
  let allowed = allowed @ aliases_with_allowed_route in
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

let truncate_tool_surface_names ~max_tools ~essential_names all_allowed =
  if List.length all_allowed <= max_tools
  then all_allowed
  else (
    let essential_names = Keeper_types.dedupe_keep_order essential_names in
    let essential =
      all_allowed
      |> List.filter (fun name -> List.mem name essential_names)
      |> Keeper_types.dedupe_keep_order
    in
    let non_essential =
      List.filter (fun name -> not (List.mem name essential_names)) all_allowed
    in
    let budget = max 0 (max_tools - List.length essential) in
    essential
    @ (non_essential
       |> List.filteri (fun i _ -> i < budget)
       |> Keeper_types.dedupe_keep_order))
;;
