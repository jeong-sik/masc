(** Exact Keeper tool-schema projection.

    This module validates the descriptor/registry join and exposes the complete
    descriptor-declared model surface. It does not classify tool meaning,
    select a subset for a turn, or authorize execution. *)

module StringSet = Set_util.StringSet

let dedupe_tool_schemas (schemas : Masc_domain.tool_schema list) =
  let _, schemas_rev =
    List.fold_left
      (fun (seen, schemas_rev) (schema : Masc_domain.tool_schema) ->
         if StringSet.mem schema.name seen
         then seen, schemas_rev
         else StringSet.add schema.name seen, schema :: schemas_rev)
      (StringSet.empty, [])
      schemas
  in
  List.rev schemas_rev
;;

let all_keeper_model_tool_schemas () =
  Keeper_tool_descriptor.model_visible_descriptors ()
  |> List.concat_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    Keeper_tool_descriptor.keeper_model_names descriptor
    |> List.map (fun name ->
      { Masc_domain.name
      ; description = descriptor.description
      ; input_schema = descriptor.input_schema
      }))
  |> dedupe_tool_schemas
;;

let keeper_model_tool_schemas = all_keeper_model_tool_schemas

let keeper_model_tool_names () =
  keeper_model_tool_schemas ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;
