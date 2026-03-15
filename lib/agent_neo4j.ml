(** Agent Neo4j - Persist Agent identities to Neo4j graph database

    Stores Agent nodes with:
    - Core identity (hash, name, type, role)
    - Profile (traits, avatar)
    - Lineage (generation, parent_hash)
    - Activity tracking (born_at, last_seen, visit_count)

    Relationships:
    - DESCENDED_FROM: child -> parent lineage
    - COLLABORATED_WITH: agents that worked together
    - CREATED_POST: agent -> board post

    All queries use parameterized Cypher ($param syntax) to prevent injection.

    @since 0.6.0
*)

(** {1 Types} *)

(** Parameterized Cypher query. [statement] uses [$param] placeholders;
    [params] carries corresponding values as JSON.
    The Neo4j driver (Bolt or HTTP) substitutes parameters server-side,
    preventing Cypher injection regardless of input content. *)
type cypher_query = {
  statement : string;
  params : (string * Yojson.Safe.t) list;
}

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

(** {1 Cypher Escaping (defense-in-depth for shell path only)} *)

(** Escape string for inline Cypher single-quoted literals.
    Handles: backslash, single quote, double quote, newline, CR, tab, null.
    Prefer parameterized queries ([cypher_query]) over inline escaping. *)
let escape_cypher_string s =
  let buf = Buffer.create (String.length s + 16) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\'' -> Buffer.add_string buf "\\'"
    | '"'  -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\x00' -> Buffer.add_string buf "\\u0000"
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(** {1 Query Serialization} *)

(** Convert a JSON value to an inline Cypher literal (for shell fallback). *)
let rec json_to_cypher_literal = function
  | `String v -> Printf.sprintf "'%s'" (escape_cypher_string v)
  | `Int n -> string_of_int n
  | `Float f -> Printf.sprintf "%g" f
  | `Bool b -> if b then "true" else "false"
  | `Null -> "null"
  | `List items ->
      let strs = List.map json_to_cypher_literal items in
      Printf.sprintf "[%s]" (String.concat ", " strs)
  | `Assoc _ as j -> Yojson.Safe.to_string j
  | `Intlit s -> s
  | `Tuple _ | `Variant _ -> "null"

(** Replace all occurrences of [pattern] with [replacement] in [s]. *)
let replace_all ~pattern ~replacement s =
  let plen = String.length pattern in
  let slen = String.length s in
  if plen = 0 then s
  else
    let buf = Buffer.create slen in
    let rec go i =
      if i > slen - plen then
        Buffer.add_substring buf s i (slen - i)
      else if String.sub s i plen = pattern then begin
        Buffer.add_string buf replacement;
        go (i + plen)
      end else begin
        Buffer.add_char buf s.[i];
        go (i + 1)
      end
    in
    go 0;
    Buffer.contents buf

(** Render a parameterized query with inline substitution.
    Used only for the shell command path. Prefer [to_http_payload]
    or [to_bolt_params] for production use. *)
let render_inline (q : cypher_query) : string =
  (* Sort params by key length descending to avoid partial matches:
     e.g. $last_seen before $last *)
  let sorted_params =
    List.sort (fun (k1, _) (k2, _) ->
      compare (String.length k2) (String.length k1)
    ) q.params
  in
  List.fold_left (fun cypher (key, value) ->
    replace_all ~pattern:("$" ^ key) ~replacement:(json_to_cypher_literal value) cypher
  ) q.statement sorted_params

(** Build JSON payload for Neo4j HTTP Transactional API.
    This is the primary safe execution path. Parameters are passed
    as a separate JSON object, never interpolated into the Cypher text. *)
let to_http_payload (q : cypher_query) : string =
  Yojson.Safe.to_string
    (`Assoc [
      ("statements", `List [
        `Assoc [
          ("statement", `String q.statement);
          ("parameters", `Assoc q.params);
        ]
      ])
    ])

(** Return (cypher, params) for use with Neo4j Bolt driver.
    Pass directly to [Neo4j_client_eio.query ~cypher ~params]. *)
let to_bolt_params (q : cypher_query) : string * Yojson.Safe.t =
  (q.statement, `Assoc q.params)

(** Build a shell command for [sb neo4j query].
    Uses [Filename.quote] for shell safety and inline parameter rendering
    with [escape_cypher_string] as defense-in-depth. *)
let to_shell_cmd (q : cypher_query) : string =
  let cypher = render_inline q in
  let oneliner =
    cypher
    |> String.split_on_char '\n'
    |> List.filter (fun s -> String.trim s <> "")
    |> String.concat " "
  in
  Printf.sprintf "sb neo4j query %s" (Filename.quote oneliner)

(** {1 Parameterized Query Builders} *)

(** Build MERGE query for Agent node *)
let build_agent_merge_query (agent : Agent_ecosystem.extended) =
  let type_str = Agent_ecosystem.string_of_agent_type agent.agent_type in
  let traits_json = `List (List.map (fun t -> `String t) agent.profile.traits) in
  let mutations_json = `List (List.map (fun m -> `String m) agent.lineage.mutations) in
  let ancestors_json = `List (List.map (fun a -> `String a) agent.lineage.ancestors) in
  let avatar_param = match agent.profile.avatar with
    | Some a -> `String a
    | None -> `Null
  in
  let parent_param = match agent.lineage.parent_hash with
    | Some p -> `String p
    | None -> `Null
  in
  { statement = {|
MERGE (a:Agent {hash: $hash})
ON CREATE SET
  a.session_key = $session_key,
  a.name = $name,
  a.agent_name = $agent_name,
  a.type = $type,
  a.role = $role,
  a.traits = $traits,
  a.avatar = $avatar,
  a.generation = $generation,
  a.parent_hash = $parent_hash,
  a.ancestors = $ancestors,
  a.mutations = $mutations,
  a.born_at = $born_at,
  a.last_seen = $last_seen,
  a.visit_count = 1,
  a.created_at = datetime()
ON MATCH SET
  a.last_seen = $last_seen,
  a.visit_count = coalesce(a.visit_count, 0) + 1,
  a.mutations = $mutations
RETURN a.hash AS hash, a.visit_count AS visit_count
|};
    params = [
      ("hash", `String agent.hash);
      ("session_key", `String agent.base.session_key);
      ("name", `String agent.profile.name);
      ("agent_name", `String agent.base.agent_name);
      ("type", `String type_str);
      ("role", `String agent.profile.role);
      ("traits", traits_json);
      ("avatar", avatar_param);
      ("generation", `Int agent.lineage.generation);
      ("parent_hash", parent_param);
      ("ancestors", ancestors_json);
      ("mutations", mutations_json);
      ("born_at", `Float agent.base.registered_at);
      ("last_seen", `Float agent.base.last_seen);
    ];
  }

(** Build query to create DESCENDED_FROM relationship *)
let build_lineage_query (agent : Agent_ecosystem.extended) =
  match agent.lineage.parent_hash with
  | None -> None
  | Some parent_hash ->
      Some { statement = {|
MATCH (child:Agent {hash: $child_hash})
MATCH (parent:Agent {hash: $parent_hash})
MERGE (child)-[r:DESCENDED_FROM]->(parent)
ON CREATE SET
  r.created_at = datetime(),
  r.generation_diff = 1
RETURN child.hash AS child, parent.hash AS parent
|};
        params = [
          ("child_hash", `String agent.hash);
          ("parent_hash", `String parent_hash);
        ];
      }

(** Build query to update last_seen *)
let build_touch_query hash =
  { statement = {|
MATCH (a:Agent {hash: $hash})
SET a.last_seen = $now
RETURN a.hash AS hash
|};
    params = [
      ("hash", `String hash);
      ("now", `Float (Time_compat.now ()));
    ];
  }

(** Build query to create COLLABORATED_WITH relationship *)
let build_collaboration_query hash1 hash2 context =
  { statement = {|
MATCH (a1:Agent {hash: $hash1})
MATCH (a2:Agent {hash: $hash2})
MERGE (a1)-[r:COLLABORATED_WITH]-(a2)
ON CREATE SET
  r.first_collab = datetime(),
  r.collab_count = 1,
  r.contexts = [$context]
ON MATCH SET
  r.collab_count = r.collab_count + 1,
  r.contexts = r.contexts + $context,
  r.last_collab = datetime()
RETURN a1.hash AS agent1, a2.hash AS agent2, r.collab_count AS count
|};
    params = [
      ("hash1", `String hash1);
      ("hash2", `String hash2);
      ("context", `String context);
    ];
  }

(** Build query to link agent to board post *)
let build_post_link_query agent_hash post_id =
  { statement = {|
MATCH (a:Agent {hash: $agent_hash})
MERGE (p:BoardPost {id: $post_id})
ON CREATE SET p.created_at = datetime()
MERGE (a)-[r:CREATED_POST]->(p)
ON CREATE SET r.created_at = datetime()
RETURN a.hash AS agent, p.id AS post
|};
    params = [
      ("agent_hash", `String agent_hash);
      ("post_id", `String post_id);
    ];
  }

(** Build query to get agent by hash *)
let build_get_agent_query hash =
  { statement = {|
MATCH (a:Agent {hash: $hash})
OPTIONAL MATCH (a)-[:DESCENDED_FROM]->(parent:Agent)
RETURN a {
  .hash, .name, .agent_name, .type, .role,
  .traits, .avatar, .generation, .parent_hash,
  .ancestors, .mutations, .born_at, .last_seen,
  .visit_count
} AS agent,
parent.hash AS parent_hash,
parent.name AS parent_name
|};
    params = [("hash", `String hash)];
  }

(** Build query to list agents by type *)
let build_list_by_type_query agent_type =
  let type_str = Agent_ecosystem.string_of_agent_type agent_type in
  { statement = {|
MATCH (a:Agent {type: $type})
RETURN a.hash AS hash, a.name AS name, a.role AS role,
       a.generation AS generation, a.last_seen AS last_seen
ORDER BY a.last_seen DESC
LIMIT 50
|};
    params = [("type", `String type_str)];
  }

(** Build query to get lineage tree.
    NOTE: Neo4j does not support parameters in variable-length relationship
    ranges. The [depth] argument is an [int], so inline substitution is
    safe -- no injection risk from numeric types. *)
let build_lineage_tree_query hash depth =
  { statement = Printf.sprintf {|
MATCH path = (a:Agent {hash: $hash})-[:DESCENDED_FROM*0..%d]->(ancestor:Agent)
RETURN [node IN nodes(path) | {
  hash: node.hash,
  name: node.name,
  generation: node.generation
}] AS lineage
ORDER BY length(path) DESC
LIMIT 1
|} depth;
    params = [("hash", `String hash)];
  }

(** Build query to find collaboration network *)
let build_collaboration_network_query hash =
  { statement = {|
MATCH (a:Agent {hash: $hash})-[r:COLLABORATED_WITH]-(other:Agent)
RETURN other.hash AS hash, other.name AS name,
       r.collab_count AS collaborations,
       r.last_collab AS last_collab
ORDER BY r.collab_count DESC
LIMIT 20
|};
    params = [("hash", `String hash)];
  }

(** {1 High-Level Operations} *)

(** Save agent to Neo4j — returns queries to execute *)
let save_agent_queries (agent : Agent_ecosystem.extended) =
  let merge = build_agent_merge_query agent in
  match build_lineage_query agent with
  | Some lineage -> [merge; lineage]
  | None -> [merge]

(** Save agent — returns shell commands (legacy interface).
    Prefer [save_agent_queries] with [to_bolt_params] for production use. *)
let save_agent_cmd (agent : Agent_ecosystem.extended) =
  save_agent_queries agent |> List.map to_shell_cmd

(** Touch agent (update last_seen) *)
let touch_agent_cmd hash =
  build_touch_query hash |> to_shell_cmd

(** Record collaboration between two agents *)
let record_collaboration_cmd hash1 hash2 context =
  build_collaboration_query hash1 hash2 context |> to_shell_cmd

(** Link agent to board post *)
let link_post_cmd agent_hash post_id =
  build_post_link_query agent_hash post_id |> to_shell_cmd

(** Get agent by hash *)
let get_agent_cmd hash =
  build_get_agent_query hash |> to_shell_cmd

(** List agents by type *)
let list_by_type_cmd agent_type =
  build_list_by_type_query agent_type |> to_shell_cmd

(** {1 Statistics} *)

(** Build query for agent statistics (no user input, no parameters needed) *)
let build_stats_query () =
  { statement = {|
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
|};
    params = [];
  }

let stats_cmd () =
  build_stats_query () |> to_shell_cmd

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
