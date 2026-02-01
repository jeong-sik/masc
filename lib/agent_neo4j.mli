(** Agent Neo4j - Persist Agent identities to Neo4j graph database

    @since 0.6.0
*)

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

(** {1 Cypher Query Builders} *)

val build_agent_merge_query : Agent_ecosystem.extended -> string
val build_lineage_query : Agent_ecosystem.extended -> string option
val build_touch_query : string -> string
val build_collaboration_query : string -> string -> string -> string
val build_post_link_query : string -> string -> string
val build_get_agent_query : string -> string
val build_list_by_type_query : Agent_ecosystem.agent_type -> string
val build_lineage_tree_query : string -> int -> string
val build_collaboration_network_query : string -> string
val build_stats_query : unit -> string

(** {1 Shell Command Operations} *)

(** Save agent to Neo4j - returns shell commands to execute *)
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
