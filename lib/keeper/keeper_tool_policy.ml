(** Exact Keeper tool-schema projection.

    This module validates the descriptor/registry join and exposes the complete
    descriptor-declared model surface. It does not classify tool meaning,
    select a subset for a turn, or authorize execution. *)

let all_keeper_model_tool_schemas () =
  Keeper_tool_descriptor.model_visible_schemas ()
;;

let keeper_model_tool_schemas = all_keeper_model_tool_schemas

let keeper_model_tool_names () =
  keeper_model_tool_schemas ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;
