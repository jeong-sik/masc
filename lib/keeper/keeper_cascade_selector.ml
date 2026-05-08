(** Keeper_cascade_selector -- L1 Proactive Routing (RFC-0041 Phase B3). *)

open Cascade_ref

type selected_target = {
  group : string;
  item : Cascade_ref.cascade_item;
}

let select_item_for_turn
    ~(keeper_name : string)
    ~(cascade_profile : cascade_profile)
    ~(health_cache : Keeper_health_probe.health_status)
    ~(last_used_item : string option)
    : (selected_target, [> `No_available_item ]) result =
  let rec try_group group_name visited =
    if List.mem group_name visited then
      Error `No_available_item
    else
      match find_group cascade_profile group_name with
      | None -> Error `No_available_item
      | Some group ->
          let items = order_items group.strategy group.items in
          let items =
            match group.strategy, last_used_item with
            | RoundRobin, Some last_id ->
                let rec rotate = function
                  | [] -> []
                  | item :: rest ->
                      if String.equal item.id last_id then rest @ [item]
                      else item :: rotate rest
                in
                rotate items
            | _ -> items
          in
          let rec find_healthy = function
            | [] -> None
            | item :: rest ->
                if Keeper_health_probe.is_item_healthy ~keeper_name ~item_id:item.id then
                  Some item
                else
                  find_healthy rest
          in
          match find_healthy items with
          | Some item -> Ok { group = group_name; item }
          | None ->
              (match group.fallback_group with
               | Some next ->
                   try_group next (group_name :: visited)
               | None ->
                   Error `No_available_item)
  in
  let start_group =
    match cascade_profile.groups with
    | first :: _ -> first.name
    | [] -> cascade_profile.name
  in
  try_group start_group []
