(** Read-only lookups over Keeper_registry.

    Extracted from keeper_registry.ml (1490-1546) as part of the
    godfile decomp campaign. These are O(n) scans across all
    registered keepers; they do not need access to the internal
    Atomic state primitive and instead consume [Keeper_registry.all]
    snapshots. Moving them out of the registry's mutator-rich core
    isolates the read API from the CAS retry loops. *)

open Keeper_registry_types

let find_by_name name =
  Keeper_registry.all ()
  |> List.find_opt (fun (v : registry_entry) -> String.equal v.name name)
;;

let find_by_agent_name agent_name =
  Keeper_registry.all ()
  |> List.find_opt (fun (v : registry_entry) ->
       String.equal v.meta.Keeper_types.agent_name agent_name)
;;

let find_by_id (uid : Keeper_id.Uid.t) =
  Keeper_registry.all ()
  |> List.find_opt (fun (v : registry_entry) ->
       match v.meta.Keeper_types.keeper_id with
       | Some id -> Keeper_id.Uid.equal id uid
       | None -> false)
;;

let tool_usage_of_by_name name =
  match find_by_name name with
  | None -> []
  | Some entry ->
    StringMap.fold (fun n e acc -> (n, e) :: acc) entry.tool_usage []
    |> List.sort (fun (_, (a : Keeper_types.tool_call_entry))
                      (_, (b : Keeper_types.tool_call_entry)) ->
         Int.compare b.count a.count)
;;

let resolve_config (config : Coord_utils_backend_setup.config) keeper_name
  : Coord_utils_backend_setup.config
  =
  if keeper_name = ""
  then config
  else
    (* Keeper config resolution is scoped to the caller's current base_path.
       Do not retarget requests across other base_path registries. *)
    match Keeper_registry.get ~base_path:config.base_path keeper_name with
    | Some _ | None -> config
;;
