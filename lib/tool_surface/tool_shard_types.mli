(** Tool_shard_types — pure Keeper schema families and enum-string mirrors. *)

val sort_order_enum_strings : string list
(** Hand-mirrored from [Board_dispatch.valid_sort_order_strings] (#8513). *)

val memory_search_source_enum_strings : string list
(** Hand-mirrored from [Keeper_tool_memory_runtime.valid_memory_search_source_strings]
    (#8484). *)

val memory_kind_enum_strings : string list
(** Hand-mirrored from [Keeper_memory_policy.valid_memory_kind_strings]
    (#8527). *)

val writable_memory_kind_enum_strings : string list
(** Hand-mirrored from [Keeper_memory_policy.writable_memory_kind_strings]. *)

val fs_write_mode_enum_strings : string list
(** Hand-mirrored from [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings]
    (#8490). *)

val vote_direction_enum_strings : string list
(** Hand-mirrored from [Board_votes.valid_vote_direction_strings] (#8506). *)

(** {1 Schema selection} *)

val select_named_schemas :
  string list -> Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** Pure: pick the named schemas (in input order) from the given pool. *)

val base_tools : Masc_domain.tool_schema list
(** Pure: base tool schemas (always-on tools every keeper sees). *)

val board_tools : Masc_domain.tool_schema list
(** Pure: keeper_board tool schemas. *)

val filesystem_tools : Masc_domain.tool_schema list
(** Pure: file tool schemas. *)

val search_files_tools : Masc_domain.tool_schema list
(** Pure: structured search tool schemas. *)

val typed_execute_tools : Masc_domain.tool_schema list
(** Pure: typed execution tool schemas. *)

val tool_execute_schema : Masc_domain.tool_schema
(** Canonical typed Execute schema exposed through the public facade. *)

val voice_tools : Masc_domain.tool_schema list
(** Voice tool schemas. *)

val library_tools : Masc_domain.tool_schema list

val surface_tools : Masc_domain.tool_schema list
(** keeper_surface_read lane reading (RFC-0223 P3). *)
(** Library tool schemas. *)

val taskboard_tools : Masc_domain.tool_schema list
(** Taskboard tool schemas. *)
