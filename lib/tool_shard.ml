(** Keeper handler schema catalog.

    Schema families remain split by domain for maintainability. This catalog
    describes handler inputs; model exposure is owned exclusively by
    [Keeper_tool_descriptor]. *)

include Tool_shard_types

let dedupe_schemas (schemas : Masc_domain.tool_schema list) =
  let _, schemas_rev =
    List.fold_left
      (fun (seen, schemas_rev) (schema : Masc_domain.tool_schema) ->
         if Set_util.StringSet.mem schema.name seen
         then seen, schemas_rev
         else Set_util.StringSet.add schema.name seen, schema :: schemas_rev)
      (Set_util.StringSet.empty, [])
      schemas
  in
  List.rev schemas_rev
;;

let all_keeper_tool_schemas : Masc_domain.tool_schema list =
  [ base_tools
  ; board_tools
  ; filesystem_tools
  ; search_files_tools
  ; typed_execute_tools
  ; voice_tools
  ; library_tools
  ; surface_tools
  ; taskboard_tools
  ]
  |> List.concat
  |> dedupe_schemas
;;
