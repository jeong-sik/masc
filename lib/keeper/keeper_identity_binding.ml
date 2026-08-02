(** Authoritative Keeper identity bindings.

    This module deliberately does not parse an agent name or derive a Keeper
    name from spelling. It joins the live registry and persisted metadata on
    their typed [agent_name] field and preserves ambiguity as data. *)

type resolution =
  | Not_found
  | Unique of string
  | Ambiguous of string list
  | Lookup_failed of string

let resolve ~config ~agent_name =
  let registered_keeper_names =
    Keeper_registry_lookup.find_all_by_agent_name_in_base_path
      ~base_path:config.Workspace.base_path
      agent_name
    |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
    |> List.sort_uniq String.compare
  in
  match registered_keeper_names with
  | _ :: _ :: _ -> Ambiguous registered_keeper_names
  | [ keeper_name ] -> Unique keeper_name
  | [] ->
    (match
       Keeper_meta_store.persisted_keeper_name_for_agent_name config ~agent_name
     with
     | Ok None -> Not_found
     | Ok (Some keeper_name) -> Unique keeper_name
     | Error detail -> Lookup_failed detail)
