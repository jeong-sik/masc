(** Exact Keeper tool-schema projection.

    Descriptor declarations decide whether a schema is model-visible. This
    module performs no per-Keeper or per-turn policy filtering. *)

(** Complete descriptor-declared model surface. *)
val keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list

val keeper_model_tool_names : unit -> string list
