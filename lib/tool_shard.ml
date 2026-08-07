(** Keeper handler schema catalog.

    Schema families remain split by domain for maintainability. This catalog
    describes handler inputs; model exposure is owned exclusively by
    [Keeper_tool_descriptor]. *)

include Tool_shard_types

let all_keeper_tool_schemas : Masc_domain.tool_schema list =
  [ base_tools
  ; filesystem_tools
  ; search_files_tools
  ; typed_execute_tools
  ; voice_tools
  ; library_tools
  ; surface_tools
  ; taskboard_tools
  ]
  |> List.concat
;;
