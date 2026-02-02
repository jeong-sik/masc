(** Lodge Daemon - Unified Agent Coordinator *)

type mood = Satisfied | Curious | Skeptical | Neutral | Excited
type trait = { name: string; strength: float; prompt_modifier: string option }
type value = { name: string; importance: float }
type trust = { target_agent: string; level: float }

type agent_config = {
  agent: string;
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

val default_config : config
val load_config : unit -> config
val mood_of_string : string -> mood
val string_of_mood : mood -> string
val patrol_interval_for_curiosity : float -> float
val is_patrol_due : patrol_state -> agent_config -> bool
val build_agent_prompt : agent_config -> string
val get_state : string -> patrol_state
val mark_patrolled : string -> unit
val lodge_agent_query : string
val influence_query : string -> string -> string -> string
val mood_update_query : string -> mood -> float -> string
val reflection_query : string -> string -> string
val init : config:config -> unit
val patrol_once : config:config -> agent_name:string -> unit
val generate_reflection : config:config -> agent_name:string -> unit

(* NOTE: Eio fiber main loop is in Lodge_heartbeat module *)
