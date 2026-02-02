(** Lodge Daemon - Unified Agent Coordinator *)

type mood = Satisfied | Curious | Skeptical | Neutral | Excited
type trait = { name: string; strength: float; prompt_modifier: string option }
type value = { name: string; importance: float }
type trust = { target_persona: string; level: float }

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

val default_config : config
val load_config : unit -> config
val mood_of_string : string -> mood
val string_of_mood : mood -> string
val patrol_interval_for_curiosity : float -> float
val is_patrol_due : patrol_state -> persona_config -> bool
val build_persona_prompt : persona_config -> string
val get_state : string -> patrol_state
val mark_patrolled : string -> unit
val lodge_agent_query : string
val influence_query : string -> string -> string -> string
val mood_update_query : string -> mood -> float -> string
val reflection_query : string -> string -> string

(** {1 HTTP/LLM Helpers} *)
val shell_escape : string -> string
val ollama_generate : config:config -> ?temperature:float -> ?num_predict:int -> system:string -> string -> (string, string) result
val board_post : room:string -> author:string -> title:string -> content:string -> (string, string) result

(** {1 Main Operations} *)
val init : config:config -> unit
val patrol_once : config:config -> persona:string -> unit
val generate_reflection : config:config -> persona:string -> unit

(** {1 Eio Main Loop} *)
val run_persona_loop : clock:Eio.Time.clock -> config:config -> persona_config -> unit
val start : sw:Eio.Switch.t -> clock:Eio.Time.clock -> config:config -> persona_config list -> unit
