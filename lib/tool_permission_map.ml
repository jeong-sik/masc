(** Tool_permission_map — Shared tool→permission resolution. *)

open Types

let declared_permission_for_tool tool_name =
  (Tool_catalog.metadata tool_name).required_permission

let legacy_permission_entries : (string * permission) list =
  [
    ("masc_done", CanCompleteTask);
    ("masc_release", CanCompleteTask);
  ]

let legacy_permission_for_tool tool_name =
  List.assoc_opt tool_name legacy_permission_entries

let known_tool_names =
  let metadata_tools =
    Tool_catalog.all_surfaces
    |> List.concat_map Tool_catalog.tools_for_surface
  in
  let explicit_tools = List.map fst Tool_catalog.explicit_metadata in
  let known = metadata_tools @ explicit_tools @ List.map fst legacy_permission_entries in
  List.sort_uniq String.compare known

let permission_for_tool tool_name =
  match declared_permission_for_tool tool_name with
  | Some _ as permission -> permission
  | None -> legacy_permission_for_tool tool_name
