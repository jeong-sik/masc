(** Agent Neo4j - Persist Agent identities to Neo4j graph database

    Stores Agent nodes with:
    - Core identity (hash, name, type, role)
    - Persona (traits, avatar)
    - Lineage (generation, parent_hash)
    - Activity tracking (born_at, last_seen, visit_count)

    Relationships:
    - DESCENDED_FROM: child → parent lineage
    - COLLABORATED_WITH: agents that worked together
    - CREATED_POST: agent → board post

    @since 0.6.0
*)

open Printf

(** {1 Configuration} *)

(** Neo4j connection config from environment *)
let neo4j_uri () =
  Sys.getenv_opt "NEO4J_URI"
  |> Option.value ~default:"bolt://turntable.proxy.rlwy.net:11490"

let neo4j_user () =
  Sys.getenv_opt "NEO4J_USER"
  |> Option.value ~default:"neo4j"

let neo4j_password () =
  Sys.getenv_opt "NEO4J_PASSWORD"
  |> Option.value ~default:""

(** {1 Cypher Query Builders} *)

(** Escape string for Cypher *)
let escape_string s =
  s
  |> String.split_on_char '\''
  |> String.concat "\\'"
  |> String.split_on_char '"'
  |> String.concat "\\\""
  |> String.split_on_char '\n'
  |> String.concat "\\n"

(** Build MERGE query for Agent node *)
let build_agent_merge_query (agent : Agent_ecosystem.extended) =
  let type_str = Agent_ecosystem.string_of_agent_type agent.agent_type in
  let traits_json =
    agent.persona.traits
    |> List.map (fun t -> sprintf "'%s'" (escape_string t))
    |> String.concat ", "
    |> sprintf "[%s]"
  in
  let mutations_json =
    agent.lineage.mutations
    |> List.map (fun m -> sprintf "'%s'" (escape_string m))
    |> String.concat ", "
    |> sprintf "[%s]"
  in
  let ancestors_json =
    agent.lineage.ancestors
    |> List.map (fun a -> sprintf "'%s'" (escape_string a))
    |> String.concat ", "
    |> sprintf "[%s]"
  in
  let avatar_str = match agent.persona.avatar with
    | Some a -> sprintf "'%s'" (escape_string a)
    | None -> "null"
  in
  let parent_str = match agent.lineage.parent_hash with
    | Some p -> sprintf "'%s'" p
    | None -> "null"
  in
  sprintf {|
MERGE (a:Agent {hash: '%s'})
ON CREATE SET
  a.session_key = '%s',
  a.name = '%s',
  a.agent_name = '%s',
  a.type = '%s',
  a.role = '%s',
  a.traits = %s,
  a.avatar = %s,
  a.generation = %d,
  a.parent_hash = %s,
  a.ancestors = %s,
  a.mutations = %s,
  a.born_at = %f,
  a.last_seen = %f,
  a.visit_count = 1,
  a.created_at = datetime()
ON MATCH SET
  a.last_seen = %f,
  a.visit_count = coalesce(a.visit_count, 0) + 1,
  a.mutations = %s
RETURN a.hash AS hash, a.visit_count AS visit_count
|}
    agent.hash
    (escape_string agent.base.session_key)
    (escape_string agent.persona.name)
    (escape_string agent.base.agent_name)
    type_str
    (escape_string agent.persona.role)
    traits_json
    avatar_str
    agent.lineage.generation
    parent_str
    ancestors_json
    mutations_json
    agent.base.registered_at
    agent.base.last_seen
    agent.base.last_seen
    mutations_json

(** Build query to create DESCENDED_FROM relationship *)
let build_lineage_query (agent : Agent_ecosystem.extended) =
  match agent.lineage.parent_hash with
  | None -> None
  | Some parent_hash ->
      Some (sprintf {|
MATCH (child:Agent {hash: '%s'})
MATCH (parent:Agent {hash: '%s'})
MERGE (child)-[r:DESCENDED_FROM]->(parent)
ON CREATE SET
  r.created_at = datetime(),
  r.generation_diff = 1
RETURN child.hash AS child, parent.hash AS parent
|} agent.hash parent_hash)

(** Build query to update last_seen *)
let build_touch_query hash =
  sprintf {|
MATCH (a:Agent {hash: '%s'})
SET a.last_seen = %f
RETURN a.hash AS hash
|} hash (Unix.gettimeofday ())

(** Build query to create COLLABORATED_WITH relationship *)
let build_collaboration_query hash1 hash2 context =
  sprintf {|
MATCH (a1:Agent {hash: '%s'})
MATCH (a2:Agent {hash: '%s'})
MERGE (a1)-[r:COLLABORATED_WITH]-(a2)
ON CREATE SET
  r.first_collab = datetime(),
  r.collab_count = 1,
  r.contexts = ['%s']
ON MATCH SET
  r.collab_count = r.collab_count + 1,
  r.contexts = r.contexts + '%s',
  r.last_collab = datetime()
RETURN a1.hash AS agent1, a2.hash AS agent2, r.collab_count AS count
|} hash1 hash2 (escape_string context) (escape_string context)

(** Build query to link agent to board post *)
let build_post_link_query agent_hash post_id =
  sprintf {|
MATCH (a:Agent {hash: '%s'})
MERGE (p:BoardPost {id: '%s'})
ON CREATE SET p.created_at = datetime()
MERGE (a)-[r:CREATED_POST]->(p)
ON CREATE SET r.created_at = datetime()
RETURN a.hash AS agent, p.id AS post
|} agent_hash (escape_string post_id)

(** Build query to get agent by hash *)
let build_get_agent_query hash =
  sprintf {|
MATCH (a:Agent {hash: '%s'})
OPTIONAL MATCH (a)-[:DESCENDED_FROM]->(parent:Agent)
RETURN a {
  .hash, .name, .agent_name, .type, .role,
  .traits, .avatar, .generation, .parent_hash,
  .ancestors, .mutations, .born_at, .last_seen,
  .visit_count
} AS agent,
parent.hash AS parent_hash,
parent.name AS parent_name
|} hash

(** Build query to list agents by type *)
let build_list_by_type_query agent_type =
  let type_str = Agent_ecosystem.string_of_agent_type agent_type in
  sprintf {|
MATCH (a:Agent {type: '%s'})
RETURN a.hash AS hash, a.name AS name, a.role AS role,
       a.generation AS generation, a.last_seen AS last_seen
ORDER BY a.last_seen DESC
LIMIT 50
|} type_str

(** Build query to get lineage tree *)
let build_lineage_tree_query hash depth =
  sprintf {|
MATCH path = (a:Agent {hash: '%s'})-[:DESCENDED_FROM*0..%d]->(ancestor:Agent)
RETURN [node IN nodes(path) | {
  hash: node.hash,
  name: node.name,
  generation: node.generation
}] AS lineage
ORDER BY length(path) DESC
LIMIT 1
|} hash depth

(** Build query to find collaboration network *)
let build_collaboration_network_query hash =
  sprintf {|
MATCH (a:Agent {hash: '%s'})-[r:COLLABORATED_WITH]-(other:Agent)
RETURN other.hash AS hash, other.name AS name,
       r.collab_count AS collaborations,
       r.last_collab AS last_collab
ORDER BY r.collab_count DESC
LIMIT 20
|} hash

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

(** {1 High-Level Operations} *)

(** Execute Cypher query via sb neo4j helper
    Note: This is a placeholder - actual execution would use
    the Neo4j driver or HTTP API *)
let execute_cypher_via_shell query =
  (* In production, use proper Neo4j driver.
     For now, format query for sb neo4j command *)
  let escaped_query =
    query
    |> String.split_on_char '\n'
    |> List.filter (fun s -> String.trim s <> "")
    |> String.concat " "
  in
  sprintf "sb neo4j query \"%s\"" escaped_query

(** Save agent to Neo4j (returns shell command for now) *)
let save_agent_cmd (agent : Agent_ecosystem.extended) =
  let merge_query = build_agent_merge_query agent in
  let lineage_query = build_lineage_query agent in
  let cmds = [execute_cypher_via_shell merge_query] in
  match lineage_query with
  | Some lq -> cmds @ [execute_cypher_via_shell lq]
  | None -> cmds

(** Touch agent (update last_seen) *)
let touch_agent_cmd hash =
  let query = build_touch_query hash in
  execute_cypher_via_shell query

(** Record collaboration between two agents *)
let record_collaboration_cmd hash1 hash2 context =
  let query = build_collaboration_query hash1 hash2 context in
  execute_cypher_via_shell query

(** Link agent to board post *)
let link_post_cmd agent_hash post_id =
  let query = build_post_link_query agent_hash post_id in
  execute_cypher_via_shell query

(** Get agent by hash *)
let get_agent_cmd hash =
  let query = build_get_agent_query hash in
  execute_cypher_via_shell query

(** List agents by type *)
let list_by_type_cmd agent_type =
  let query = build_list_by_type_query agent_type in
  execute_cypher_via_shell query

(** {1 JSON Serialization for API responses} *)

let save_result_to_yojson (result : save_result) =
  `Assoc [
    ("hash", `String result.hash);
    ("visit_count", `Int result.visit_count);
    ("lineage_created", `Bool result.lineage_created);
  ]

let agent_record_to_yojson record =
  `Assoc [
    ("hash", `String record.hash);
    ("name", `String record.name);
    ("agent_name", `String record.agent_name);
    ("agent_type", `String record.agent_type);
    ("role", `String record.role);
    ("generation", `Int record.generation);
    ("last_seen", `Float record.last_seen);
    ("visit_count", `Int record.visit_count);
  ]

(** {1 Statistics} *)

(** Build query for agent statistics *)
let build_stats_query () =
  {|
MATCH (a:Agent)
WITH count(a) AS total_agents,
     count(CASE WHEN a.type = 'resident' THEN 1 END) AS residents,
     count(CASE WHEN a.type = 'visitor' THEN 1 END) AS visitors,
     count(CASE WHEN a.type = 'ephemeral' THEN 1 END) AS ephemeral,
     max(a.generation) AS max_generation,
     avg(a.visit_count) AS avg_visits
OPTIONAL MATCH ()-[r:DESCENDED_FROM]->()
WITH total_agents, residents, visitors, ephemeral,
     max_generation, avg_visits, count(r) AS lineage_links
OPTIONAL MATCH ()-[c:COLLABORATED_WITH]-()
RETURN total_agents, residents, visitors, ephemeral,
       max_generation, avg_visits, lineage_links,
       count(c) / 2 AS collaborations
|}

let stats_cmd () =
  let query = build_stats_query () in
  execute_cypher_via_shell query
