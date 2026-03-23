(** Tool_shard — Dynamic tool sharding for MASC agents.

    @since 2.62.0 *)

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Types.tool_schema list;
  removable : bool;
  description : string;
}

(** {1 Predefined Shards} *)

val shard_base : shard
(** Core tools: time, context, memory. Not removable. *)

val shard_board : shard
(** MASC Board: post, list, comment. *)

val shard_filesystem : shard
(** File I/O: read, edit. *)

val shard_shell : shard
(** Shell access: bash, github. *)

val shard_weather : shard
(** Weather queries. *)

(** {1 Lookup} *)

val get_shard : string -> shard option
(** Get a shard by name. *)

val all_shards : (string, shard) Hashtbl.t
(** All predefined shards by name. *)

(** {1 Tool Composition} *)

val default_shard_names : string list
(** Default shards for a new keeper: base, board, filesystem, shell, weather. *)

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

val list_all_shards : unit -> (string * bool * int) list
(** List all available shards with their status.
    Returns (name, removable, tool_count) tuples. *)

(** {1 Per-Agent Shard State} *)

val agent_shards : (string, string list) Hashtbl.t
(** Global agent → active_shards mapping. *)

val get_agent_shards : string -> string list
(** Get shards for an agent. Returns [default_shard_names] if unset. *)

val set_agent_shards : string -> string list -> unit
(** Set active shards for an agent. *)

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
    Agent shard state is tracked in-memory via [agent_shards] hashtable. *)

val autoresearch_keeper_tools : Types.tool_schema list
(** Autoresearch tools for keeper use (excludes swarm_start). *)

val shard_autoresearch : shard
(** Autoresearch shard: start, cycle, status, inject, stop. *)

val coding_tools : Types.tool_schema list
(** Coding shard tools (keeper_bash, keeper_github).
    Not in default shards — only granted when policy_shell_mode = "coding". *)

val shard_coding : shard
(** Coding shard: bash, github (requires policy_shell_mode=coding). *)

val keeper_model_tools : Types.tool_schema list
(** Default tool set from default shards — excludes coding tools. *)
