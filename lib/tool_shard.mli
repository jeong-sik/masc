
(** Tool_shard — Dynamic tool sharding for MASC agents.

    @since 2.62.0 *)

(** Issue #8513: hand-mirrored from
    [Board_dispatch.valid_sort_order_strings] (#8453 SSOT). Schema
    previously hand-listed 3 of 5 sort orders; sync regression test in
    [test_types.ml :: sort_order_schema_ssot] catches drift. *)
val sort_order_enum_strings : string list


(** Issue #8484: hand-mirrored from
    [Keeper_tool_memory_runtime.valid_memory_search_source_strings]. Sync
    regression test in [test_types.ml :: memory_search_source_ssot]
    catches drift. *)
val memory_search_source_enum_strings : string list

(** Issue #8527: hand-mirrored from
    [Keeper_memory_policy.valid_memory_kind_strings]. Sync regression
    test in [test_types.ml :: memory_kind_ssot] catches drift. *)
val memory_kind_enum_strings : string list

(** Explicit-write subset mirrored from
    [Keeper_memory_policy.writable_memory_kind_strings]. *)
val writable_memory_kind_enum_strings : string list

(** Issue #8490: hand-mirrored from
    [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings]. Sync regression test
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

val shard_search_files : shard
(** Grep structured repo inspection access. *)

(** {1 Lookup} *)

val get_shard : string -> shard option
(** Get a shard by name. *)

(** {1 Tool Composition} *)

val default_shard_names : string list
(** Default shards for a new keeper: base, board, filesystem, search_files,
    library, taskboard. *)

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
(** Empty: [masc_tool_*] callable tools are not exposed. *)

val execute : string -> Yojson.Safe.t -> (bool * Yojson.Safe.t)
(** Legacy compatibility entrypoint. [masc_tool_*] calls are no longer
    exposed and return unknown. Internal shard state is managed through
    keeper/persona configuration, not callable tools. *)

val all_keeper_tool_schemas : Masc_domain.tool_schema list
(** #10101: every keeper-facing tool schema exposed by this
    module, built from [all_shards] plus unsharded default tools.
    Feeds [Config.raw_all_tool_schemas] so
    [Tool_help_registry.find_entry] can resolve every shard
    tool.  Duplicates are possible; dedupe at consumer. *)

val keeper_model_tools : Masc_domain.tool_schema list
(** Default tool set from default shards. *)
