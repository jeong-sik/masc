(** Tool_shard_types — pure Keeper schema families. *)

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

val wiki_tools : Masc_domain.tool_schema list

val max_rich_blocks : int
(** Canonical maximum number of top-level Slack Block Kit blocks per message. *)

val surface_tools : Masc_domain.tool_schema list
(** Surface read/post schemas projected into help and dispatch registries. *)

val taskboard_tools : Masc_domain.tool_schema list
(** Taskboard tool schemas. *)
