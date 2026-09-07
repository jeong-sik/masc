(** Immutable Keeper tool catalog facade.

    Tool families are an organizational detail only.  This module has no
    runtime membership or authorization state. *)

val memory_search_source_enum_strings : string list

val base_tools : Masc_domain.tool_schema list
val all_keeper_tool_schemas : Masc_domain.tool_schema list
(** Every Keeper-handler schema family, de-duplicated by exact internal tool
    name while preserving catalog order. Model visibility is owned solely by
    [Keeper_tool_descriptor.keeper_model_names]. *)
