(** Tool_shard — Dynamic tool sharding for MASC agents.

    @since 2.62.0 *)

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Llm_client.tool_def list;
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

val tools_of_shards : string list -> Llm_client.tool_def list
(** Combine tools from multiple shard names. *)

val keeper_llm_tools : Llm_client.tool_def list
(** Full tool set (all 11 tools) — backward compatible with existing code. *)
