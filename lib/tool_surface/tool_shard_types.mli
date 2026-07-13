(** Tool_shard_types — pure types + enum-string SSOT mirrors extracted
    from Tool_shard (2165 LoC godfile).

    Holds the [shard] record + enum-string lists hand-mirrored from
    keeper-side validators (#8480/#8484/#8490/#8506/#8513/#8524/#8527).
    State-touching shard registries remain in Tool_shard. Re-included
    by Tool_shard so existing callers continue to use [Tool_shard.shard]
    etc. unchanged. *)

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

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Masc_domain.tool_schema list;
  read_only_tools : string list;
  removable : bool;
  description : string;
}

module StringMap : Map.S with type key = string

(** {1 Schema selection + agent shard helpers} *)

val select_named_schemas :
  string list -> Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** Pure: pick the named schemas (in input order) from the given pool. *)

val default_shard_names : string list
(** Pure: the default shards granted to a fresh agent. *)

val tool_spec_read_only : string list

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
