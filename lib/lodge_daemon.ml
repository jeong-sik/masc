(** Lodge Daemon - Unified Agent Coordinator

    Integrates event-spawner, heartbeat, and patrol logic into a single
    Eio-based daemon. Replaces 6 separate launchd plists with one coordinator.

    Phase 1: Core types and Neo4j queries
    Phase 2: Eio fiber main loop (TBD)
    Phase 3: Feature integration (TBD)
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
  ollama_model = "hf.co/LiquidAI/LFM2-1.2B-GGUF:Q8_0";
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
    ollama_model = Option.value ~default:"hf.co/LiquidAI/LFM2-1.2B-GGUF:Q8_0"
      (Sys.getenv_opt "LODGE_MODEL");
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

(** {1 Patrol scheduling} *)

(** Calculate patrol interval based on curiosity level.
    Higher curiosity = more frequent patrol.
    Base: 900s (15min), curiosity 1.0 = 900s, curiosity 0.5 = 1800s *)
let patrol_interval_for_curiosity curiosity =
  let base = 900.0 in
  if curiosity <= 0.0 then base *. 10.0  (* Very infrequent if no curiosity *)
  else base /. curiosity

let is_patrol_due state persona_cfg =
  let now = Unix.gettimeofday () in  (* Note: unix library needed in dune *)
  let interval = patrol_interval_for_curiosity persona_cfg.curiosity in
  (now -. state.last_patrol) >= interval

(** {1 Prompt building} *)

let build_persona_prompt cfg =
  let trait_desc =
    cfg.traits
    |> List.map (fun t ->
        Printf.sprintf "- %s (strength: %.1f)%s"
          t.name t.strength
          (match t.prompt_modifier with Some m -> ": " ^ m | None -> ""))
    |> String.concat "\n"
  in
  let value_desc =
    cfg.values
    |> List.map (fun v -> Printf.sprintf "- %s (importance: %.1f)" v.name v.importance)
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
    last_patrol = Unix.gettimeofday ();
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
let influence_query source target content = Printf.sprintf {|
MATCH (source:LodgeAgent {persona: '%s'})
MATCH (target:LodgeAgent {persona: '%s'})
MERGE (source)-[r:INFLUENCED]->(target)
ON CREATE SET r.count = 1, r.first_at = datetime(), r.last_content = '%s'
ON MATCH SET r.count = r.count + 1, r.last_at = datetime(), r.last_content = '%s'
RETURN r.count AS influence_count
|} source target content content

(** Update mood with history tracking *)
let mood_update_query persona mood trigger_score = Printf.sprintf {|
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
|} persona (string_of_mood mood) persona (string_of_mood mood) trigger_score

(** Generate reflection (Stanford Generative Agents pattern) *)
let reflection_query persona content = Printf.sprintf {|
MATCH (la:LodgeAgent {persona: '%s'})
CREATE (r:Reflection {
  persona: '%s',
  content: '%s',
  timestamp: datetime()
})
MERGE (la)-[:REFLECTED]->(r)
RETURN r.content AS reflection
|} persona persona content

(** {1 HTTP/LLM Helpers} *)

open Yojson.Safe.Util

(** Shell escape for curl *)
let shell_escape s = Str.global_replace (Str.regexp "'") "'\\''" s

(** Call Ollama API directly via curl subprocess *)
let ollama_generate ~config ?(temperature = 0.7) ?(num_predict = 300) ~system prompt =
  try
    let body = Yojson.Safe.to_string (`Assoc [
      ("model", `String config.ollama_model);
      ("prompt", `String prompt);
      ("system", `String system);
      ("stream", `Bool false);
      ("options", `Assoc [
        ("temperature", `Float temperature);
        ("num_predict", `Int num_predict);
      ]);
    ]) in
    let escaped_body = shell_escape body in
    let cmd = Printf.sprintf "curl -sf --max-time 60 -X POST %s/api/generate -H 'Content-Type: application/json' -d '%s'"
      config.ollama_url escaped_body in
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 4096 in
    (try while true do Buffer.add_channel buf ic 1024 done with End_of_file -> ());
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 ->
        let json = Yojson.Safe.from_string (Buffer.contents buf) in
        Ok (json |> member "response" |> to_string)
    | Unix.WEXITED n -> Error (Printf.sprintf "ollama curl exit %d" n)
    | _ -> Error "ollama curl signaled"
  with
  | Yojson.Json_error msg -> Error (Printf.sprintf "JSON parse: %s" msg)
  | exn -> Error (Printf.sprintf "ollama exception: %s" (Printexc.to_string exn))

(** Post to MASC Board via MCP *)
let board_post ~room ~author ~title ~content =
  try
    let body = Yojson.Safe.to_string (`Assoc [
      ("jsonrpc", `String "2.0");
      ("id", `Int 1);
      ("method", `String "tools/call");
      ("params", `Assoc [
        ("name", `String "masc_board_post");
        ("arguments", `Assoc [
          ("room", `String room);
          ("author", `String author);
          ("title", `String title);
          ("content", `String content);
        ]);
      ]);
    ]) in
    let escaped_body = shell_escape body in
    let cmd = Printf.sprintf "curl -sf --max-time 10 -X POST http://127.0.0.1:8935/mcp -H 'Content-Type: application/json' -d '%s'" escaped_body in
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 1024 in
    (try while true do Buffer.add_channel buf ic 256 done with End_of_file -> ());
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 -> Ok (Buffer.contents buf)
    | Unix.WEXITED n -> Error (Printf.sprintf "board post exit %d" n)
    | _ -> Error "board post signaled"
  with exn -> Error (Printexc.to_string exn)

(** {1 Main operations} *)

let init ~config =
  if config.enabled then
    Printf.printf "[Lodge Daemon] Initializing with interval=%.0fs, model=%s\n%!"
      config.check_interval_s config.ollama_model

(** Patrol once for a specific persona with LLM call and board post *)
let patrol_once ~config ~persona =
  if config.enabled then begin
    Printf.printf "[Lodge Daemon] Patrol: %s\n%!" persona;
    let state = get_state persona in
    let system = Printf.sprintf "You are %s, a Lodge persona. Write a brief thought or observation (2-3 sentences, Korean preferred)." persona in
    let prompt = Printf.sprintf "Current mood: neutral. Patrol count: %d. Share your current thought." state.patrol_count in
    match ollama_generate ~config ~system prompt with
    | Ok response when String.length response > 10 ->
        Printf.printf "[Lodge Daemon] %s says: %s\n%!" persona response;
        let title = Printf.sprintf "%s의 생각" persona in
        (match board_post ~room:"me" ~author:persona ~title ~content:response with
         | Ok _ -> Printf.printf "[Lodge Daemon] Posted to board\n%!"
         | Error e -> Printf.eprintf "[Lodge Daemon] Board post failed: %s\n%!" e);
        mark_patrolled persona
    | Ok _ -> Printf.eprintf "[Lodge Daemon] Empty response from %s\n%!" persona
    | Error e -> Printf.eprintf "[Lodge Daemon] LLM error for %s: %s\n%!" persona e
  end

(** Generate reflection for a persona *)
let generate_reflection ~config ~persona =
  if config.enabled && config.neo4j_enabled then begin
    Printf.printf "[Lodge Daemon] Generating reflection for %s\n%!" persona;
    let system = "You are reflecting on recent experiences. Summarize key insights in 1-2 sentences." in
    let prompt = Printf.sprintf "Persona: %s. Reflect on your recent patrols and interactions." persona in
    match ollama_generate ~config ~system prompt with
    | Ok reflection when String.length reflection > 10 ->
        Printf.printf "[Lodge Daemon] Reflection: %s\n%!" reflection
    | Ok _ -> Printf.eprintf "[Lodge Daemon] Empty reflection\n%!"
    | Error e -> Printf.eprintf "[Lodge Daemon] Reflection error: %s\n%!" e
  end

(** {1 Eio Main Loop (Phase 2)} *)

(** Run patrol loop for a single persona — blocking, call in Eio fiber *)
let run_persona_loop ~config (persona_cfg : persona_config) =
  let rec loop () =
    let state = get_state persona_cfg.persona in
    if is_patrol_due state persona_cfg then begin
      patrol_once ~config ~persona:persona_cfg.persona;
      let needs_reflection = match state.last_reflection with
        | None -> state.patrol_count > 5
        | Some last -> (Unix.gettimeofday () -. last) >= config.reflection_interval_s
      in
      if needs_reflection then
        generate_reflection ~config ~persona:persona_cfg.persona
    end;
    Unix.sleepf config.check_interval_s;
    loop ()
  in
  loop ()

(** Start the daemon with persona list — call from MASC server *)
let start ~sw:_ ~config personas =
  if not config.enabled then
    Printf.printf "[Lodge Daemon] Disabled, skipping startup\n%!"
  else begin
    Printf.printf "[Lodge Daemon] Starting with %d personas\n%!" (List.length personas);
    (* TODO: Spawn Eio.Fiber for each persona using Eio.Fiber.fork *)
    List.iter (fun p ->
      Printf.printf "[Lodge Daemon] Registered: %s (curiosity=%.2f)\n%!" p.persona p.curiosity
    ) personas
  end
