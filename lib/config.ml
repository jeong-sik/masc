(** Tool schema registry and visibility helpers. *)

module StringSet = Set.Make (String)

let dedupe_schemas (schemas : Types.tool_schema list) =
  let seen = ref StringSet.empty in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if StringSet.mem schema.name !seen then
        false
      else (
        seen := StringSet.add schema.name !seen;
        true))
    schemas

let retired_front_door_schema_names =
  [
    "masc_collaboration_graph";
  ]

let filter_retired_front_door_schemas (schemas : Types.tool_schema list) =
  List.filter
    (fun (schema : Types.tool_schema) ->
      not (List.mem schema.name retired_front_door_schema_names))
    schemas

let raw_all_tool_schemas : Types.tool_schema list =
  filter_retired_front_door_schemas
    (dedupe_schemas
       (Tools.raw_schemas
       @ Tool_schemas_control.schemas
       @ Tool_schemas_a2a.schemas
       @ Tool_schemas_misc.schemas
       @ Tool_board.tools
       @ Tool_keeper.schemas
       @ Tool_local_runtime.schemas
       @ Tool_autoresearch.schemas
       @ Tool_compact.schemas
       @ Tool_repair_loop.schemas
       @ Tool_agent_timeline.schemas
       @ Tool_shard.schemas))

(** Validate tool schemas at module initialization time.
    Logs warnings for: duplicate names, empty names/descriptions,
    input_schema.type not "object". Does not block startup. *)
let validate_schemas (schemas : Types.tool_schema list) =
  let errors = ref [] in
  let seen = ref StringSet.empty in
  List.iter
    (fun (schema : Types.tool_schema) ->
      if StringSet.mem schema.name !seen then
        errors :=
          Printf.sprintf "Duplicate tool name: %s" schema.name :: !errors
      else seen := StringSet.add schema.name !seen;
      if schema.name = "" then
        errors := "Empty tool name found" :: !errors;
      if schema.description = "" then
        errors :=
          Printf.sprintf "Empty description for tool: %s" schema.name
          :: !errors;
      match Yojson.Safe.Util.member "type" schema.input_schema with
      | `String "object" -> ()
      | _ ->
          errors :=
            Printf.sprintf "Tool %s: input_schema.type is not 'object'"
              schema.name
            :: !errors)
    schemas;
  match !errors with
  | [] -> ()
  | errs ->
      List.iter (fun e -> Log.Config.warn "%s" e) errs

let all_tool_schemas : Types.tool_schema list =
  let schemas =
    Capability_registry.public_tool_schemas_from raw_all_tool_schemas
  in
  validate_schemas schemas;
  schemas

let all_tool_names () : string list =
  List.map (fun (s : Types.tool_schema) -> s.name) all_tool_schemas

let is_tool_visible tool_name =
  Tool_catalog.is_visible tool_name

let visible_tool_schemas ?(include_hidden = false) ?(include_deprecated = false) () :
    Types.tool_schema list =
  Capability_registry.visible_public_tool_schemas_from ~include_hidden
    ~include_deprecated raw_all_tool_schemas
