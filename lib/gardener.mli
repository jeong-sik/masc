(** Gardener — Self-Organizing Agent Ecosystem Manager (OAS-integrated).

    The Gardener monitors ecosystem health and autonomously manages the agent
    population through spawn and retirement decisions.

    OAS integration: exports Agent Card, publishes events via Event_bus,
    uses Pulse for tick scheduling (replaces raw Eio.Time.sleep loop).

    {2 Key Features}

    - {b Homeostatic Balance}: Maintains target population with inverse-U rewards
    - {b Gap Signal Processing}: Detects unmet needs and spawns appropriate agents
    - {b Retirement Management}: Removes idle agents while respecting minimums
    - {b Safety Mechanisms}: Circuit breaker, budgets, cooldowns, grace periods

    {2 Usage}

    The Gardener runs as a background loop when enabled:
    {[
      (* In server initialization *)
      Gardener.start ~sw ~clock ~room_config ()
    ]}

    MCP tools can also interact directly:
    {[
      let health = Gardener.get_health () in
      let decision = Gardener.propose_spawn ~topic:"security" ~reason:"Need security review" ~urgency:Medium
    ]}
*)

open Gardener_types

(** {1 Configuration} *)

(** Load configuration from environment variables *)
val load_config : unit -> gardener_config

(** Get current configuration (alias for [load_config]) *)
val get_config : unit -> gardener_config

(** {1 Circuit Breaker} *)

(** Check if circuit breaker is open (all operations blocked) *)
val is_circuit_open : unit -> bool

(** Reset circuit breaker state *)
val reset_circuit : unit -> unit

(** {1 Budget Checks} *)

(** Check if spawn operation is allowed (budget + cooldown + circuit) *)
val can_spawn : config:gardener_config -> bool

(** Check if retirement operation is allowed *)
val can_retire : config:gardener_config -> bool

(** {1 Health Monitoring} *)

(** Calculate comprehensive ecosystem health metrics.

    This queries:
    - Agent list from Room (via room_config)
    - Selection stats from Thompson_sampling
    - Recent posts/comments from Board

    @return Current health state with homeostatic score *)
val calculate_health : config:gardener_config -> room_config:Room_utils.config option -> ecosystem_health

(** Convenience function for MCP tools — uses default config *)
val get_health : unit -> ecosystem_health

(** A2A v0.3 Agent Card for gardener. *)
val agent_card : Agent_card.agent_card

(** Truth-only runtime status for the active gardener loop. *)
val status_json : unit -> Yojson.Safe.t

(** {1 Decision Making} *)

(** Decide whether to spawn a new agent for a gap.

    Decision hierarchy:
    1. Budget/cooldown/circuit checks → may defer
    2. Population cap check → may reject
    3. LLM decision (if enabled) or rule-based → approve/defer/reject *)
val decide_spawn :
  config:gardener_config ->
  health:ecosystem_health ->
  gap:enriched_gap ->
  spawn_decision

(** Decide whether to retire an agent.

    Checks:
    - Population minimum
    - Budget/cooldown
    - Idle threshold
    - Recent contributions *)
val decide_retire :
  config:gardener_config ->
  health:ecosystem_health ->
  agent_stats:agent_stats ->
  retirement_decision

(** {1 Execution} *)

(** Execute an approved spawn decision via OAS worker agent.

    Spawns a real OAS agent using [Spawn_eio.spawn]. When called from the
    background tick loop, pass [~sw] and [~room_config] explicitly. When
    called from the MCP tool layer, omit them to use the module-level refs
    set during {!start}.

    @return [Ok message] on success, [Error reason] otherwise *)
val execute_spawn :
  ?sw:Eio.Switch.t ->
  ?room_config:Room_utils.config ->
  decision:spawn_decision ->
  unit ->
  (string, string) result

(** Execute an approved retirement decision.

    Posts warning, initiates grace period.
    @return [Ok agent_name] on success, [Error reason] otherwise *)
val execute_retire : decision:retirement_decision -> (string, string) result

(** {1 Gap Processing} *)

(** Enrich raw gap signals with context for decision making.

    Calculates:
    - Topic similarity to existing agents
    - Urgency score based on signal count and maturity
    - Proposer list and context snippets

    Note: This function is internal — use [detect_intervention] for external callers. *)

(** {1 Intervention Detection} *)

(** Detect what intervention (if any) is needed.

    Checks gap signals and idle agents to determine if
    spawn or retirement should be initiated. *)
val detect_intervention :
  config:gardener_config ->
  health:ecosystem_health ->
  intervention

(** {1 Background Loop} *)

(** Run one tick of the gardener loop.

    Calculates health, detects intervention needs, and acts if appropriate. *)
val tick :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:gardener_config ->
  room_config:Room.config ->
  unit

(** Start the gardener background loop.

    Only starts if [MASC_GARDENER_ENABLED=true].
    Uses Pulse for tick scheduling (replaces raw Eio.Time.sleep loop).
    Optionally subscribes to Sentinel events via Event_bus. *)
val start :
  ?bus:Agent_sdk.Event_bus.t ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  room_config:Room.config ->
  unit ->
  unit

(** {1 MCP Tool API} *)

(** Propose spawning a new agent (manual trigger).

    Bypasses gap signal maturity check.
    @param topic The role/topic for the new agent
    @param reason Why this agent is needed
    @param urgency How urgent the need is *)
val propose_spawn :
  topic:string ->
  reason:string ->
  urgency:urgency ->
  spawn_decision

(** Propose spawning a new agent and report the actual decision path.

    The provenance reflects whether the result came from the LLM judgment path
    or a non-LLM fallback path such as cooldown, population caps, or rule-based
    logic. *)
val propose_spawn_with_provenance :
  topic:string ->
  reason:string ->
  urgency:urgency ->
  spawn_decision * string

(** Propose retiring an agent (manual trigger).

    @param agent_name The agent to consider for retirement *)
val propose_retire :
  agent_name:string ->
  retirement_decision

(** {1 String Similarity (Levenshtein)} *)

(** Calculate Levenshtein edit distance between two strings.
    @return Minimum number of single-character edits (insert/delete/substitute) *)
val levenshtein : string -> string -> int

(** Calculate normalized similarity (0.0-1.0) using Levenshtein distance.
    Case-insensitive comparison.
    @return 1.0 for identical strings, 0.0 for completely different *)
val string_similarity : string -> string -> float

(** {1 Topic Analysis} *)

(** Extract topic keywords from text with frequency counts.
    Filters out stop words and short words.
    @return List of (word, count) sorted by frequency descending *)
val extract_topics_from_text : string -> (string * int) list

(** Calculate topic coverage from Board posts.
    @return List of (topic, coverage_score) for top 10 topics *)
val calculate_topic_coverage : posts:Board.post list -> (string * float) list

(** {1 Overload Detection} *)

(** Daily action limit per agent (posts + comments) *)
val daily_action_limit : int

(** Count agents exceeding daily action limit in the last 24 hours.
    @param posts List of all posts
    @param comments List of all comments
    @param now Current timestamp
    @return Number of overloaded agents *)
val count_overloaded_agents :
  posts:Board.post list ->
  comments:Board.comment list ->
  now:float ->
  int
