(** Gardener Types — Self-Organizing Agent Ecosystem

    Type definitions for the Gardener Agent that manages ecosystem homeostasis.

    {2 Design Principles}

    - {b Homeostatic Balance}: The ecosystem maintains a target population,
      penalizing both over- and under-population (inverse-U reward curve).
    - {b Safety First}: Hard limits on population bounds (min/max), daily budgets,
      and cooldowns prevent runaway spawning or retirement.
    - {b Circuit Breaker}: Consecutive failures trigger a cooldown period to
      prevent cascading errors.
*)

(** {1 Urgency Levels} *)

type urgency =
  | Low       (** Normal gap, can wait *)
  | Medium    (** Multiple signals, should act soon *)
  | High      (** Many signals, act within hours *)
  | Critical  (** Ecosystem health at risk *)

val urgency_of_string : string -> urgency
val string_of_urgency : urgency -> string
val urgency_to_yojson : urgency -> Yojson.Safe.t
val urgency_of_yojson : Yojson.Safe.t -> (urgency, string) result

val pp_urgency : Format.formatter -> urgency -> unit
val show_urgency : urgency -> string
val equal_urgency : urgency -> urgency -> bool

(** {1 Agent Statistics} *)

(** Per-agent activity metrics used for health assessment *)
type agent_stats = {
  name: string;
  posts_24h: int;           (** Posts in last 24 hours *)
  comments_24h: int;        (** Comments in last 24 hours *)
  votes_received_24h: int;  (** Votes received in last 24 hours *)
  last_active: float;       (** Unix timestamp of last activity *)
  idle_hours: float;        (** Hours since last activity *)
  thompson_alpha: float;    (** Thompson sampling alpha (successes) *)
  thompson_beta: float;     (** Thompson sampling beta (failures) *)
}

val agent_stats_to_yojson : agent_stats -> Yojson.Safe.t
val pp_agent_stats : Format.formatter -> agent_stats -> unit
val show_agent_stats : agent_stats -> string

(** {1 Task Backlog Summary} *)

(** Summary of MASC task backlog state for ecosystem health assessment *)
type task_backlog_summary = {
  total_tasks: int;               (** Total tasks in backlog *)
  todo_count: int;                (** Unclaimed TODO tasks *)
  claimed_count: int;             (** Claimed but not started *)
  in_progress_count: int;         (** Currently in progress *)
  done_count: int;                (** Completed tasks *)
  orphan_count: int;              (** Claimed/in_progress with offline assignee *)
  oldest_todo_age_hours: float;   (** Age of oldest unclaimed task in hours *)
  high_priority_todo: int;        (** P1-P2 unclaimed tasks *)
}

val task_backlog_summary_to_yojson : task_backlog_summary -> Yojson.Safe.t
val pp_task_backlog_summary : Format.formatter -> task_backlog_summary -> unit
val show_task_backlog_summary : task_backlog_summary -> string

val empty_task_backlog : task_backlog_summary

(** {1 Ecosystem Health} *)

(** Comprehensive health metrics for the agent ecosystem.

    The [homeostatic_score] is calculated using an inverse-U curve:
    - Score is 1.0 when population equals target
    - Score decreases as population diverges from target in either direction
    - Formula: [1.0 - abs(current - target) / max(target - min, max - target)]
*)
type ecosystem_health = {
  total_agents: int;           (** Total registered agents *)
  active_agents: int;          (** Agents with activity in last 24h *)
  idle_agents: int;            (** Agents with no activity in 24h+ *)
  overloaded_agents: int;      (** Agents above daily action limit *)

  posts_24h: int;              (** Total posts in last 24h *)
  comments_24h: int;           (** Total comments in last 24h *)
  unanswered_questions: int;   (** Posts with "?" but no comments *)

  topic_coverage: (string * float) list;  (** (topic, coverage_score) pairs *)
  selection_entropy: float;    (** Diversity of agent selection (0-1) *)

  homeostatic_score: float;    (** Overall balance score (0-1) *)
  needs_spawn: bool;           (** Ecosystem needs more agents *)
  needs_retirement: bool;      (** Ecosystem has too many idle agents *)

  last_spawn: float option;    (** Unix timestamp of last spawn *)
  last_retirement: float option;  (** Unix timestamp of last retirement *)
  spawns_today: int;           (** Spawns in last 24h *)
  retirements_today: int;      (** Retirements in last 24h *)

  (* Task-aware fields *)
  task_backlog: task_backlog_summary;  (** MASC task backlog state *)
  system_error_rate: float;    (** Error rate from telemetry (0.0-1.0) *)
  needs_workers: bool;         (** todo > 0 AND no available workers *)
  room_active_agents: int;     (** Non-Inactive agents currently in room *)
}

val ecosystem_health_to_yojson : ecosystem_health -> Yojson.Safe.t
val pp_ecosystem_health : Format.formatter -> ecosystem_health -> unit
val show_ecosystem_health : ecosystem_health -> string

(** {1 Gap Signal Types} *)

(** Gap signal detected by agents. *)
type gap_signal_t = {
  gs_topic : string;
  gs_detected_by : string;
  gs_context : string;
  gs_timestamp : float;
}

(** Minimal agent record for topic similarity calculations. *)
type agent = {
  name : string;
  traits : string list;
  preferred_hours : int list;
  activity_level : string;
}

(** {1 Enriched Gap Signal} *)

(** Gap signal enriched with context for spawn decisions.
    Maturity is important: gaps must "age" before triggering spawns
    to avoid reacting to transient needs. *)
type enriched_gap = {
  topic: string;                (** Gap topic (e.g., "security", "UX") *)
  signal_count: int;            (** Number of accumulated signals *)
  proposers: string list;       (** Agents who detected the gap *)
  context_snippets: string list; (** Relevant conversation snippets *)
  first_detected: float;        (** When first signal was recorded *)
  maturity_hours: float;        (** Hours since first detection *)
  topic_similarity: float;      (** Similarity to existing agents (0-1) *)
  urgency_score: float;         (** Calculated urgency (0-1) *)
}

val enriched_gap_to_yojson : enriched_gap -> Yojson.Safe.t
val pp_enriched_gap : Format.formatter -> enriched_gap -> unit
val show_enriched_gap : enriched_gap -> string

(** {1 Spawn Decision} *)

(** Result of spawn decision process.

    Decisions follow a strict hierarchy:
    1. Hard limits (population max, daily budget) → Rejected
    2. Cooldown checks → Deferred with retry time
    3. LLM decision (if enabled) → Approved/Rejected
    4. Rule-based decision → Approved/Rejected
*)
type spawn_decision =
  | SpawnApproved of {
      topic: string;
      urgency: urgency;
      proposed_traits: string list;
      proposed_hours: int list;
      reason: string;
    }
  | SpawnDeferred of {
      topic: string;
      retry_after_sec: float;
      reason: string;
    }
  | SpawnRejected of {
      topic: string;
      reason: string;
    }

val spawn_decision_to_yojson : spawn_decision -> Yojson.Safe.t
val pp_spawn_decision : Format.formatter -> spawn_decision -> unit
val show_spawn_decision : spawn_decision -> string

(** {1 Retirement Decision} *)

(** Result of retirement decision process.

    Retirement includes a grace period where the agent is warned
    before actual removal. This allows:
    - Agent to increase activity
    - Human review if needed
    - Graceful cleanup of any active tasks
*)
type retirement_decision =
  | RetireApproved of {
      agent_name: string;
      reason: string;
      grace_period_sec: float;  (** Warning time before actual retirement *)
    }
  | RetireDeferred of {
      agent_name: string;
      retry_after_sec: float;
      reason: string;
    }
  | RetireRejected of {
      agent_name: string;
      reason: string;
    }

val retirement_decision_to_yojson : retirement_decision -> Yojson.Safe.t
val pp_retirement_decision : Format.formatter -> retirement_decision -> unit
val show_retirement_decision : retirement_decision -> string

(** {1 Triage Outcome} *)

(** Outcome of the last backlog triage session *)
type triage_outcome =
  | Triage_none       (** No triage attempted yet *)
  | Triage_productive (** Triage resulted in claimed tasks *)
  | Triage_noop       (** Triage completed but no tasks claimed *)

val string_of_triage_outcome : triage_outcome -> string
val pp_triage_outcome : Format.formatter -> triage_outcome -> unit
val show_triage_outcome : triage_outcome -> string
val equal_triage_outcome : triage_outcome -> triage_outcome -> bool

(** {1 Gardener State} *)

(** Persistent state for the Gardener Agent.

    State tracks:
    - Timing of last operations for cooldown enforcement
    - Daily budget consumption
    - Circuit breaker status
*)
type gardener_state = {
  mutable last_health_check: float;
  mutable last_tick_started_at: float;
  mutable last_tick_completed_at: float;
  mutable last_spawn_attempt: float;
  mutable last_retirement_attempt: float;
  mutable consecutive_failures: int;
  mutable circuit_open_until: float option;
  mutable spawns_today: int;
  mutable retirements_today: int;
  mutable last_intervention: string;
  mutable last_decision_source: string;
  mutable last_action: string;
  mutable last_target: string;
  mutable last_reason: string;
  mutable last_error: string;
  mutable tick_count: int;
  mutable last_total_agents: int;
  mutable last_active_agents: int;
  mutable last_idle_agents: int;
  mutable last_todo_count: int;
  mutable last_high_priority_todo: int;
  mutable last_orphan_count: int;
  mutable last_homeostatic_score: float;
  mutable last_needs_workers: bool;
  mutable last_room_active_agents: int;
  mutable day_start: float;  (** Start of current "day" for budget tracking *)
  mutable last_triage_started_at: float;
  mutable last_triage_outcome: triage_outcome;
}

val make_gardener_state : unit -> gardener_state
val pp_gardener_state : Format.formatter -> gardener_state -> unit
val show_gardener_state : gardener_state -> string

(** {1 Gardener Configuration} *)

(** Configuration for the Gardener Agent.

    All values are loaded from environment variables with sensible defaults.
    See {!Env_config.Gardener} for the mapping.

    {b Population Bounds}:
    - [min_agents]: Hard floor, never retire below (default: 5)
    - [max_agents]: Hard ceiling, never spawn above (default: 30)
    - [target_agents]: Homeostatic sweet spot (default: 15)

    {b Daily Budgets}:
    - [max_daily_spawns]: Prevents runaway spawning (default: 3)
    - [max_daily_retirements]: Prevents mass retirement (default: 2)
*)
type gardener_config = {
  enabled: bool;               (** Master switch for Gardener *)

  (* Population bounds *)
  min_agents: int;             (** Never retire below this *)
  max_agents: int;             (** Never spawn above this *)
  target_agents: int;          (** Homeostatic target *)

  (* Budgets *)
  max_daily_spawns: int;       (** Max spawns per day *)
  max_daily_retirements: int;  (** Max retirements per day *)

  (* Cooldowns *)
  spawn_cooldown_sec: float;   (** Min time between spawns *)
  retirement_cooldown_sec: float;  (** Min time between retirements *)

  (* Decision parameters *)
  use_llm_decision: bool;      (** Use LLM for complex decisions *)
  gap_maturity_hours: float;   (** Min hours before gap can trigger spawn *)
  idle_threshold_hours: float; (** Hours of inactivity before retirement eligible *)

  (* Grace periods *)
  retirement_grace_sec: float; (** Warning time before actual retirement *)

  (* Circuit breaker *)
  max_consecutive_failures: int;  (** Failures before circuit opens *)
  circuit_cooldown_sec: float;    (** Circuit open duration *)

  (* Loop timing *)
  check_interval_sec: float;   (** Health check interval *)
}

val gardener_config_to_yojson : gardener_config -> Yojson.Safe.t
val pp_gardener_config : Format.formatter -> gardener_config -> unit
val show_gardener_config : gardener_config -> string

(** {1 Ecosystem Intervention} *)

(** Type of intervention needed based on health assessment *)
type intervention =
  | NeedSpawn of enriched_gap        (** Should spawn a new agent *)
  | NeedWorker of task_backlog_summary  (** Task pressure requires workers *)
  | NeedRetirement of agent_stats    (** Should retire an agent *)
  | Balanced                         (** Ecosystem is healthy *)

val pp_intervention : Format.formatter -> intervention -> unit
val show_intervention : intervention -> string
