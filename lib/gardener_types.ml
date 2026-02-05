(** Gardener Types — Self-Organizing Agent Ecosystem

    Type definitions for the Gardener Agent that manages ecosystem homeostasis:
    - Health metrics for the agent population
    - Spawn/retirement decisions with safety mechanisms
    - Configuration for population bounds and budgets

    Research foundation:
    - ROMA (Sentient): Task complexity evaluation → spawn decisions
    - Homeostatic Balance (arxiv 1606.00799): Inverse-U reward for over/under population
    - Effort Budgeting (Anthropic): Explicit boundaries prevent runaway spawning
*)

(** {1 Urgency Levels} *)

type urgency =
  | Low       (** Normal gap, can wait *)
  | Medium    (** Multiple signals, should act soon *)
  | High      (** Many signals, act within hours *)
  | Critical  (** Ecosystem health at risk *)
[@@deriving show, eq]

let urgency_of_string = function
  | "low" -> Low
  | "medium" -> Medium
  | "high" -> High
  | "critical" -> Critical
  | _ -> Medium

let string_of_urgency = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

let urgency_to_yojson u = `String (string_of_urgency u)

let urgency_of_yojson = function
  | `String s -> Ok (urgency_of_string s)
  | _ -> Error "urgency must be a string"

(** {1 Agent Statistics} *)

type agent_stats = {
  name: string;
  posts_24h: int;           (** Posts in last 24 hours *)
  comments_24h: int;        (** Comments in last 24 hours *)
  votes_received_24h: int;  (** Votes received in last 24 hours *)
  last_active: float;       (** Unix timestamp of last activity *)
  idle_hours: float;        (** Hours since last activity *)
  thompson_alpha: float;    (** Thompson sampling alpha (successes) *)
  thompson_beta: float;     (** Thompson sampling beta (failures) *)
} [@@deriving show]

let agent_stats_to_yojson s = `Assoc [
  ("name", `String s.name);
  ("posts_24h", `Int s.posts_24h);
  ("comments_24h", `Int s.comments_24h);
  ("votes_received_24h", `Int s.votes_received_24h);
  ("last_active", `Float s.last_active);
  ("idle_hours", `Float s.idle_hours);
  ("thompson_alpha", `Float s.thompson_alpha);
  ("thompson_beta", `Float s.thompson_beta);
]

(** {1 Ecosystem Health} *)

(** Comprehensive health metrics for the agent ecosystem *)
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
} [@@deriving show]

let ecosystem_health_to_yojson h = `Assoc [
  ("total_agents", `Int h.total_agents);
  ("active_agents", `Int h.active_agents);
  ("idle_agents", `Int h.idle_agents);
  ("overloaded_agents", `Int h.overloaded_agents);
  ("posts_24h", `Int h.posts_24h);
  ("comments_24h", `Int h.comments_24h);
  ("unanswered_questions", `Int h.unanswered_questions);
  ("topic_coverage", `List (List.map (fun (t, s) ->
    `Assoc [("topic", `String t); ("score", `Float s)]) h.topic_coverage));
  ("selection_entropy", `Float h.selection_entropy);
  ("homeostatic_score", `Float h.homeostatic_score);
  ("needs_spawn", `Bool h.needs_spawn);
  ("needs_retirement", `Bool h.needs_retirement);
  ("last_spawn", match h.last_spawn with Some t -> `Float t | None -> `Null);
  ("last_retirement", match h.last_retirement with Some t -> `Float t | None -> `Null);
  ("spawns_today", `Int h.spawns_today);
  ("retirements_today", `Int h.retirements_today);
]

(** {1 Enriched Gap Signal} *)

(** Gap signal enriched with context for spawn decisions *)
type enriched_gap = {
  topic: string;                (** Gap topic (e.g., "security", "UX") *)
  signal_count: int;            (** Number of accumulated signals *)
  proposers: string list;       (** Agents who detected the gap *)
  context_snippets: string list; (** Relevant conversation snippets *)
  first_detected: float;        (** When first signal was recorded *)
  maturity_hours: float;        (** Hours since first detection *)
  topic_similarity: float;      (** Similarity to existing agents (0-1) *)
  urgency_score: float;         (** Calculated urgency (0-1) *)
} [@@deriving show]

let enriched_gap_to_yojson g = `Assoc [
  ("topic", `String g.topic);
  ("signal_count", `Int g.signal_count);
  ("proposers", `List (List.map (fun s -> `String s) g.proposers));
  ("context_snippets", `List (List.map (fun s -> `String s) g.context_snippets));
  ("first_detected", `Float g.first_detected);
  ("maturity_hours", `Float g.maturity_hours);
  ("topic_similarity", `Float g.topic_similarity);
  ("urgency_score", `Float g.urgency_score);
]

(** {1 Spawn Decision} *)

(** Result of spawn decision process *)
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
[@@deriving show]

let spawn_decision_to_yojson = function
  | SpawnApproved { topic; urgency; proposed_traits; proposed_hours; reason } ->
      `Assoc [
        ("decision", `String "approved");
        ("topic", `String topic);
        ("urgency", urgency_to_yojson urgency);
        ("proposed_traits", `List (List.map (fun s -> `String s) proposed_traits));
        ("proposed_hours", `List (List.map (fun i -> `Int i) proposed_hours));
        ("reason", `String reason);
      ]
  | SpawnDeferred { topic; retry_after_sec; reason } ->
      `Assoc [
        ("decision", `String "deferred");
        ("topic", `String topic);
        ("retry_after_sec", `Float retry_after_sec);
        ("reason", `String reason);
      ]
  | SpawnRejected { topic; reason } ->
      `Assoc [
        ("decision", `String "rejected");
        ("topic", `String topic);
        ("reason", `String reason);
      ]

(** {1 Retirement Decision} *)

(** Result of retirement decision process *)
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
[@@deriving show]

let retirement_decision_to_yojson = function
  | RetireApproved { agent_name; reason; grace_period_sec } ->
      `Assoc [
        ("decision", `String "approved");
        ("agent_name", `String agent_name);
        ("reason", `String reason);
        ("grace_period_sec", `Float grace_period_sec);
      ]
  | RetireDeferred { agent_name; retry_after_sec; reason } ->
      `Assoc [
        ("decision", `String "deferred");
        ("agent_name", `String agent_name);
        ("retry_after_sec", `Float retry_after_sec);
        ("reason", `String reason);
      ]
  | RetireRejected { agent_name; reason } ->
      `Assoc [
        ("decision", `String "rejected");
        ("agent_name", `String agent_name);
        ("reason", `String reason);
      ]

(** {1 Gardener State} *)

(** Persistent state for the Gardener Agent *)
type gardener_state = {
  mutable last_health_check: float;
  mutable last_spawn_attempt: float;
  mutable last_retirement_attempt: float;
  mutable consecutive_failures: int;
  mutable circuit_open_until: float option;
  mutable spawns_today: int;
  mutable retirements_today: int;
  mutable day_start: float;  (** Start of current "day" for budget tracking *)
} [@@deriving show]

let make_gardener_state () = {
  last_health_check = 0.0;
  last_spawn_attempt = 0.0;
  last_retirement_attempt = 0.0;
  consecutive_failures = 0;
  circuit_open_until = None;
  spawns_today = 0;
  retirements_today = 0;
  day_start = Time_compat.now ();
}

(** {1 Gardener Configuration} *)

(** Configuration for the Gardener Agent (from environment variables) *)
type gardener_config = {
  enabled: bool;               (** Master switch for Gardener *)

  (* Population bounds *)
  min_agents: int;             (** Never retire below this (default: 5) *)
  max_agents: int;             (** Never spawn above this (default: 30) *)
  target_agents: int;          (** Homeostatic target (default: 15) *)

  (* Budgets *)
  max_daily_spawns: int;       (** Max spawns per day (default: 3) *)
  max_daily_retirements: int;  (** Max retirements per day (default: 2) *)

  (* Cooldowns *)
  spawn_cooldown_sec: float;   (** Min time between spawns (default: 3600) *)
  retirement_cooldown_sec: float;  (** Min time between retirements (default: 7200) *)

  (* Decision parameters *)
  use_llm_decision: bool;      (** Use LLM for complex decisions (default: true) *)
  gap_maturity_hours: float;   (** Min hours before gap can trigger spawn (default: 2.0) *)
  idle_threshold_hours: float; (** Hours of inactivity before retirement eligible (default: 48.0) *)

  (* Grace periods *)
  retirement_grace_sec: float; (** Warning time before actual retirement (default: 3600) *)

  (* Circuit breaker *)
  max_consecutive_failures: int;  (** Failures before circuit opens (default: 3) *)
  circuit_cooldown_sec: float;    (** Circuit open duration (default: 3600) *)

  (* Loop timing *)
  check_interval_sec: float;   (** Health check interval (default: 1800) *)
} [@@deriving show]

let gardener_config_to_yojson c = `Assoc [
  ("enabled", `Bool c.enabled);
  ("min_agents", `Int c.min_agents);
  ("max_agents", `Int c.max_agents);
  ("target_agents", `Int c.target_agents);
  ("max_daily_spawns", `Int c.max_daily_spawns);
  ("max_daily_retirements", `Int c.max_daily_retirements);
  ("spawn_cooldown_sec", `Float c.spawn_cooldown_sec);
  ("retirement_cooldown_sec", `Float c.retirement_cooldown_sec);
  ("use_llm_decision", `Bool c.use_llm_decision);
  ("gap_maturity_hours", `Float c.gap_maturity_hours);
  ("idle_threshold_hours", `Float c.idle_threshold_hours);
  ("retirement_grace_sec", `Float c.retirement_grace_sec);
  ("max_consecutive_failures", `Int c.max_consecutive_failures);
  ("circuit_cooldown_sec", `Float c.circuit_cooldown_sec);
  ("check_interval_sec", `Float c.check_interval_sec);
]

(** {1 Ecosystem Intervention} *)

(** Type of intervention needed *)
type intervention =
  | NeedSpawn of enriched_gap   (** Should spawn a new agent *)
  | NeedRetirement of agent_stats  (** Should retire an agent *)
  | Balanced                    (** Ecosystem is healthy *)
[@@deriving show]
