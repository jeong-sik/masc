(** Knowledge Graph — Neo4j Knowledge node management.

    Schema:
      (:Agent)-[:KNOWS]->(:Knowledge {content, confidence, source, created_at})
      (:Knowledge)-[:SUPERSEDES]->(:Knowledge)
      (:Knowledge)-[:RELATES_TO]->(:Knowledge)

    Confidence decays 0.01/day. Re-verification resets decay.
    Injected into agent context on startup (within token budget).

    @since 2.90.0 *)

open Printf

(** A knowledge entry for Neo4j persistence. *)
type knowledge_entry = {
  id : string;
  agent_name : string;
  content : string;
  confidence : float;       (** 0.0-1.0, decays over time *)
  source : string;          (** Where this knowledge came from *)
  category : string;        (** "decision" | "learning" | "fact" | "procedure" *)
  created_at : float;
  last_verified : float;
  supersedes : string option;   (** ID of knowledge this supersedes *)
}

(** Escape string for Cypher queries. *)
let escape s =
  s
  |> String.split_on_char '\''
  |> String.concat "\\'"
  |> String.split_on_char '\n'
  |> String.concat "\\n"

(* ================================================================ *)
(* Cypher Query Builders                                            *)
(* ================================================================ *)

(** Create or update a Knowledge node and link it to an Agent. *)
let build_create_knowledge_query (k : knowledge_entry) =
  let supersedes_clause = match k.supersedes with
    | Some prev_id ->
      sprintf {|
WITH k
OPTIONAL MATCH (prev:Knowledge {id: '%s'})
FOREACH (_ IN CASE WHEN prev IS NOT NULL THEN [1] ELSE [] END |
  CREATE (k)-[:SUPERSEDES]->(prev)
  SET prev.superseded = true
)|} (escape prev_id)
    | None -> ""
  in
  sprintf {|MERGE (a:Agent {name: '%s'})
MERGE (k:Knowledge {id: '%s'})
ON CREATE SET
  k.content = '%s',
  k.confidence = %f,
  k.source = '%s',
  k.category = '%s',
  k.created_at = datetime({epochSeconds: %d}),
  k.last_verified = datetime({epochSeconds: %d}),
  k.superseded = false
ON MATCH SET
  k.content = '%s',
  k.confidence = %f,
  k.last_verified = datetime({epochSeconds: %d})
MERGE (a)-[:KNOWS]->(k)%s
RETURN k.id AS id, k.confidence AS confidence|}
    (escape k.agent_name)
    (escape k.id)
    (escape k.content) k.confidence (escape k.source) (escape k.category)
    (int_of_float k.created_at) (int_of_float k.last_verified)
    (escape k.content) k.confidence (int_of_float k.last_verified)
    supersedes_clause

(** Create a RELATES_TO relationship between two Knowledge nodes. *)
let build_relate_knowledge_query ~id_a ~id_b =
  sprintf {|MATCH (a:Knowledge {id: '%s'}), (b:Knowledge {id: '%s'})
MERGE (a)-[:RELATES_TO]->(b)
RETURN a.id, b.id|}
    (escape id_a) (escape id_b)

(** Apply confidence decay to all Knowledge nodes.
    decay = 0.01 per day since last_verified. *)
let build_decay_query () =
  {|MATCH (k:Knowledge)
WHERE k.superseded = false AND k.confidence > 0.0
WITH k, duration.between(k.last_verified, datetime()).days AS days_since
WHERE days_since > 0
SET k.confidence = CASE
  WHEN k.confidence - (days_since * 0.01) < 0.0 THEN 0.0
  ELSE k.confidence - (days_since * 0.01)
END
RETURN count(k) AS updated_count|}

(** Query recent Knowledge for an agent (within token budget). *)
let build_agent_knowledge_query ~agent_name ~limit =
  sprintf {|MATCH (a:Agent {name: '%s'})-[:KNOWS]->(k:Knowledge)
WHERE k.superseded = false AND k.confidence > 0.1
RETURN k.id, k.content, k.confidence, k.category, k.source
ORDER BY k.confidence DESC, k.last_verified DESC
LIMIT %d|}
    (escape agent_name) limit

(* ================================================================ *)
(* Local JSONL Cache (for offline/fallback)                         *)
(* ================================================================ *)

let knowledge_dir () =
  let me_root = Env_config.me_root () in
  Filename.concat me_root ".masc/knowledge"

let ensure_dir path =
  Fs_compat.mkdir_p path

let entry_to_json (k : knowledge_entry) : Yojson.Safe.t =
  `Assoc [
    ("id", `String k.id);
    ("agent_name", `String k.agent_name);
    ("content", `String k.content);
    ("confidence", `Float k.confidence);
    ("source", `String k.source);
    ("category", `String k.category);
    ("created_at", `Float k.created_at);
    ("last_verified", `Float k.last_verified);
    ("supersedes", match k.supersedes with Some s -> `String s | None -> `Null);
  ]

(** Append knowledge entry to local JSONL cache. *)
let cache_locally (k : knowledge_entry) =
  let dir = knowledge_dir () in
  ensure_dir dir;
  let path = Filename.concat dir (k.agent_name ^ ".jsonl") in
  Fs_compat.append_jsonl path (entry_to_json k)

(** Create a knowledge entry with auto-generated ID. *)
let create ~agent_name ~content ~confidence ~source ~category ?supersedes () =
  let now = Time_compat.now () in
  let id = sprintf "k-%s-%d-%06d" agent_name (int_of_float now) (Random.int 999999) in
  let entry = {
    id; agent_name; content; confidence; source; category;
    created_at = now; last_verified = now; supersedes;
  } in
  cache_locally entry;
  entry

(** Format knowledge entries for agent prompt injection. *)
let format_for_context (entries : knowledge_entry list) : string =
  if List.length entries = 0 then ""
  else
    let lines = List.map (fun k ->
      sprintf "- [%s/%.0f%%] %s" k.category (k.confidence *. 100.0) k.content
    ) entries in
    "[KNOWLEDGE]\n" ^ String.concat "\n" lines ^ "\n[/KNOWLEDGE]"
