(** Agent Neo4j - Persist Agent identities to Neo4j graph database

    All queries use parameterized Cypher ($param syntax) to prevent injection.

    @since 0.6.0
*)

(** {1 Types} *)

(** Parameterized Cypher query. [statement] uses [$param] placeholders;
    [params] carries corresponding values.
    Pass to [to_bolt_params], [to_http_payload], or [to_shell_cmd]. *)
type cypher_query = {
  statement : string;
  params : (string * Yojson.Safe.t) list;
}

(** {1 Configuration} *)

val neo4j_uri : unit -> string
val neo4j_user : unit -> string
val neo4j_password : unit -> string

(** {1 Result Types} *)

type save_result = {
  hash : string;
  visit_count : int;
  lineage_created : bool;
}

type agent_record = {
  hash : string;
  name : string;
  agent_name : string;
  agent_type : string;
  role : string;
  generation : int;
  last_seen : float;
  visit_count : int;
}

(** {1 Cypher Query Builders}

    All builders return parameterized [cypher_query] values.
    Use [to_bolt_params] or [to_http_payload] for safe execution. *)

val build_agent_merge_query : Agent_ecosystem.extended -> cypher_query
val build_lineage_query : Agent_ecosystem.extended -> cypher_query option
val build_touch_query : string -> cypher_query
val build_collaboration_query : string -> string -> string -> cypher_query
val build_post_link_query : string -> string -> cypher_query
val build_get_agent_query : string -> cypher_query
val build_list_by_type_query : Agent_ecosystem.agent_type -> cypher_query
val build_lineage_tree_query : string -> int -> cypher_query
val build_collaboration_network_query : string -> cypher_query
val build_stats_query : unit -> cypher_query

(** {1 Query Serialization} *)

(** Escape a string for inline Cypher use (defense-in-depth).
    Prefer parameterized queries. *)
val escape_cypher_string : string -> string

(** JSON payload for Neo4j HTTP Transactional API (primary safe path). *)
val to_http_payload : cypher_query -> string

(** [(cypher, params)] for use with [Neo4j_client_eio.query]. *)
val to_bolt_params : cypher_query -> string * Yojson.Safe.t

(** Shell command for [sb neo4j query] with proper escaping. *)
val to_shell_cmd : cypher_query -> string

(** {1 High-Level Operations} *)

(** Save agent — returns parameterized queries *)
val save_agent_queries : Agent_ecosystem.extended -> cypher_query list

(** Save agent — returns shell commands (legacy interface) *)
val save_agent_cmd : Agent_ecosystem.extended -> string list

(** Update agent's last_seen timestamp *)
val touch_agent_cmd : string -> string

(** Record collaboration between two agents *)
val record_collaboration_cmd : string -> string -> string -> string

(** Link agent to a board post *)
val link_post_cmd : string -> string -> string

(** Get agent by hash *)
val get_agent_cmd : string -> string

(** List agents by type *)
val list_by_type_cmd : Agent_ecosystem.agent_type -> string

(** Get agent statistics *)
val stats_cmd : unit -> string

(** {1 JSON Serialization} *)

val save_result_to_yojson : save_result -> Yojson.Safe.t
val agent_record_to_yojson : agent_record -> Yojson.Safe.t
