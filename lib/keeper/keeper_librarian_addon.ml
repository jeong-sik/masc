type operation = Admission | Durable
let all = [Admission; Durable]
let package_id = "keeper-librarian"
let tool = function Admission -> "admit_memory" | Durable -> "derive_memory"
let output = function Admission -> "admission" | Durable -> "durable"
let reserved () =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas
  @ (Keeper_tool_descriptor.all_descriptors () |> List.concat_map Keeper_tool_descriptor.registered_names)
  |> List.sort_uniq String.compare

type unavailable =
  | Unattached
  | Unready of Lane_addon_unready.t * Lane_addon_unready.t list
  | Export_conflict of Lane_addon_tool_export.conflict
  | Wrong_package of { actual : string }
  | Manual_installation

let unavailable_to_string = function
  | Unattached -> "Keeper Librarian Add-on is not attached"
  | Unready (first, rest) ->
    String.concat "; " (List.map Lane_addon_unready.message (first :: rest))
  | Export_conflict conflict -> Lane_addon_tool_export.conflict_to_string conflict
  | Wrong_package {actual} ->
    Printf.sprintf "Keeper Librarian requires package %s; the export belongs to %s" package_id actual
  | Manual_installation -> "Keeper Librarian requires a declared installation with exact-output routes"

let select operation (snapshot : Lane_addon_runtime.tool_execution_snapshot) =
  let name = tool operation in
  match List.find_opt (fun (conflict : Lane_addon_tool_export.conflict) ->
    String.equal conflict.name name) snapshot.conflicts with
  | Some conflict -> Error (Export_conflict conflict)
  | None ->
    match List.find_opt (fun (entry : Lane_addon_runtime.tool_execution) ->
      String.equal entry.export.tool.name name) snapshot.serving with
    | Some entry when not (String.equal entry.package_id package_id) ->
      Error (Wrong_package {actual=entry.package_id})
    | Some {installation_id=None;_} -> Error Manual_installation
    | Some entry -> Ok entry
    | None ->
      match Lane_addon_unready.declaring ~name snapshot.unready with
      | [] -> Error Unattached
      | first :: rest -> Error (Unready (first,rest))

let resolve ~config ~reserved operation =
  Lane_addon_runtime.tool_execution_snapshot ~config ~reserved
    ~access:Lane_addon_sources.Operator_configuration
  |> select operation
  |> Result.map (fun (entry : Lane_addon_runtime.tool_execution) -> entry.export)
