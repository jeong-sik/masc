(** Tool_shard_types — pure types + enum-string SSOT mirrors extracted
    from Tool_shard (2165 LoC godfile).

    Holds the [shard] record + 7 enum-string lists hand-mirrored from
    keeper-side validators (#8480/#8484/#8490/#8506/#8513/#8524/#8527).
    State-touching shard registries remain in Tool_shard. Re-included
    by Tool_shard so existing callers continue to use [Tool_shard.shard]
    etc. unchanged. *)

val pr_review_event_enum_strings : string list
(** Hand-mirrored from [Keeper_tool_pr_review.valid_pr_review_event_strings]
    (#8480). *)

val sort_order_enum_strings : string list
(** Hand-mirrored from [Board_dispatch.valid_sort_order_strings] (#8513). *)

val keeper_shell_op_enum_strings : string list
(** Hand-mirrored from [Keeper_exec_shell.valid_shell_op_strings] (#8524). *)

val memory_search_source_enum_strings : string list
(** Hand-mirrored from [Keeper_exec_memory.valid_memory_search_source_strings]
    (#8484). *)

val memory_kind_enum_strings : string list
(** Hand-mirrored from [Keeper_memory_policy.valid_memory_kind_strings]
    (#8527). *)

val fs_write_mode_enum_strings : string list
(** Hand-mirrored from [Keeper_exec_fs.valid_fs_write_mode_strings]
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
(** Pure: the 7 shards granted to a fresh agent. *)

val tool_spec_read_only : string list
val tool_spec_destructive : string list

val tool_required_permission :
  string -> Masc_domain.permission option
(** Pure: required keeper permission for invoking a Tool_shard MASC tool. *)

val tool_effect_domain :
  string -> Tool_catalog.effect_domain option
(** Pure: tool-catalog effect-domain classification for a Tool_shard MASC tool. *)

val base_tools : Masc_domain.tool_schema list
(** Pure: base tool schemas (always-on tools every keeper sees). *)

val board_tools : Masc_domain.tool_schema list
(** Pure: keeper_board tool schemas. *)

val filesystem_tools : Masc_domain.tool_schema list
(** Pure: keeper_fs tool schemas. *)

val shell_tools : Masc_domain.tool_schema list
(** Pure: keeper_shell tool schemas. *)

val coding_keeper_bridge_tools : Masc_domain.tool_schema list
(** Pure: keeper_bash bridge tool schemas. *)

val keeper_pr_review_tools : Masc_domain.tool_schema list
(** PR review tools — read diffs, leave comments, approve/request changes. *)

val coding_workspace_tool_names : string list
(** Tool names that compose [coding_workspace_tools]. *)

val keeper_preflight_tools : Masc_domain.tool_schema list
(** Pre-flight validation tools for keeper autonomous work. *)

val keeper_github_pr_tools : Masc_domain.tool_schema list
(** Dedicated GitHub PR workflow tools (list/view/create/checks). *)
