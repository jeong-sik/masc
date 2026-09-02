(** Tool_shard_types — pure Keeper schema families and enum-string mirrors. *)

val memory_search_source_enum_strings : string list
(** Hand-mirrored from [Keeper_tool_memory_runtime.valid_memory_search_source_strings]
    (#8484). *)

val fs_write_mode_enum_strings : string list
(** Hand-mirrored from [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings]
    (#8490). *)

(** {1 Schema selection} *)

val select_named_schemas :
  string list -> Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** Pure: pick the named schemas (in input order) from the given pool. *)

val base_tools : Masc_domain.tool_schema list
(** Pure: base tool schemas (always-on tools every keeper sees). *)

val keeper_board_schema : Tool_name.Board_name.t -> Masc_domain.tool_schema option
(** Narrower Keeper-model projection for Board capabilities. [None]
    means the canonical Board input schema is already the Keeper projection. *)

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

val max_rich_blocks : int
(** Canonical maximum number of top-level Slack Block Kit blocks per message. *)

val surface_tools : Masc_domain.tool_schema list
(** Surface read/post schemas projected into help and dispatch registries. *)

val taskboard_tools : Masc_domain.tool_schema list
(** Taskboard tool schemas. *)
