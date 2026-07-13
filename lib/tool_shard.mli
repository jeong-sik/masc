(** Immutable Keeper tool catalog facade.

    Tool families are an organizational detail only.  This module has no
    runtime membership or authorization state. *)

val sort_order_enum_strings : string list
val memory_search_source_enum_strings : string list
val memory_kind_enum_strings : string list
val writable_memory_kind_enum_strings : string list
val fs_write_mode_enum_strings : string list
val vote_direction_enum_strings : string list

val base_tools : Masc_domain.tool_schema list
val board_tools : Masc_domain.tool_schema list

val all_keeper_tool_schemas : Masc_domain.tool_schema list
(** Every schema family exposed by the Keeper catalog, de-duplicated by exact
    tool name while preserving catalog order. *)

val keeper_model_tools : Masc_domain.tool_schema list
(** The complete flat Keeper model catalog.  Equal to
    [all_keeper_tool_schemas]; execution-time external effects pass through
    the Gate instead of a catalog-membership hierarchy. *)
