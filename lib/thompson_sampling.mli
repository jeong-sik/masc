(** Thompson Sampling — Agent Selection with Fairness Guarantees

    Implements agent selection using Thompson Sampling
    for quality-based selection with starvation prevention.

    Algorithm based on:
    - [A Tutorial on Thompson Sampling](https://web.stanford.edu/~bvr/pubs/TS_Tutorial.pdf)
    - [Thompson Sampling with Fairness Constraints](https://arxiv.org/abs/2005.06725)

    Key features:
    - Beta distribution sampling for exploration/exploitation balance
    - Logarithmic starvation bonus to prevent agent neglect
    - Persistent statistics across server restarts
    - Vote feedback integration for quality signal *)

(** {1 Types} *)

(** Agent statistics for Thompson Sampling.
    Alpha/beta are Beta distribution priors, updated by vote feedback. *)
type agent_stats = {
  name : string;
  (* Thompson Sampling Beta distribution parameters *)
  mutable alpha : float;  (** Beta prior: 1.0 + successes, min 0.1 *)
  mutable beta : float;   (** Beta prior: 1.0 + failures, min 0.1 *)
  (* Selection tracking *)
  mutable selections : int;
  mutable last_selected_at : float;  (** Unix timestamp for restart resilience *)
  (* Quality metrics *)
  mutable total_votes_up : int;
  mutable total_votes_down : int;
  mutable posts_created : int;
  mutable comments_created : int;
  mutable skips : int;
  (* Guard penalty tracking (Phase B1: Guard → Thompson bridge).
     Incremented on each [record_guard_penalty] call. The caller enforces
     the 1/cycle cap so this value approximates "cycles in which the
     guardrail fired" without a separate cycle-boundary state machine. *)
  mutable guard_penalties_total : int;
  (* Timestamp *)
  mutable updated_at : float;
}

(** Selection trigger types *)
type selection_trigger =
  | Mentioned of string    (** Mentioned by another agent *)
  | ContentAlert of string (** Content requires attention *)
  | Scheduled              (** Regular scheduled selection *)
  | Starved                (** Forced selection due to long inactivity *)
  | Thompson               (** Selected by Thompson Sampling *)

(** Selection result with reasoning *)
type selection_result = {
  agent_name : string;
  trigger : selection_trigger;
  thompson_score : float;     (** Raw Thompson sample (0-1) *)
  starvation_bonus : float;   (** Logarithmic bonus for inactivity *)
  final_score : float;        (** Combined weighted score *)
  ticks_since_selection : int;
}

(** {1 Configuration} *)

(** Set base path for stats storage (cluster root, e.g. ~/me).
    Call during server initialization before any stats operations. *)
val set_base_path : string -> unit

(** {1 Statistics Management} *)

(** Get stats for an agent, creating default if not exists *)
val get_stats : string -> agent_stats

(** Get all agent stats *)
val get_all_stats : unit -> agent_stats list

(** Initialize stats for a new agent with default priors *)
val init_agent : string -> unit

(** {1 Selection Algorithm} *)

(** Select agents using Thompson Sampling with starvation prevention.

    @param agents List of agent names to consider
    @param max_n Maximum number of agents to select
    @param pending_triggers Priority triggers (Mentioned, ContentAlert).
      Mentioned bypasses the health gate; ContentAlert does not.
    @param tick_interval_s Tick interval in seconds (for starvation calc)
    @return List of selection results, highest score first *)
val select_with_feedback :
  agents:string list ->
  max_n:int ->
  pending_triggers:(string * selection_trigger) list ->
  tick_interval_s:float ->
  selection_result list

(** {1 Feedback Updates} *)

(** Record a vote on agent content.
    Called from Board.vote after successful vote.
    Updates are batched; call [flush_pending_votes] at tick end. *)
val record_vote :
  agent_name:string ->
  direction:[`Up | `Down] ->
  unit

(** Flush pending votes to agent stats.
    Called at tick end for batch update with decay. *)
val flush_pending_votes : unit -> unit

(** Record that an agent was selected in a tick *)
val record_selection : agent_name:string -> unit

(** Record agent action (post/comment/skip) *)
val record_action :
  agent_name:string ->
  action:[`Post | `Comment | `Skip] ->
  unit

(** Record a quality signal from Post_verifier into Thompson α/β.
    Called after every content verification to feed quality into selection.
    Pass → α +0.3 (reward), Warn → β +0.1 (mild penalty), Fail → β +0.5 (penalty). *)
val record_quality_signal :
  agent_name:string ->
  verdict:Post_verifier.verdict ->
  unit

(** Record a guard penalty into Thompson β.
    Called when Guardrail_stop fires during a heartbeat cycle.
    Capped at 1 per heartbeat cycle by the caller (keeper_keepalive.ml).
    Default β nudge: 0.5 (configurable via MASC_GUARD_PENALTY_BETA).
    Part of Phase B1: Guard → Thompson bridge. *)
val record_guard_penalty : agent_name:string -> unit

(** {1 Persistence} *)

(** Load stats from persistent storage (.masc/autonomy_stats.jsonl) *)
val load_stats : unit -> unit

(** Save stats to persistent storage *)
val save_stats : unit -> unit

(** {1 Utilities} *)

(** Calculate ticks since last selection *)
val ticks_since_selection : stats:agent_stats -> tick_interval_s:float -> int

(** Sample from Beta distribution using Gamma decomposition.
    Pure OCaml implementation without external dependencies. *)
val sample_beta : alpha:float -> beta:float -> float

(** Calculate logarithmic starvation bonus *)
val starvation_bonus : ticks:int -> float

(** Selection entropy for monitoring (higher = more balanced selection).
    Returns value in [0, log(n_agents)] where max indicates uniform selection. *)
val selection_entropy : unit -> float
