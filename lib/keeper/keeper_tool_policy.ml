(** Exact Keeper tool-schema projection.

    This module validates the descriptor/registry join and exposes the complete
    descriptor-declared model surface. It does not classify tool meaning,
    select a subset for a turn, or authorize execution. *)

let all_keeper_model_tool_schemas () =
  Keeper_tool_descriptor.model_visible_schemas ~surface:All
;;

let keeper_model_tool_schemas = all_keeper_model_tool_schemas

(** Resolve tool_groups from a keeper's meta into the narrowed surface.
    [None] or empty preserves the current [All] behaviour. *)
let keeper_model_tool_schemas_for (tool_groups : string list option) () =
  let surface = Keeper_tool_descriptor.tool_groups_to_surface tool_groups in
  Keeper_tool_descriptor.model_visible_schemas ~surface
;;

let keeper_model_tool_names () =
  keeper_model_tool_schemas ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;
