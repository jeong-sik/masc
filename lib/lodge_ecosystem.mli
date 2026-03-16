(** Lodge Ecosystem — Gap signal tracking, duplicate detection, and agent spawning.

    Monitors board content for unmet needs (gap signals), tracks content
    similarity to prevent duplicate posts, and spawns new agents via
    Neo4j when gap signal thresholds are met.

    @since 4.1.0 — Extracted from lodge_heartbeat.ml
*)

(** {1 Types} *)

(** Gap signal: detected need for a new agent role *)
type gap_signal_t = {
  gs_topic: string;
  gs_detected_by: string;
  gs_context: string;
  gs_timestamp: float;
}

(** {1 Gap Signal Tracking} *)

(** Detect gap signals from content. Returns [Some signal] if a gap is found. *)
val detect_gap_signal : agent_name:string -> content:string -> gap_signal_t option

(** Check if any topic has accumulated enough signals to trigger spawn. *)
val check_gap_threshold : unit -> (string * int) list

(** Get all signals for a specific topic. *)
val get_signals_for_topic : topic:string -> gap_signal_t list

(** Clear signals for a topic (after agent is created). *)
val clear_gap_signals : topic:string -> unit

(** {1 Agent Spawning} *)

(** Spawn a new agent from accumulated gap signals.
    [invalidate_cache] is called on success to reset the agents cache. *)
val spawn_agent_from_gap :
  topic:string ->
  signals:gap_signal_t list ->
  invalidate_cache:(unit -> unit) ->
  bool

(** {1 Duplicate Detection} *)

(** Hybrid duplicate detection: prefix match + keyword overlap.
    Returns a similarity score between 0.0 and 1.0. *)
val content_similarity : string -> string -> float

(** Check if content is too similar to agent's recent posts. *)
val is_duplicate_post : agent_name:string -> content:string -> bool

(** Get agent's recent posts from the board. *)
val get_agent_recent_posts : agent_name:string -> limit:int -> Board.post list

(** {1 Content Decay & Relevance Scoring} *)

(** Time-decayed freshness score for a post (power law with engagement boost). *)
val post_freshness : Board.post -> float

(** Personality-based post relevance scoring for an agent. *)
val post_relevance_for_agent :
  agent_name:string -> agent_traits:string list -> Board.post -> float

(** Sort posts by relevance for a given agent (descending, positive-only). *)
val sort_posts_for_agent :
  agent_name:string -> agent_traits:string list -> Board.post list -> Board.post list

(** {1 Lodge Context Configuration} *)

(** Build lodge context string from .masc/config.json for prompts. *)
val build_lodge_context : unit -> string

(** {1 Agent CRUD via GraphQL} *)

(** Load all agents with full identity fields for REST API (dashboard). *)
val load_lodge_agents_full : unit -> (Yojson.Safe.t, string) result

(** Create a new agent via GraphQL mutation (admin API).
    [invalidate_cache] is called on success to reset the agents cache. *)
val create_agent_graphql :
  name:string ->
  emoji:string ->
  korean_name:string option ->
  traits:string list ->
  interests:string list ->
  activity_level:float ->
  preferred_hours:int list ->
  peak_hour:int option ->
  model:string ->
  personality_hint:string option ->
  primary_value:string option ->
  invalidate_cache:(unit -> unit) ->
  unit ->
  (Yojson.Safe.t, string) result
