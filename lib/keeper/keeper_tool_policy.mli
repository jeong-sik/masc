(** Exact Keeper tool-schema projection.

    Descriptor declarations decide whether a schema is model-visible. This
    module performs no per-Keeper or per-turn policy filtering. *)

module StringSet : Set.S with type elt = string

val tool_name_set : string list -> StringSet.t

val dedupe_tool_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list

val missing_canonical_schema_names :
  Keeper_tool_descriptor.t list -> string list

(** Exact join of registered schemas whose internal handler has a descriptor.
    No prefix, module-tag, product, or operation-name classification is used. *)
val registered_handler_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list

val registered_handler_schema_names : unit -> string list

(** Validate and install the exact registered-schema/descriptor join. *)
val inject_masc_schemas : Masc_domain.tool_schema list -> unit

(** Complete descriptor-declared model surface. *)
val all_keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list
val keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list
val keeper_model_tool_names : unit -> string list
