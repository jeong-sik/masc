module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_permission_map — Shared tool→permission resolution. *)

let declared_permission_for_tool tool_name =
  match Tool_catalog.registered_metadata tool_name with
  | Some meta -> meta.required_permission
  | None -> None
;;

let known_tool_names =
  (* Union of every curated tool-name list (replaces the deleted
     [all_surfaces |> concat_map tools_for_surface]) plus explicit metadata
     names.  Name set matches the pre-refactor base: the 5 actor lists plus
     [system_internal_hidden] (the former System_internal surface, included in
     [all_surfaces] at base).  List.sort_uniq dedupes. *)
  let metadata_tools =
    Tool_catalog_surfaces.public_mcp_surface_tools
    @ Tool_catalog_surfaces.spawned_agent_surface_tools
    @ Tool_catalog_surfaces.local_worker_surface_tools
    @ Tool_catalog_surfaces.session_min_surface_tools
    @ Tool_catalog_surfaces.admin_surface_tools
    @ Tool_catalog_surfaces.system_internal_hidden
  in
  let explicit_tools = List.map fst Tool_catalog.explicit_metadata in
  let known = metadata_tools @ explicit_tools in
  List.sort_uniq String.compare known
;;

let permission_for_tool tool_name = declared_permission_for_tool tool_name
