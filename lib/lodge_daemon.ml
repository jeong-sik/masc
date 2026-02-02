(** Lodge Daemon - Utility Types and Neo4j Queries

    Provides persona configuration types and Neo4j Cypher query builders.
    The actual Eio fiber daemon is in {!Lodge_heartbeat}.

    - Persona types: mood, trait, value, trust
    - Neo4j queries: influence, mood update, reflection
    - Curiosity-based interval calculation
*)

(** {1 Types} *)

type mood = Satisfied | Curious | Skeptical | Neutral | Excited

type trait = {
  name: string;
  strength: float;
  prompt_modifier: string option;
}

type value = {
  name: string;
  importance: float;
}

type trust = {
  target_persona: string;
  level: float;
}

type persona_config = {
  persona: string;
  recognition_need: float;
  influence_desire: float;
  curiosity: float;
  mood: mood;
  traits: trait list;
  values: value list;
  trusts: trust list;
}

type patrol_state = {
  last_patrol: float;
  patrol_count: int;
  last_reflection: float option;
}

type config = {
  enabled: bool;
  check_interval_s: float;
  heartbeat_interval_s: float;
  reflection_interval_s: float;
  ollama_url: string;
  ollama_model: string;
  neo4j_enabled: bool;
}

(** {1 Configuration} *)

let default_config = {
  enabled = false;
  check_interval_s = 60.0;
  heartbeat_interval_s = 30.0;
  reflection_interval_s = 3600.0;  (* 1 hour *)
  ollama_url = "http://127.0.0.1:11434";
  ollama_model = "glm-4.7-flash:latest";  (* 128k context *)
  neo4j_enabled = true;
}

let load_config () =
  let get_env_float name default =
    match Sys.getenv_opt name with
    | Some s -> (try float_of_string s with _ -> default)
    | None -> default
  in
  let get_env_bool name default =
    match Sys.getenv_opt name with
    | Some "true" | Some "1" -> true
    | Some "false" | Some "0" -> false
    | _ -> default
  in
  {
    enabled = get_env_bool "LODGE_DAEMON_ENABLED" false;
    check_interval_s = get_env_float "LODGE_CHECK_INTERVAL" 60.0;
    heartbeat_interval_s = get_env_float "LODGE_HEARTBEAT_INTERVAL" 30.0;
    reflection_interval_s = get_env_float "LODGE_REFLECTION_INTERVAL" 3600.0;
    ollama_url = Option.value ~default:"http://127.0.0.1:11434"
      (Sys.getenv_opt "OLLAMA_URL");
    (* Always use long-context model - no env override needed *)
    ollama_model = "glm-4.7-flash:latest";
    neo4j_enabled = get_env_bool "LODGE_NEO4J_ENABLED" true;
  }

(** {1 Mood handling} *)

let mood_of_string = function
  | "satisfied" | "Satisfied" -> Satisfied
  | "curious" | "Curious" -> Curious
  | "skeptical" | "Skeptical" -> Skeptical
  | "excited" | "Excited" -> Excited
  | _ -> Neutral

let string_of_mood = function
  | Satisfied -> "satisfied"
  | Curious -> "curious"
  | Skeptical -> "skeptical"
  | Neutral -> "neutral"
  | Excited -> "excited"

(** {1 Cypher escaping for injection prevention} *)

(** Escape string for safe use in Cypher single-quoted literals *)
let cypher_escape s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (function
    | '\'' -> Buffer.add_string buf "\\'"
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(** {1 Patrol scheduling} *)

(** Calculate patrol interval based on curiosity level.
    Higher curiosity = more frequent patrol.
    Base: 900s (15min), curiosity 1.0 = 900s, curiosity 0.5 = 1800s *)
let patrol_interval_for_curiosity curiosity =
  let base = 900.0 in
  if curiosity <= 0.0 then base *. 10.0  (* Very infrequent if no curiosity *)
  else base /. curiosity

let is_patrol_due state persona_cfg =
  let now = Time_compat.now () in  (* Note: unix library needed in dune *)
  let interval = patrol_interval_for_curiosity persona_cfg.curiosity in
  (now -. state.last_patrol) >= interval

(** {1 Prompt building} *)

let build_persona_prompt cfg =
  let trait_desc =
    cfg.traits
    |> List.map (fun (t : trait) ->
        Printf.sprintf "- %s (strength: %.1f)%s"
          t.name t.strength
          (match t.prompt_modifier with Some m -> ": " ^ m | None -> ""))
    |> String.concat "\n"
  in
  let value_desc =
    cfg.values
    |> List.map (fun (v : value) -> Printf.sprintf "- %s (importance: %.1f)" v.name v.importance)
    |> String.concat "\n"
  in
  Printf.sprintf {|You are %s, a Lodge agent with the following characteristics:

## Core Drives
- Recognition need: %.1f (0=humble, 1=attention-seeking)
- Influence desire: %.1f (0=passive, 1=want to shape others)
- Curiosity: %.1f (0=content, 1=always exploring)
- Current mood: %s

## Traits
%s

## Values
%s

Respond authentically to this persona. Keep responses concise (2-3 sentences).
|}
    cfg.persona
    cfg.recognition_need
    cfg.influence_desire
    cfg.curiosity
    (string_of_mood cfg.mood)
    trait_desc
    value_desc

(** {1 State management} *)

(* In-memory state storage - will be persisted to Neo4j in Phase 2 *)
let state_table : (string, patrol_state) Hashtbl.t = Hashtbl.create 10

let get_state persona =
  match Hashtbl.find_opt state_table persona with
  | Some s -> s
  | None -> { last_patrol = 0.0; patrol_count = 0; last_reflection = None }

let mark_patrolled persona =
  let state = get_state persona in
  Hashtbl.replace state_table persona {
    state with
    last_patrol = Time_compat.now ();
    patrol_count = state.patrol_count + 1;
  }

(** {1 Neo4j Cypher queries} *)

(** Load all active LodgeAgents with their traits, values, and trust relationships *)
let lodge_agent_query = {|
MATCH (la:LodgeAgent {active: true})
OPTIONAL MATCH (la)-[:HAS_TRAIT]->(t:Trait)
OPTIONAL MATCH (la)-[:VALUES]->(v:Value)
OPTIONAL MATCH (la)-[:TRUSTS]->(other:LodgeAgent)
RETURN la.persona AS persona,
       la.recognition_need AS recognition_need,
       la.influence_desire AS influence_desire,
       la.curiosity AS curiosity,
       la.mood AS mood,
       collect(DISTINCT {name: t.name, strength: t.strength, modifier: t.prompt_modifier}) AS traits,
       collect(DISTINCT {name: v.name, importance: v.importance}) AS values,
       collect(DISTINCT {target: other.persona, level: la.trust_level}) AS trusts
|}

(** Record social influence between personas *)
let influence_query source target content =
  let src = cypher_escape source in
  let tgt = cypher_escape target in
  let cnt = cypher_escape content in
  Printf.sprintf {|
MATCH (source:LodgeAgent {persona: '%s'})
MATCH (target:LodgeAgent {persona: '%s'})
MERGE (source)-[r:INFLUENCED]->(target)
ON CREATE SET r.count = 1, r.first_at = datetime(), r.last_content = '%s'
ON MATCH SET r.count = r.count + 1, r.last_at = datetime(), r.last_content = '%s'
RETURN r.count AS influence_count
|} src tgt cnt cnt

(** Update mood with history tracking *)
let mood_update_query persona mood trigger_score =
  let p = cypher_escape persona in
  let m = string_of_mood mood in  (* enum, safe *)
  Printf.sprintf {|
MATCH (la:LodgeAgent {persona: '%s'})
SET la.mood = '%s',
    la.mood_updated_at = datetime()
CREATE (mh:MoodHistory {
  persona: '%s',
  mood: '%s',
  trigger_score: %.2f,
  timestamp: datetime()
})
RETURN la.persona, la.mood
|} p m p m trigger_score

(** Generate reflection (Stanford Generative Agents pattern) *)
let reflection_query persona content =
  let p = cypher_escape persona in
  let c = cypher_escape content in
  Printf.sprintf {|
MATCH (la:LodgeAgent {persona: '%s'})
CREATE (r:Reflection {
  persona: '%s',
  content: '%s',
  timestamp: datetime()
})
MERGE (la)-[:REFLECTED]->(r)
RETURN r.content AS reflection
|} p p c

(** {1 Main operations} *)

let init ~config =
  if config.enabled then
    Printf.printf "[Lodge Daemon] Initializing with interval=%.0fs, model=%s\n%!"
      config.check_interval_s config.ollama_model

(** Patrol once for a specific persona - Phase 2 will add actual LLM call *)
let patrol_once ~config ~persona =
  if config.enabled then begin
    Printf.printf "[Lodge Daemon] Patrol: %s (model: %s)\n%!" persona config.ollama_model;
    mark_patrolled persona
  end

(** Generate reflection for a persona *)
let generate_reflection ~config ~persona =
  if config.enabled && config.neo4j_enabled then
    Printf.printf "[Lodge Daemon] Reflection: %s\n%!" persona

(* NOTE: Eio fiber main loop is in lodge_heartbeat.ml
   This module provides utility types and Neo4j queries only.
   See Lodge_heartbeat.start for the actual daemon. *)
