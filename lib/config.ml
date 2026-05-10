(** Tool schema registry and visibility helpers. *)

module StringSet = Set.Make (String)

let dedupe_schemas (schemas : Masc_domain.tool_schema list) =
  let unique, _ =
    List.fold_left
      (fun (acc, seen) (schema : Masc_domain.tool_schema) ->
        if StringSet.mem schema.name seen then (acc, seen)
        else (schema :: acc, StringSet.add schema.name seen))
      ([], StringSet.empty)
      schemas
  in
  List.rev unique

let retired_front_door_schema_names =
  [
  ]

let filter_retired_front_door_schemas (schemas : Masc_domain.tool_schema list) =
  List.filter
    (fun (schema : Masc_domain.tool_schema) ->
      not (List.mem schema.name retired_front_door_schema_names))
    schemas

let raw_all_tool_schemas : Masc_domain.tool_schema list =
  filter_retired_front_door_schemas
    (dedupe_schemas
       (Tools.raw_schemas
       @ Tool_schemas_control.schemas
       @ Tool_schemas_misc.schemas
       @ Tool_board.tools
       @ Keeper_types.schemas
       @ Tool_local_runtime.schemas
       @ Tool_autoresearch.schemas
       @ Tool_agent_timeline.schemas
       @ Tool_shard.schemas
       (* #9912 / #10101: every keeper-facing shard tool must reach the
          authoritative registry consumed by
          [Tool_help_registry.find_entry], or keepers that request
          help on the tool receive "unknown tool" despite the
          dispatcher handling it correctly.  #9912 plugged only
          [Tool_shard.base_tools] (5 always-present tools); #10101
          observed 11 other shard categories still missing
          (keeper_task_claim, keeper_fs_edit, keeper_board_*, ...).
          [Tool_shard.all_keeper_tool_schemas] is the SSOT that
          pulls from [all_shards] plus the non-shard
          [keeper_preflight_tools] / [keeper_pr_review_tools]
          lists, so future shard categories flow through without
          another patch-local fix. *)
       @ Tool_shard.all_keeper_tool_schemas))

(** Validate tool schemas at module initialization time.
    Logs warnings for: duplicate names, empty names/descriptions,
    input_schema.type not "object". Does not block startup. *)
let validate_schemas (schemas : Masc_domain.tool_schema list) =
  let errors, _ =
    List.fold_left
      (fun (errors, seen) (schema : Masc_domain.tool_schema) ->
        let errors =
          if StringSet.mem schema.name seen then
            Printf.sprintf "Duplicate tool name: %s" schema.name :: errors
          else errors
        in
        let seen = StringSet.add schema.name seen in
        let errors =
          if schema.name = "" then "Empty tool name found" :: errors
          else errors
        in
        let errors =
          if schema.description = "" then
            Printf.sprintf "Empty description for tool: %s" schema.name
            :: errors
          else errors
        in
        let errors =
          match Yojson.Safe.Util.member "type" schema.input_schema with
          | `String "object" -> errors
          | _ ->
              Printf.sprintf "Tool %s: input_schema.type is not 'object'"
                schema.name
              :: errors
        in
        (errors, seen))
      ([], StringSet.empty)
      schemas
  in
  match errors with
  | [] -> ()
  | errs -> List.iter (fun e -> Log.Config.warn "%s" e) errs

let all_tool_schemas : Masc_domain.tool_schema list =
  let schemas =
    Capability_registry.public_tool_schemas_from raw_all_tool_schemas
  in
  validate_schemas schemas;
  schemas

let all_tool_names () : string list =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) all_tool_schemas

let is_tool_visible tool_name =
  Tool_catalog.is_visible tool_name

let visible_tool_schemas ?(include_hidden = false) ?(include_deprecated = false) () :
    Masc_domain.tool_schema list =
  Capability_registry.visible_public_tool_schemas_from ~include_hidden
    ~include_deprecated raw_all_tool_schemas
