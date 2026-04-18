(** Tool_shard — Dynamic tool sharding for MASC agents.

    @since 2.62.0 *)

(** Issue #8480: hand-mirrored from
    [Keeper_tool_pr_review.valid_pr_review_event_strings]. Direct
    dependency would create a cycle (Tool_shard -> Keeper_tool_pr_review
    -> Keeper_alerting -> Tool_shard). The sync regression test
    [test_types.ml :: pr_review_event_ssot] catches drift. *)
val pr_review_event_enum_strings : string list

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Types.tool_schema list;
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

val tools_of_shards : string list -> Types.tool_schema list
(** Combine tools from multiple shard names. *)

(** {1 Dynamic Shard Management} *)

val grant_shard : string list -> string -> (string list, string) result
(** Grant a shard to an agent. Returns new active_shards list.
    @param active_shards Current list of granted shard names
    @param shard_name Shard to grant
    @return Ok new_list on success, Error msg on failure *)

val revoke_shard : string list -> string -> (string list, string) result
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

val base_tools : Types.tool_schema list
(** Core tools: time_now, context_status, memory_search. *)

val board_tools : Types.tool_schema list
(** Board tools: board_post, board_list, board_comment, board_vote. *)

(** {1 MCP Interface} *)

val schemas : Types.tool_schema list
(** MCP tool schemas for masc_tool_grant, masc_tool_revoke, masc_tool_list. *)

val execute : string -> Yojson.Safe.t -> (bool * Yojson.Safe.t)
(** Execute tool_shard MCP tools (grant, revoke, list).
    Agent shard state is tracked in-memory per agent. *)

val autoresearch_keeper_tools : Types.tool_schema list
(** Autoresearch tools for keeper use.
    (Earlier revisions excluded team-session swarm-start front doors;
    those front doors were removed along with the team_session module.) *)

val shard_autoresearch : shard
(** Autoresearch shard: start, cycle, status, inject, stop. *)

val coding_tools : Types.tool_schema list
(** Coding shard tools (keeper_bash + worktree/code inspection).
    keeper_shell with op=gh provides GitHub CLI access.
    Not in default shards. *)

val keeper_preflight_tools : Types.tool_schema list
(** Pre-flight validation tool schema. *)

val keeper_pr_review_tools : Types.tool_schema list
(** PR review tools (read, comment, reply) schemas. *)

val shard_coding : shard
(** Coding shard: github/shell bridge + worktree/code inspection. *)

val keeper_model_tools : Types.tool_schema list
(** Default tool set from default shards — excludes coding tools. *)
