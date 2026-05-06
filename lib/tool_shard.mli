
(** Tool_shard — Dynamic tool sharding for MASC agents.

    @since 2.62.0 *)

(** Issue #8480: hand-mirrored from
    [Keeper_tool_pr_review.valid_pr_review_event_strings]. Direct
    dependency would create a cycle (Tool_shard -> Keeper_tool_pr_review
    -> Keeper_alerting -> Tool_shard). The sync regression test
    [test_types.ml :: pr_review_event_ssot] catches drift. *)
val pr_review_event_enum_strings : string list

(** Issue #8513: hand-mirrored from
    [Board_dispatch.valid_sort_order_strings] (#8453 SSOT). Schema
    previously hand-listed 3 of 5 sort orders; sync regression test in
    [test_types.ml :: sort_order_schema_ssot] catches drift. *)
val sort_order_enum_strings : string list

(** Issue #8524: hand-mirrored from
    [Keeper_exec_shell.valid_shell_op_strings]. Schema previously
    omitted git_worktree; sync regression test in
    [test_types.ml :: keeper_shell_op_ssot] catches drift. *)
val keeper_shell_op_enum_strings : string list

(** Issue #8484: hand-mirrored from
    [Keeper_exec_memory.valid_memory_search_source_strings]. Sync
    regression test in [test_types.ml :: memory_search_source_ssot]
    catches drift. *)
val memory_search_source_enum_strings : string list

(** Issue #8527: hand-mirrored from
    [Keeper_memory_policy.valid_memory_kind_strings]. Sync regression
    test in [test_types.ml :: memory_kind_ssot] catches drift. *)
val memory_kind_enum_strings : string list

(** Issue #8490: hand-mirrored from
    [Keeper_exec_fs.valid_fs_write_mode_strings]. Sync regression test
    in [test_types.ml :: fs_write_mode_ssot] catches drift. *)
val fs_write_mode_enum_strings : string list


(** Issue #8506: hand-mirrored from
    [Board_votes.valid_vote_direction_strings]. Sync regression test
    in [test_types.ml :: vote_direction_ssot] catches drift. *)
val vote_direction_enum_strings : string list

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Masc_domain.tool_schema list;
  read_only_tools : string list;
  (** Tool names within this shard that have no side effects.
      Used by [Keeper_tool_registry] to derive the read-only set
      instead of maintaining a separate hardcoded list. *)
  removable : bool;
  description : string;
}

(** {1 Predefined Shards} *)

val shard_base : shard
(** Core tools: time, context, memory. Not removable. *)

val shard_board : shard
(** MASC Board: post, list, comment. *)

val shard_filesystem : shard
(** File I/O: read-only inspection. *)

val shard_shell : shard
(** Structured read-only shell access. *)

(** {1 Lookup} *)

val get_shard : string -> shard option
(** Get a shard by name. *)

(** {1 Tool Composition} *)

val default_shard_names : string list
(** Default shards for a new keeper: base, board, filesystem, shell,
    library, taskboard, coding, autoresearch. *)

val tools_of_shards : string list -> Masc_domain.tool_schema list
(** Combine tools from multiple shard names. *)

(** {1 Dynamic Shard Management} *)

val grant_shard : string list -> string -> (string list, string) Result.t
(** Grant a shard to an agent. Returns new active_shards list.
    @param active_shards Current list of granted shard names
    @param shard_name Shard to grant
    @return Ok new_list on success, Error msg on failure *)

val revoke_shard : string list -> string -> (string list, string) Result.t
(** Revoke a shard from an agent. Returns new active_shards list.
    @param active_shards Current list of granted shard names
    @param shard_name Shard to revoke (must be removable)
    @return Ok new_list on success, Error msg on failure *)

val all_read_only_keeper_tools : unit -> string list
(** Collect read_only_tools from all shards. *)

val recovery_minimum_shard_names : unit -> string list
(** Shard names where [removable = false]. Property-based recovery floor:
    these shards cannot be revoked and remain available in Failing phase.
    Phase B2: TLA+ ToolSetNeverEmpty relies on this being non-empty. *)

val list_all_shards : unit -> (string * bool * int) list
(** List all available shards with their status.
    Returns (name, removable, tool_count) tuples. *)

(** {1 Per-Agent Shard State} *)

val get_agent_shards : string -> string list
(** Get shards for an agent. Returns [default_shard_names] if unset. *)

val set_agent_shards : string -> string list -> unit
(** Set active shards for an agent. *)

val remove_agent_shards : string -> unit
(** Remove agent from the shard registry (resets to defaults). *)

(** {1 Tool Definitions} *)

val base_tools : Masc_domain.tool_schema list
(** Core tools: time_now, context_status, memory_search. *)

val board_tools : Masc_domain.tool_schema list
(** Board tools: board_post, board_list, board_comment, board_vote. *)

(** {1 MCP Interface} *)

val schemas : Masc_domain.tool_schema list
(** MCP tool schemas for masc_tool_grant, masc_tool_revoke, masc_tool_list. *)

val execute : string -> Yojson.Safe.t -> (bool * Yojson.Safe.t)
(** Execute tool_shard MCP tools (grant, revoke, list).
    Agent shard state is tracked in-memory per agent. *)

val autoresearch_keeper_tools : Masc_domain.tool_schema list
(** Autoresearch tools for keeper use.
    (Earlier revisions excluded now-removed orchestration front doors.) *)

val shard_autoresearch : shard
(** Autoresearch shard: start, cycle, status, inject, stop. *)

val coding_tools : Masc_domain.tool_schema list
(** Coding shard tools (keeper_bash + worktree/code inspection).
    keeper_shell with op=gh provides GitHub CLI access.
    Not in default shards. *)

val keeper_preflight_tools : Masc_domain.tool_schema list
(** Pre-flight validation tool schema. *)

val keeper_github_pr_tools : Masc_domain.tool_schema list
(** Dedicated GitHub PR workflow tools (list, status, draft create). *)

val all_keeper_tool_schemas : Masc_domain.tool_schema list
(** #10101: every keeper-facing tool schema exposed by this
    module, built from [all_shards] (so new shard categories
    flow through automatically) plus the non-shard lists
    [keeper_preflight_tools], [keeper_github_pr_tools], and
    [keeper_pr_review_tools].
    Feeds [Config.raw_all_tool_schemas] so
    [Tool_help_registry.find_entry] can resolve every shard
    tool.  Duplicates are possible; dedupe at consumer. *)

val keeper_pr_review_tools : Masc_domain.tool_schema list
(** PR review tools (read, comment, reply) schemas. *)

val shard_coding : shard
(** Coding shard: github/shell bridge + worktree/code inspection. *)

val keeper_model_tools : Masc_domain.tool_schema list
(** Default tool set from default shards — excludes coding tools. *)
